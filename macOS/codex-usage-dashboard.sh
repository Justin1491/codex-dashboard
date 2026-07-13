#!/bin/bash

# Thin compatibility launcher. The stable v2.3 dashboard core remains unchanged;
# this file only normalizes OpenAI's usage-window response before the core reads it.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_SCRIPT="$SCRIPT_DIR/codex-usage-dashboard-core.sh"
CACHE_PATH="${CODEX_HOME:-$HOME/.codex}/dashboard-window-cache.json"
USAGE_URL="${CODEX_USAGE_ENDPOINT:-https://chatgpt.com/backend-api/wham/usage}"

[[ -f "$CORE_SCRIPT" ]] || { printf 'Error: stable dashboard core not found at %s\n' "$CORE_SCRIPT" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { printf 'Error: jq is required. Install it with: brew install jq\n' >&2; exit 1; }

_codex_epoch() {
  local value="${1:-0}"
  [[ "$value" =~ ^[0-9]+$ ]] && { ((value > 99999999999)) && value=$((value / 1000)); printf '%s' "$value"; return; }
  value="$(printf '%s' "$value" | sed -E 's/\.[0-9]+Z$/Z/')"
  TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$value" '+%s' 2>/dev/null || printf '0'
}

_codex_load_cache() {
  if [[ -f "$CACHE_PATH" ]] && command jq empty "$CACHE_PATH" >/dev/null 2>&1; then
    CODEX_WINDOW_CACHE="$(cat "$CACHE_PATH")"
  else
    CODEX_WINDOW_CACHE='{}'
  fi
}

_codex_save_cache() {
  mkdir -p "$(dirname "$CACHE_PATH")" 2>/dev/null || true
  printf '%s\n' "$CODEX_WINDOW_CACHE" >"$CACHE_PATH" 2>/dev/null || true
}

_codex_cache_kind() {
  local slot="$1" reset="$2"
  command jq -r --arg slot "$slot" --argjson reset "$reset" '
    .[$slot] // {} |
    if (.reset_at // 0) == $reset then (.kind // "") else "" end
  ' <<<"$CODEX_WINDOW_CACHE"
}

_codex_classify() {
  local slot="$1" window="$2" only_window="$3"
  local minutes reset cached previous_reset previous_kind delta remaining now
  minutes="$(command jq -r '.window_minutes // .window_size_minutes // 0' <<<"$window")"
  reset="$(_codex_epoch "$(command jq -r '.reset_at // 0' <<<"$window")")"
  [[ "$minutes" =~ ^[0-9]+$ ]] || minutes=0

  if ((minutes >= 4320)); then printf 'weekly'; return; fi
  if ((minutes > 0 && minutes <= 720)); then printf 'short'; return; fi

  cached="$(_codex_cache_kind "$slot" "$reset")"
  [[ -n "$cached" ]] && { printf '%s' "$cached"; return; }

  previous_reset="$(command jq -r --arg slot "$slot" '.[$slot].reset_at // 0' <<<"$CODEX_WINDOW_CACHE")"
  previous_kind="$(command jq -r --arg slot "$slot" '.[$slot].kind // ""' <<<"$CODEX_WINDOW_CACHE")"
  if [[ "$previous_reset" =~ ^[0-9]+$ ]] && ((previous_reset > 0 && reset > previous_reset)); then
    delta=$((reset - previous_reset))
    ((delta >= 259200)) && { printf 'weekly'; return; }
    ((delta <= 43200)) && { printf 'short'; return; }
  fi

  [[ "$previous_kind" == 'weekly' || "$previous_kind" == 'short' ]] && { printf '%s' "$previous_kind"; return; }
  [[ "$only_window" == 'true' ]] && { printf 'weekly'; return; }

  now="$(date +%s)"; remaining=$((reset - now))
  ((remaining > 43200)) && { printf 'weekly'; return; }
  printf 'short'
}

_codex_cache_window() {
  local slot="$1" window="$2" kind="$3" reset
  reset="$(_codex_epoch "$(command jq -r '.reset_at // 0' <<<"$window")")"
  CODEX_WINDOW_CACHE="$(command jq -c --arg slot "$slot" --arg kind "$kind" --argjson reset "$reset" '.[$slot] = {reset_at:$reset, kind:$kind}' <<<"$CODEX_WINDOW_CACHE")"
}

_codex_normalize_usage() {
  local json="$1" primary secondary primary_kind secondary_kind short weekly only
  _codex_load_cache
  primary="$(command jq -c '.rate_limit.primary_window // null' <<<"$json")"
  secondary="$(command jq -c '.rate_limit.secondary_window // null' <<<"$json")"
  short='null'; weekly='null'

  if [[ "$primary" != 'null' && "$secondary" != 'null' ]]; then
    primary_kind="$(_codex_classify primary "$primary" false)"
    secondary_kind="$(_codex_classify secondary "$secondary" false)"

    if [[ "$primary_kind" == "$secondary_kind" ]]; then
      if (( $(_codex_epoch "$(command jq -r '.reset_at // 0' <<<"$primary")") < $(_codex_epoch "$(command jq -r '.reset_at // 0' <<<"$secondary")") )); then
        primary_kind='short'; secondary_kind='weekly'
      else
        primary_kind='weekly'; secondary_kind='short'
      fi
    fi

    if [[ "$primary_kind" == 'short' ]]; then short="$primary"; else weekly="$primary"; fi
    if [[ "$secondary_kind" == 'short' ]]; then short="$secondary"; else weekly="$secondary"; fi
    _codex_cache_window primary "$primary" "$primary_kind"
    _codex_cache_window secondary "$secondary" "$secondary_kind"
  elif [[ "$primary" != 'null' ]]; then
    primary_kind="$(_codex_classify primary "$primary" true)"
    if [[ "$primary_kind" == 'short' ]]; then short="$primary"; else weekly="$primary"; fi
    _codex_cache_window primary "$primary" "$primary_kind"
  elif [[ "$secondary" != 'null' ]]; then
    secondary_kind="$(_codex_classify secondary "$secondary" true)"
    if [[ "$secondary_kind" == 'short' ]]; then short="$secondary"; else weekly="$secondary"; fi
    _codex_cache_window secondary "$secondary" "$secondary_kind"
  fi

  _codex_save_cache
  command jq -c --argjson short "$short" --argjson weekly "$weekly" '
    .rate_limit.primary_window = $short |
    .rate_limit.secondary_window = $weekly
  ' <<<"$json"
}

curl() {
  local arg url='' response
  for arg in "$@"; do
    case "$arg" in
      http://*|https://*) url="$arg" ;;
    esac
  done

  response="$(command curl "$@")" || return $?
  if [[ "$url" == "$USAGE_URL" ]]; then
    _codex_normalize_usage "$response"
  else
    printf '%s' "$response"
  fi
}

export CACHE_PATH USAGE_URL CODEX_WINDOW_CACHE
export -f curl _codex_epoch _codex_load_cache _codex_save_cache _codex_cache_kind _codex_classify _codex_cache_window _codex_normalize_usage

# Change only the displayed version. All executable dashboard logic comes from
# the known-good v2.3 core.
sed 's/^VERSION="2\.3\.0"$/VERSION="2.4.3"/' "$CORE_SCRIPT" | /bin/bash -s -- "$@"
exit $?
