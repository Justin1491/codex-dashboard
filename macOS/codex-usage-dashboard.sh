#!/bin/bash

set -uo pipefail

VERSION="2.4.0"
AUTH_PATH="${CODEX_HOME:-$HOME/.codex}/auth.json"
CACHE_PATH="${CODEX_HOME:-$HOME/.codex}/dashboard-window-cache.json"
USAGE_ENDPOINT="${CODEX_USAGE_ENDPOINT:-https://chatgpt.com/backend-api/wham/usage}"
CREDITS_ENDPOINT="${CODEX_CREDITS_ENDPOINT:-https://chatgpt.com/backend-api/wham/rate-limit-reset-credits}"

RESET=$'\033[0m'; BOLD=$'\033[1m'; DIM=$'\033[2m'
GREEN=$'\033[32m'; YELLOW=$'\033[33m'; CYAN=$'\033[36m'; RED=$'\033[31m'

AUTO_RESUME=false
RESUME_PROJECT="$PWD"
RESUME_PROMPT="The rate limit has reset. Review the current repository and session state, then continue the interrupted task from the last safe point. Do not repeat completed work."
API_REFRESH_SECONDS=60
MINIMUM_WIDTH=116
MAXIMUM_CANVAS_WIDTH=160

usage() {
  cat <<EOF_HELP
Codex Usage Dashboard v$VERSION

Usage:
  $(basename "$0") [options]

Options:
  --auto-resume          Resume the most recent non-interactive Codex session
                         after Codex access becomes available again.
  --project PATH         Project directory used for resume --last.
  --refresh SECONDS      API refresh interval. Default: 60.
  --prompt TEXT          Continuation instruction sent to Codex.
  --help                 Show this help.
EOF_HELP
}

error() { printf '\n%sError:%s %s\n\n' "$RED$BOLD" "$RESET" "$1" >&2; exit 1; }

