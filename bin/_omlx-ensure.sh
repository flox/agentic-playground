# Shared helper — sourced by launch-* omlx wrappers.
# Ensures a model is loaded in omlx, downloading from HuggingFace if missing.
# Sets OMLX_API_KEY on success.

omlx_ensure_model() {
  local model="$1" host="$2" port="$3"
  local base="http://${host}:${port}"
  local key_file="${FLOX_ENV_CACHE:-$HOME/.cache/omlx}/omlx.api-key"

  if [[ ! -s "$key_file" ]]; then
    echo "Error: omlx API key not found at $key_file" >&2
    echo "  Run: deepseek --model <model> (first-run bootstrap), or set FLOX_ENV_CACHE." >&2
    return 1
  fi
  OMLX_API_KEY="$(cat "$key_file")"

  local models
  if ! models="$(curl -sf --connect-timeout 5 --max-time 10 \
      -H "Authorization: Bearer $OMLX_API_KEY" \
      "$base/v1/models" 2>/dev/null)"; then
    echo "Error: cannot reach omlx at ${host}:${port}" >&2
    echo "  Is omlx running? Try: flox services status omlx" >&2
    return 1
  fi

  # omlx strips org prefix in /v1/models listings; check both full and short name
  local short_name="${model##*/}"
  if echo "$models" | jq -e --arg m "$model" --arg s "$short_name" \
      '.data[] | select(.id == $m or .id == $s)' >/dev/null 2>&1; then
    return 0
  fi

  # Model not loaded — need HuggingFace token to download
  local hf_token=""
  if [[ -f "$HOME/.cache/huggingface/token" ]]; then
    hf_token="$(cat "$HOME/.cache/huggingface/token")"
  fi
  if [[ -z "$hf_token" ]]; then
    echo "Error: HuggingFace token required to download ${model}" >&2
    echo "  Run: huggingface-cli login" >&2
    return 1
  fi

  # Admin login (cookie-based session)
  local cookies
  cookies="$(mktemp -t omlx-cookies.XXXXXX)"
  # Clean up cookie file if the script is interrupted during the download poll.
  # Normal exit paths use explicit rm -f; this trap covers SIGINT/TERM/HUP.
  # The calling script's trap (set after this function returns) will overwrite this.
  trap 'rm -f "${cookies:-}"' INT TERM HUP
  local status
  status="$(curl -s -o /dev/null -w '%{http_code}' \
    --connect-timeout 5 --max-time 10 \
    -c "$cookies" \
    -X POST "$base/admin/api/login" \
    -H 'Content-Type: application/json' \
    -d "{\"api_key\":\"$OMLX_API_KEY\"}")"
  if [[ "$status" != "200" ]]; then
    rm -f "$cookies"
    echo "Error: omlx admin login failed (HTTP $status)" >&2
    echo "  Is the API key in $key_file current? Try: flox services restart omlx" >&2
    return 1
  fi

  # Escape model/token for JSON
  local model_json="${model//\\/\\\\}"
  model_json="${model_json//\"/\\\"}"
  local hf_json="${hf_token//\\/\\\\}"
  hf_json="${hf_json//\"/\\\"}"

  # Trigger download
  echo "Downloading ${model}..." >&2
  local resp task_id
  if ! resp="$(curl -fsS --connect-timeout 5 --max-time 30 \
      -b "$cookies" \
      -X POST "$base/admin/api/hf/download" \
      -H 'Content-Type: application/json' \
      -d "{\"repo_id\":\"${model_json}\",\"hf_token\":\"${hf_json}\"}" 2>&1)"; then
    rm -f "$cookies"
    echo "Error: failed to start download for ${model}" >&2
    return 1
  fi
  task_id="$(echo "$resp" | jq -r '.task.task_id // empty')"
  if [[ -z "$task_id" ]]; then
    rm -f "$cookies"
    echo "Error: download did not start for ${model}: $resp" >&2
    return 1
  fi

  # Poll until complete (900 * 2s = 30 min cap)
  local state="" n=0 prog task
  while true; do
    n=$((n + 1))
    if [[ $n -gt 900 ]]; then
      rm -f "$cookies"
      printf '\n' >&2
      echo "Error: download timed out after 30 min (last state: ${state:-?})" >&2
      return 1
    fi
    task="$(curl -fsS -b "$cookies" "$base/admin/api/hf/tasks" 2>/dev/null \
      | jq -c --arg id "$task_id" '.tasks[] | select(.task_id == $id)')"
    state="$(echo "$task" | jq -r '.status')"
    case "$state" in
      completed)
        printf '\r\033[K' >&2
        echo "done." >&2
        break
        ;;
      failed)
        rm -f "$cookies"
        printf '\n' >&2
        echo "Error: download failed: $(echo "$task" | jq -r '.error')" >&2
        return 1
        ;;
      *)
        prog="$(echo "$task" | jq -r '.progress')"
        printf '\r  %s  %.1f%%' "${state:-?}" "${prog:-0}" >&2
        sleep 2
        ;;
    esac
  done
  rm -f "$cookies"
}
