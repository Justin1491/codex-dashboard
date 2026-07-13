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
command -v perl >/dev/null 2>&1 || { printf 'Error: perl is required for the interactive dashboard overlay.\n' >&2; exit 1; }

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

# Interactive setup supplements the existing --auto-resume and --project options.
# The stable core remains untouched; this launcher injects the small UI overlay.
_codex_transform_core() {
  local old_version='VERSION="2.3.0"'
  local new_version='VERSION="2.5.3"'
  local old_footer='write_rel "$FOOTER_HELP_ROW" 3 "${DIM}Press Control + C to exit.${RESET}"'
  local new_footer='write_rel "$FOOTER_HELP_ROW" 3 "${DIM}Press A to configure auto-resume | Control+C to exit.${RESET}"'
  local insert_before='cleanup() {'
  local startup_status_old=$'  else\n    RESUME_STATUS=\'Codex is available\'\n  fi'
  local startup_status_new=$'  else\n    if [[ "$AUTO_RESUME" == \'true\' ]]; then\n      RESUME_STATUS=\'Armed; waiting for Codex to become rate limited\'\n    else\n      RESUME_STATUS=\'Codex is available\'\n    fi\n  fi'
  local loop_status_old=$'        else\n          RESUME_STATUS=\'Codex is available\'\n        fi'
  local loop_status_new=$'        else\n          if [[ "$AUTO_RESUME" == \'true\' ]]; then\n            RESUME_STATUS=\'Armed; waiting for Codex to become rate limited\'\n          else\n            RESUME_STATUS=\'Codex is available\'\n          fi\n        fi'
  local loop_marker='    sleep 0.2'
  local loop_replacement=$'    _codex_poll_interactive_key\n\n    sleep 0.2'
  local screen_start_old=$'  enter_dashboard_screen\n  ALT_SCREEN_ACTIVE=true\n  draw_dashboard'
  local screen_start_new=$'  enter_dashboard_screen\n  ALT_SCREEN_ACTIVE=true\n  _codex_enable_key_mode\n  draw_dashboard'
  local cleanup_old='cleanup() {'
  local cleanup_new=$'cleanup() {\n  _codex_restore_tty_mode'
  local interactive_overlay

  IFS= read -r -d '' interactive_overlay <<'EOF_OVERLAY' || true
CODEX_TTY_STATE=''

_codex_enable_key_mode() {
  local state=''

  if [[ -z "${CODEX_TTY_STATE:-}" ]]; then
    state="$(stty -g </dev/tty 2>/dev/null || true)"
    [[ -n "$state" ]] && CODEX_TTY_STATE="$state"
  fi

  [[ -n "${CODEX_TTY_STATE:-}" ]] || return 0
  # VMIN=0 and VTIME=1 make each poll return after at most 0.1 seconds.
  stty -icanon min 0 time 1 -echo </dev/tty 2>/dev/null || true
}

_codex_restore_tty_mode() {
  [[ -n "${CODEX_TTY_STATE:-}" ]] || return 0
  stty "$CODEX_TTY_STATE" </dev/tty 2>/dev/null || true
}

_codex_restore_dashboard_after_prompt() {
  enter_dashboard_screen
  ALT_SCREEN_ACTIVE=true
  _codex_enable_key_mode
  read_terminal_size
  calculate_layout "$TERM_COLS" "$TERM_ROWS" "$CREDIT_COUNT"
  draw_dashboard
}

_codex_wait_for_enter() {
  printf '\nPress Enter to return to the dashboard.'
  IFS= read -r _ </dev/tty || true
}

_codex_resolve_project_path() {
  local input="${1:-}"

  if [[ -z "$input" ]]; then
    input="$RESUME_PROJECT"
  elif [[ "$input" == '~' ]]; then
    input="$HOME"
  elif [[ "$input" == '~/'* ]]; then
    input="$HOME/${input#\~/}"
  fi

  (cd "$input" 2>/dev/null && pwd -P) || return 1
}

_codex_configure_auto_resume() {
  local action='' project_input='' candidate='' confirm=''

  _codex_restore_tty_mode
  if [[ "${ALT_SCREEN_ACTIVE:-false}" == 'true' ]]; then
    leave_dashboard_screen
    ALT_SCREEN_ACTIVE=false
  fi

  printf '\033[2J\033[H'
  printf 'Configure Automatic Resume\n\n'

  if [[ "$AUTO_RESUME" == 'true' ]]; then
    printf 'Auto-resume is currently armed for:\n  %s\n\n' "$RESUME_PROJECT"
    printf '[C] Change project\n[D] Disable auto-resume\n[Enter] Cancel\n\nChoice: '
    IFS= read -r action </dev/tty || action=''
    case "$action" in
      d|D)
        AUTO_RESUME=false
        AUTO_RESUME_TRIGGERED=false
        RESUME_STATUS='Disabled'
        _codex_restore_dashboard_after_prompt
        return
        ;;
      c|C)
        ;;
      *)
        _codex_restore_dashboard_after_prompt
        return
        ;;
    esac
  fi

  printf 'Project folder [%s]: ' "$RESUME_PROJECT"
  IFS= read -r project_input </dev/tty || project_input=''

  if ! candidate="$(_codex_resolve_project_path "$project_input")"; then
    printf '\nProject directory not found: %s\n' "${project_input:-$RESUME_PROJECT}"
    _codex_wait_for_enter
    _codex_restore_dashboard_after_prompt
    return
  fi

  if ! command -v codex >/dev/null 2>&1; then
    printf '\nThe codex command was not found. Install or sign in to Codex first.\n'
    _codex_wait_for_enter
    _codex_restore_dashboard_after_prompt
    return
  fi

  printf '\nArm auto-resume for:\n  %s\n\nConfirm? [Y/n]: ' "$candidate"
  IFS= read -r confirm </dev/tty || confirm='n'
  case "$confirm" in
    n|N|no|NO|No)
      _codex_restore_dashboard_after_prompt
      return
      ;;
  esac

  AUTO_RESUME=true
  RESUME_PROJECT="$candidate"
  AUTO_RESUME_TRIGGERED=false

  if [[ "$LIMIT_REACHED" == 'true' || "$ALLOWED" != 'true' ]]; then
    WAS_BLOCKED=true
    RESUME_STATUS='Waiting for Codex access to reset'
  else
    WAS_BLOCKED=false
    RESUME_STATUS='Armed; waiting for Codex to become rate limited'
  fi

  _codex_restore_dashboard_after_prompt
}