parse_arguments() {
  while (($#)); do
    case "$1" in
      --auto-resume) AUTO_RESUME=true; shift ;;
      --project) [[ $# -ge 2 ]] || error "--project requires a path."; RESUME_PROJECT="$2"; shift 2 ;;
      --refresh) [[ $# -ge 2 ]] || error "--refresh requires seconds."; API_REFRESH_SECONDS="$2"; [[ "$API_REFRESH_SECONDS" =~ ^[1-9][0-9]*$ ]] || error "Refresh must be a positive integer."; shift 2 ;;
      --prompt) [[ $# -ge 2 ]] || error "--prompt requires text."; RESUME_PROMPT="$2"; shift 2 ;;
      --help|-h) usage; exit 0 ;;
      *) error "Unknown option: $1" ;;
    esac
  done
}

repeat_char() { local c="$1" n="$2" s; printf -v s '%*s' "$n" ''; printf '%s' "${s// /$c}"; }
center_text() { local t="$1" w="$2" l; ((${#t} >= w)) && { printf '%.*s' "$w" "$t"; return; }; l=$(((w-${#t})/2)); printf '%*s%s%*s' "$l" '' "$t" "$((w-${#t}-l))" ''; }
truncate_text() { local t="$1" n="$2"; ((${#t}<=n)) && printf '%s' "$t" || printf '%.*s...' "$((n-3))" "$t"; }

iso_to_epoch() {
  local ts="${1:-}"
  [[ -z "$ts" || "$ts" == null ]] && { printf 0; return; }
  if [[ "$ts" =~ ^[0-9]+$ ]]; then
    ((${#ts}>11)) && printf '%s' "$((ts/1000))" || printf '%s' "$ts"
    return
  fi
  ts="$(printf '%s' "$ts" | sed -E 's/\.[0-9]+Z$/Z/')"
  TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts" '+%s' 2>/dev/null || printf 0
}

epoch_local() { local e="${1:-0}"; ((e>0)) 2>/dev/null && date -r "$e" '+%b %-d, %Y %-I:%M:%S %p %Z' || printf '—'; }
format_countdown() {
  local e="${1:-0}" now rem d h m s
  [[ "$e" =~ ^[0-9]+$ ]] || { printf 'UNKNOWN'; return; }
  ((e>0)) || { printf '—'; return; }
  now=$(date +%s); rem=$((e-now)); ((rem>0)) || { printf 'READY'; return; }
  d=$((rem/86400)); h=$(((rem%86400)/3600)); m=$(((rem%3600)/60)); s=$((rem%60))
  printf '%dd %02dh %02dm %02ds' "$d" "$h" "$m" "$s"
}

ascii_bar() {
  local remaining="${1:-0}" width=20 filled empty
  [[ "$remaining" =~ ^[0-9]+$ ]] || remaining=0
  ((remaining<0)) && remaining=0; ((remaining>100)) && remaining=100
  filled=$((remaining*width/100)); empty=$((width-filled))
  printf '['; repeat_char '#' "$filled"; repeat_char '-' "$empty"; printf ']'
}

fetch_json() {
  curl --fail --silent --show-error "$1" \
    -H "Authorization: Bearer $TOKEN" \
    -H "ChatGPT-Account-ID: $ACCOUNT_ID" \
    -H 'originator: Codex Desktop'
}

load_cache() {
  [[ -f "$CACHE_PATH" ]] && jq empty "$CACHE_PATH" >/dev/null 2>&1 && CACHE_JSON="$(cat "$CACHE_PATH")" || CACHE_JSON='{}'
}

save_cache() {
  mkdir -p "$(dirname "$CACHE_PATH")" 2>/dev/null || true
  printf '%s\n' "$CACHE_JSON" >"$CACHE_PATH" 2>/dev/null || true
}

cache_kind_for() {
  local slot="$1" reset="$2"
  jq -r --arg slot "$slot" --argjson reset "$reset" '.[$slot] // {} | if (.reset_at // 0) == $reset then (.kind // "") else "" end' <<<"$CACHE_JSON"
}

update_cache_slot() {
  local slot="$1" reset="$2" kind="$3"
  CACHE_JSON="$(jq -c --arg slot "$slot" --arg kind "$kind" --argjson reset "$reset" --argjson seen "$(date +%s)" '.[$slot] = {reset_at:$reset,kind:$kind,seen_at:$seen}' <<<"$CACHE_JSON")"
}

classify_window() {
  local slot="$1" minutes="$2" reset="$3" now remaining cached prev_reset prev_kind delta
  now=$(date +%s); remaining=$((reset-now)); ((remaining<0)) && remaining=0

  if [[ "$minutes" =~ ^[0-9]+$ ]] && ((minutes>0)); then
    if ((minutes>=4320)); then printf weekly; return; fi
    if ((minutes<=720)); then printf short; return; fi
  fi

  cached="$(cache_kind_for "$slot" "$reset")"
  [[ -n "$cached" ]] && { printf '%s' "$cached"; return; }

  prev_reset="$(jq -r --arg slot "$slot" '.[$slot].reset_at // 0' <<<"$CACHE_JSON")"
  prev_kind="$(jq -r --arg slot "$slot" '.[$slot].kind // ""' <<<"$CACHE_JSON")"
  if [[ "$prev_reset" =~ ^[0-9]+$ ]] && ((prev_reset>0 && reset>prev_reset)); then
    delta=$((reset-prev_reset))
    if ((delta>=259200)); then printf weekly; return; fi
    if ((delta<=43200)); then printf short; return; fi
  fi

  [[ "$prev_kind" == weekly && "$remaining" -le 43200 ]] && { printf weekly; return; }
  ((remaining>43200)) && { printf weekly; return; }
  printf ambiguous
}

reset_window_state() {
  SHORT_PRESENT=false; WEEK_PRESENT=false; AMBIG_PRESENT=false
  SHORT_USED=0; SHORT_RESET=0; SHORT_LABEL='Short-term'
  WEEK_USED=0; WEEK_RESET=0
  AMBIG_USED=0; AMBIG_RESET=0
}

assign_window() {
  local kind="$1" used="$2" reset="$3" label="$4"
  case "$kind" in
    short) SHORT_PRESENT=true; SHORT_USED="$used"; SHORT_RESET="$reset"; SHORT_LABEL="$label" ;;
    weekly) WEEK_PRESENT=true; WEEK_USED="$used"; WEEK_RESET="$reset" ;;
    *) AMBIG_PRESENT=true; AMBIG_USED="$used"; AMBIG_RESET="$reset" ;;
  esac
}

parse_windows() {
  local slot used reset minutes kind label count=0 first_slot first_used first_reset first_minutes second_slot second_used second_reset second_minutes
  reset_window_state

  while IFS=$'\t' read -r slot used reset minutes; do
    [[ -n "$slot" ]] || continue
    reset="$(iso_to_epoch "$reset")"; [[ "$used" =~ ^[0-9]+([.][0-9]+)?$ ]] || used=0; used="${used%.*}"
    [[ "$minutes" =~ ^[0-9]+$ ]] || minutes=0
    ((count++))
    if ((count==1)); then first_slot="$slot"; first_used="$used"; first_reset="$reset"; first_minutes="$minutes"
    else second_slot="$slot"; second_used="$used"; second_reset="$reset"; second_minutes="$minutes"; fi
  done < <(jq -r '[ ["primary", .rate_limit.primary_window?], ["secondary", .rate_limit.secondary_window?] ][] | select(.[1] != null) | [.[0], (.[1].used_percent // 0), (.[1].reset_at // 0), (.[1].window_minutes // .[1].window_size_minutes // 0)] | @tsv' <<<"$USAGE_JSON")

  if ((count==2)) && ((first_minutes==0 && second_minutes==0)); then
    if ((first_reset < second_reset)); then
      kind=short; label='Short-term'; assign_window "$kind" "$first_used" "$first_reset" "$label"; update_cache_slot "$first_slot" "$first_reset" "$kind"
      kind=weekly; assign_window "$kind" "$second_used" "$second_reset" 'Weekly'; update_cache_slot "$second_slot" "$second_reset" "$kind"
    else
      kind=weekly; assign_window "$kind" "$first_used" "$first_reset" 'Weekly'; update_cache_slot "$first_slot" "$first_reset" "$kind"
      kind=short; label='Short-term'; assign_window "$kind" "$second_used" "$second_reset" "$label"; update_cache_slot "$second_slot" "$second_reset" "$kind"
    fi
  elif ((count>=1)); then
    kind="$(classify_window "$first_slot" "$first_minutes" "$first_reset")"
    label='Short-term'; ((first_minutes>0 && first_minutes%60==0 && first_minutes<=720)) && label="$((first_minutes/60))-hour"
    assign_window "$kind" "$first_used" "$first_reset" "$label"; [[ "$kind" != ambiguous ]] && update_cache_slot "$first_slot" "$first_reset" "$kind"
    if ((count==2)); then
      kind="$(classify_window "$second_slot" "$second_minutes" "$second_reset")"
      label='Short-term'; ((second_minutes>0 && second_minutes%60==0 && second_minutes<=720)) && label="$((second_minutes/60))-hour"
      assign_window "$kind" "$second_used" "$second_reset" "$label"; [[ "$kind" != ambiguous ]] && update_cache_slot "$second_slot" "$second_reset" "$kind"
    fi
  fi
  save_cache
}

parse_api_data() {
  PLAN="$(jq -r '.plan_type // "unknown"' <<<"$USAGE_JSON")"
  ALLOWED="$(jq -r '.rate_limit.allowed // false' <<<"$USAGE_JSON")"
  LIMIT_REACHED="$(jq -r '.rate_limit.limit_reached // false' <<<"$USAGE_JSON")"
  parse_windows

  AVAILABLE_CREDITS="$(jq -r '.available_count // .rate_limit_reset_credits.available_count // 0' <<<"$CREDITS_JSON")"
  CREDIT_LINES=()
  while IFS=$'\t' read -r status granted expires; do
    [[ -n "$status" ]] || continue
    CREDIT_LINES+=("$(printf '%-12s %-32s %-32s %s' "$status" "$(epoch_local "$(iso_to_epoch "$granted")")" "$(epoch_local "$(iso_to_epoch "$expires")")" "$(format_countdown "$(iso_to_epoch "$expires")")")")
  done < <(jq -r '(.credits // [])[]? | [(.status // "unknown"),(.granted_at // 0),(.expires_at // 0)] | @tsv' <<<"$CREDITS_JSON")
}

refresh_data() {
  local usage credits
  usage="$(fetch_json "$USAGE_ENDPOINT")" || return 1
  jq empty <<<"$usage" >/dev/null 2>&1 || return 1
  credits="$(fetch_json "$CREDITS_ENDPOINT" 2>/dev/null || printf '{}')"
  jq empty <<<"$credits" >/dev/null 2>&1 || credits='{}'
  USAGE_JSON="$usage"; CREDITS_JSON="$credits"; parse_api_data
  LAST_SUCCESS="$(date '+%b %-d, %Y %-I:%M:%S %p %Z')"; STATUS='Refresh successful'
}

window_line() {
  local label="$1" present="$2" used="$3" reset="$4" remaining
  if [[ "$present" != true ]]; then
    printf '%-11s %-30s %-8s %-34s %s' "$label" 'Temporarily not enforced' '—' 'No reset scheduled' '—'
    return
  fi
  remaining=$((100-used)); ((remaining<0)) && remaining=0; ((remaining>100)) && remaining=100
  printf '%-11s %s %3d%%   %3d%%     %-34s %s' "$label" "$(ascii_bar "$remaining")" "$remaining" "$used" "$(epoch_local "$reset")" "$(format_countdown "$reset")"
}

render() {
  local cols canvas pad line access auto i
  cols=$(tput cols 2>/dev/null || printf 120); ((cols<MINIMUM_WIDTH)) && cols=$MINIMUM_WIDTH
  canvas=$((cols-4)); ((canvas>MAXIMUM_CANVAS_WIDTH)) && canvas=$MAXIMUM_CANVAS_WIDTH
  printf -v pad '%*s' "$(((cols-canvas)/2))" ''
  printf '\033[H\033[2J'
  line="+$(repeat_char '-' "$((canvas-2))")+"
  printf '%s%s\n' "$pad" "$CYAN$line$RESET"
  printf '%s%s|%s|%s\n' "$pad" "$CYAN$BOLD" "$(center_text "CODEX USAGE DASHBOARD V$VERSION" "$((canvas-2))")" "$RESET"
  printf '%s%s\n\n' "$pad" "$CYAN$line$RESET"
  [[ "$ALLOWED" == true && "$LIMIT_REACHED" != true ]] && access="${GREEN}AVAILABLE${RESET}" || access="${RED}LIMIT REACHED${RESET}"
  [[ "$AUTO_RESUME" == true ]] && auto="${GREEN}ENABLED${RESET}" || auto="${DIM}OFF${RESET}"
  printf '%s%-14s %-28s %-14s %b\n' "$pad" 'Plan' "$PLAN" 'Access' "$access"
  printf '%s%-14s %-28s %-14s %b\n' "$pad" 'Reset credits' "$AVAILABLE_CREDITS" 'Auto-resume' "$auto"
  printf '%s%-14s %s\n\n' "$pad" 'Resume project' "$(truncate_text "$RESUME_PROJECT" 70)"
  printf '%s%s\n' "$pad" "$(repeat_char '-' "$canvas")"
  printf '%s%-11s %-30s %-8s %-34s %s\n' "$pad" 'WINDOW' 'REMAINING' 'USED' 'RESETS' 'TIME TO RESET'
  printf '%s%s\n' "$pad" "$(repeat_char '-' "$canvas")"
  if [[ "$AMBIG_PRESENT" == true ]]; then
    printf '%s%s\n' "$pad" "$(window_line 'Usage window' true "$AMBIG_USED" "$AMBIG_RESET")"
  else
    printf '%s%s\n' "$pad" "$(window_line "$SHORT_LABEL" "$SHORT_PRESENT" "$SHORT_USED" "$SHORT_RESET")"
    printf '%s%s\n' "$pad" "$(window_line 'Weekly' "$WEEK_PRESENT" "$WEEK_USED" "$WEEK_RESET")"
  fi
  printf '\n%s-- RESET CREDIT STATUS %s\n' "$pad" "$(repeat_char '-' "$((canvas-23))")"
  printf '%s%-12s %-32s %-32s %s\n' "$pad" 'STATUS' 'GRANTED' 'EXPIRES' 'TIME REMAINING'
  printf '%s%s\n' "$pad" "$(repeat_char '-' "$canvas")"
  if ((${#CREDIT_LINES[@]}==0)); then printf '%s%sNo individual reset-credit records were returned.%s\n' "$pad" "$DIM" "$RESET"; else for i in "${!CREDIT_LINES[@]}"; do printf '%s%s\n' "$pad" "${CREDIT_LINES[i]}"; done; fi
  printf '\n%s%sAutomation status: %s%s\n' "$pad" "$DIM" "$RESUME_STATUS" "$RESET"
  printf '%s%sAPI status:        %s%s\n' "$pad" "$DIM" "$STATUS" "$RESET"
  printf '%s%sLast successful:   %s%s\n' "$pad" "$DIM" "$LAST_SUCCESS" "$RESET"
  printf '%s%sTerminal: %sx? | API refresh: %ss | Countdown: 1s%s\n' "$pad" "$DIM" "$cols" "$API_REFRESH_SECONDS" "$RESET"
  printf '%s%sPress Control + C to exit.%s\n' "$pad" "$DIM" "$RESET"
}

start_resume() {
  local log
  [[ "$AUTO_RESUME" == true ]] || return
  command -v codex >/dev/null 2>&1 || { RESUME_STATUS='Failed: codex command not found'; return; }
  log="${TMPDIR:-/tmp}/codex-auto-resume-$(date +%Y%m%d-%H%M%S).log"
  (cd "$RESUME_PROJECT" && codex exec resume --last --sandbox workspace-write "$RESUME_PROMPT") >"$log" 2>&1 &
  RESUME_STATUS="Started Codex resume as PID $!"; WAS_BLOCKED=false
}

cleanup() { printf '\033[?25h\033[0m'; }

main() {
  local last_fetch=0 now blocked
  parse_arguments "$@"
  command -v jq >/dev/null 2>&1 || error "jq is required. Install it with: brew install jq"
  command -v curl >/dev/null 2>&1 || error "curl is required."
  [[ -f "$AUTH_PATH" ]] || error "Codex authentication file not found at $AUTH_PATH"
  [[ -d "$RESUME_PROJECT" ]] || error "Project directory not found: $RESUME_PROJECT"
  TOKEN="$(jq -r '.tokens.access_token // .access_token // empty' "$AUTH_PATH")"
  ACCOUNT_ID="$(jq -r '.tokens.account_id // .account_id // empty' "$AUTH_PATH")"
  [[ -n "$TOKEN" && -n "$ACCOUNT_ID" ]] || error "Required authentication values were not found in auth.json."
  load_cache
  LAST_SUCCESS='—'; STATUS='Not yet refreshed'; RESUME_STATUS='Waiting'; WAS_BLOCKED=false
  refresh_data || error "Unable to retrieve initial usage data."
  blocked=false; [[ "$LIMIT_REACHED" == true || "$ALLOWED" != true ]] && blocked=true
  [[ "$blocked" == true ]] && { WAS_BLOCKED=true; RESUME_STATUS='Waiting for Codex access to reset'; } || RESUME_STATUS='Codex is available'
  trap cleanup EXIT INT TERM HUP
  printf '\033[?25l'
  while true; do
    now=$(date +%s)
    if ((now-last_fetch>=API_REFRESH_SECONDS)); then
      if refresh_data; then
        blocked=false; [[ "$LIMIT_REACHED" == true || "$ALLOWED" != true ]] && blocked=true
        if [[ "$blocked" == true ]]; then WAS_BLOCKED=true; RESUME_STATUS='Waiting for Codex access to reset'
        elif [[ "$WAS_BLOCKED" == true ]]; then start_resume
        elif [[ "$RESUME_STATUS" != Started* ]]; then RESUME_STATUS='Codex is available'; fi
      else STATUS='Refresh failed; showing last successful data'; fi
      last_fetch=$now
    fi
    render
    sleep 1
  done
}

main "$@"