_codex_poll_interactive_key() {
  local key=''

  if IFS= read -r -s -n 1 key </dev/tty 2>/dev/null; then
    case "$key" in
      a|A) _codex_configure_auto_resume ;;
    esac
  fi
}

EOF_OVERLAY

  export CODEX_CORE_OLD_VERSION="$old_version"
  export CODEX_CORE_NEW_VERSION="$new_version"
  export CODEX_CORE_OLD_FOOTER="$old_footer"
  export CODEX_CORE_NEW_FOOTER="$new_footer"
  export CODEX_CORE_INSERT_BEFORE="$insert_before"
  export CODEX_CORE_INTERACTIVE_OVERLAY="$interactive_overlay"
  export CODEX_CORE_STARTUP_STATUS_OLD="$startup_status_old"
  export CODEX_CORE_STARTUP_STATUS_NEW="$startup_status_new"
  export CODEX_CORE_LOOP_STATUS_OLD="$loop_status_old"
  export CODEX_CORE_LOOP_STATUS_NEW="$loop_status_new"
  export CODEX_CORE_LOOP_MARKER="$loop_marker"
  export CODEX_CORE_LOOP_REPLACEMENT="$loop_replacement"
  export CODEX_CORE_SCREEN_START_OLD="$screen_start_old"
  export CODEX_CORE_SCREEN_START_NEW="$screen_start_new"
  export CODEX_CORE_CLEANUP_OLD="$cleanup_old"
  export CODEX_CORE_CLEANUP_NEW="$cleanup_new"

  local transformed
  transformed="$(LC_ALL=C perl -0pe '
    s/\Q$ENV{CODEX_CORE_OLD_VERSION}\E/$ENV{CODEX_CORE_NEW_VERSION}/ge;
    s/\Q$ENV{CODEX_CORE_OLD_FOOTER}\E/$ENV{CODEX_CORE_NEW_FOOTER}/ge;
    s/\Q$ENV{CODEX_CORE_INSERT_BEFORE}\E/$ENV{CODEX_CORE_INTERACTIVE_OVERLAY} . "\n" . $ENV{CODEX_CORE_INSERT_BEFORE}/ge;
    s/\Q$ENV{CODEX_CORE_STARTUP_STATUS_OLD}\E/$ENV{CODEX_CORE_STARTUP_STATUS_NEW}/ge;
    s/\Q$ENV{CODEX_CORE_LOOP_STATUS_OLD}\E/$ENV{CODEX_CORE_LOOP_STATUS_NEW}/ge;
    s/\Q$ENV{CODEX_CORE_LOOP_MARKER}\E/$ENV{CODEX_CORE_LOOP_REPLACEMENT}/ge;
    s/\Q$ENV{CODEX_CORE_SCREEN_START_OLD}\E/$ENV{CODEX_CORE_SCREEN_START_NEW}/ge;
    s/\Q$ENV{CODEX_CORE_CLEANUP_OLD}\E/$ENV{CODEX_CORE_CLEANUP_NEW}/ge;
  ' "$CORE_SCRIPT")" || return 1

  grep -Fq 'VERSION="2.5.3"' <<<"$transformed" || { printf 'Error: dashboard version overlay failed.\n' >&2; return 1; }
  grep -Fq '_codex_configure_auto_resume()' <<<"$transformed" || { printf 'Error: interactive auto-resume overlay failed.\n' >&2; return 1; }
  grep -Fq 'Press A to configure auto-resume' <<<"$transformed" || { printf 'Error: interactive dashboard help overlay failed.\n' >&2; return 1; }
  grep -Fq '_codex_poll_interactive_key' <<<"$transformed" || { printf 'Error: interactive key handler overlay failed.\n' >&2; return 1; }
  grep -Fq '_codex_enable_key_mode' <<<"$transformed" || { printf 'Error: interactive terminal mode overlay failed.\n' >&2; return 1; }
  grep -Fq '_codex_restore_tty_mode' <<<"$transformed" || { printf 'Error: terminal restoration overlay failed.\n' >&2; return 1; }

  printf '%s\n' "$transformed"
}

_codex_transform_core | /bin/bash -s -- "$@"
exit $?
