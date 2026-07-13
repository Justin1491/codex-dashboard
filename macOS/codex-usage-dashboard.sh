#!/bin/bash

# Codex Dashboard for macOS
# Stable in-place terminal rendering with adaptive usage-window classification.
set -uo pipefail

VERSION="2.4.2"
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
MAXIMUM_WIDTH=160
ALT_SCREEN_ACTIVE=false
CLEANED_UP=false
WAS_BLOCKED=false
AUTO_RESUME_TRIGGERED=false
RESUME_STATUS='Waiting'
RESUME_PID=''
RESUME_LOG=''
LAST_REFRESH_STATUS='Not yet refreshed'
LAST_SUCCESSFUL_REFRESH='—'

usage() {
  cat <<EOF_HELP
Codex Usage Dashboard v$VERSION

Usage: $(basename "$0") [options]

  --auto-resume       Resume Codex when access becomes available again.
  --project PATH      Project directory for resume --last.
  --refresh SECONDS   API refresh interval. Default: 60.
  --prompt TEXT       Continuation instruction.
  --help              Show this help.
EOF_HELP
}

error() { printf '\n%sError:%s %s\n\n' "$RED$BOLD" "$RESET" "$1" >&2; exit 1; }

parse_arguments() {
  while (($#)); do
    case "$1" in
      --auto-resume) AUTO_RESUME=true; shift ;;
      --project) [[ $# -ge 2 ]] || error '--project requires a path.'; RESUME_PROJECT="$2"; shift 2 ;;
      --refresh) [[ $# -ge 2 ]] || error '--refresh requires seconds.'; API_REFRESH_SECONDS="$2"; [[ "$API_REFRESH_SECONDS" =~ ^[1-9][0-9]*$ ]] || error 'Refresh must be a positive integer.'; shift 2 ;;
      --prompt) [[ $# -ge 2 ]] || error '--prompt requires text.'; RESUME_PROMPT="$2"; shift 2 ;;
      --help|-h) usage; exit 0 ;;
      *) error "Unknown option: $1" ;;
    esac
  done
}

cleanup() {
  [[ "$CLEANED_UP" == true ]] && return
  CLEANED_UP=true
  if [[ "$ALT_SCREEN_ACTIVE" == true ]]; then printf '\033[?25h\033[0m\033[?1049l'; ALT_SCREEN_ACTIVE=false; else printf '\033[?25h\033[0m'; fi
}
trap 'exit 0' INT TERM HUP
trap cleanup EXIT

iso_to_epoch() {
  local value="${1:-0}"
  [[ -z "$value" || "$value" == null ]] && { printf 0; return; }
  [[ "$value" =~ ^[0-9]+$ ]] && { ((value > 99999999999)) && value=$((value/1000)); printf '%s' "$value"; return; }
  value="$(printf '%s' "$value" | sed -E 's/\.[0-9]+Z$/Z/')"
  TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$value" '+%s' 2>/dev/null || printf 0
}

epoch_local() { local epoch="${1:-0}"; ((epoch > 0)) 2>/dev/null && date -r "$epoch" '+%b %-d, %Y %-I:%M:%S %p %Z' || printf '—'; }
countdown_text() { local epoch="${1:-0}" now remaining days hours minutes seconds; ((epoch > 0)) 2>/dev/null || { printf '—'; return; }; now=$(date +%s); remaining=$((epoch-now)); ((remaining > 0)) || { printf 'READY'; return; }; days=$((remaining/86400)); hours=$(((remaining%86400)/3600)); minutes=$(((remaining%3600)/60)); seconds=$((remaining%60)); printf '%dd %02dh %02dm %02ds' "$days" "$hours" "$minutes" "$seconds"; }
ascii_bar() { local remaining="${1:-0}" width=20 filled empty; [[ "$remaining" =~ ^[0-9]+$ ]] || remaining=0; ((remaining<0)) && remaining=0; ((remaining>100)) && remaining=100; filled=$((remaining*width/100)); empty=$((width-filled)); printf '['; printf '%*s' "$filled" '' | tr ' ' '#'; printf '%*s' "$empty" '' | tr ' ' '-'; printf ']'; }

read_terminal_size() { local size rows cols; size="$(stty size </dev/tty 2>/dev/null || true)"; read -r rows cols _ <<<"$size"; [[ "$rows" =~ ^[0-9]+$ ]] || rows=30; [[ "$cols" =~ ^[0-9]+$ ]] || cols=120; TERM_ROWS=$rows; TERM_COLS=$cols; CANVAS_WIDTH=$((cols-4)); ((CANVAS_WIDTH>MAXIMUM_WIDTH)) && CANVAS_WIDTH=$MAXIMUM_WIDTH; ((CANVAS_WIDTH<MINIMUM_WIDTH)) && CANVAS_WIDTH=$MINIMUM_WIDTH; ORIGIN_COL=$(((cols-CANVAS_WIDTH)/2+1)); ((ORIGIN_COL<1)) && ORIGIN_COL=1; }
fetch_json() { curl --fail --silent --show-error "$1" -H "Authorization: Bearer $TOKEN" -H "ChatGPT-Account-ID: $ACCOUNT_ID" -H 'originator: Codex Desktop'; }
load_cache() { if [[ -f "$CACHE_PATH" ]] && jq empty "$CACHE_PATH" >/dev/null 2>&1; then CACHE_JSON="$(cat "$CACHE_PATH")"; else CACHE_JSON='{}'; fi; }
save_cache() { mkdir -p "$(dirname "$CACHE_PATH")" 2>/dev/null || true; printf '%s\n' "$CACHE_JSON" >"$CACHE_PATH" 2>/dev/null || true; }
cached_kind() { jq -r --arg slot "$1" --argjson reset "$2" '.[$slot] // {} | if (.reset_at // 0) == $reset then (.kind // "") else "" end' <<<"$CACHE_JSON"; }
cache_window() { CACHE_JSON="$(jq -c --arg slot "$1" --arg kind "$3" --argjson reset "$2" '.[$slot]={reset_at:$reset,kind:$kind}' <<<"$CACHE_JSON")"; }

classify_window() { local slot="$1" minutes="$2" reset="$3" remaining previous_reset previous_kind delta cached; if ((minutes>=4320)); then printf weekly; return; fi; if ((minutes>0 && minutes<=720)); then printf short; return; fi; cached="$(cached_kind "$slot" "$reset")"; [[ -n "$cached" ]] && { printf '%s' "$cached"; return; }; previous_reset="$(jq -r --arg slot "$slot" '.[$slot].reset_at // 0' <<<"$CACHE_JSON")"; previous_kind="$(jq -r --arg slot "$slot" '.[$slot].kind // ""' <<<"$CACHE_JSON")"; if ((previous_reset>0 && reset>previous_reset)); then delta=$((reset-previous_reset)); ((delta>=259200)) && { printf weekly; return; }; ((delta<=43200)) && { printf short; return; }; fi; remaining=$((reset-$(date +%s))); [[ "$previous_kind" == weekly ]] && { printf weekly; return; }; ((remaining>43200)) && { printf weekly; return; }; printf ambiguous; }
reset_windows() { SHORT_PRESENT=false; WEEK_PRESENT=false; AMBIG_PRESENT=false; SHORT_USED=0; SHORT_RESET=0; SHORT_LABEL='Short-term'; WEEK_USED=0; WEEK_RESET=0; AMBIG_USED=0; AMBIG_RESET=0; }
assign_window() { case "$1" in short) SHORT_PRESENT=true; SHORT_USED="$2"; SHORT_RESET="$3"; SHORT_LABEL="$4" ;; weekly) WEEK_PRESENT=true; WEEK_USED="$2"; WEEK_RESET="$3" ;; *) AMBIG_PRESENT=true; AMBIG_USED="$2"; AMBIG_RESET="$3" ;; esac; }

parse_windows() {
  local rows count slot used reset minutes kind label first_slot first_used first_reset first_minutes second_slot second_used second_reset second_minutes
  reset_windows
  rows="$(jq -r '[ ["primary", .rate_limit.primary_window?], ["secondary", .rate_limit.secondary_window?] ][] | select(.[1] != null) | [.[0], (.[1].used_percent // 0), (.[1].reset_at // 0), (.[1].window_minutes // .[1].window_size_minutes // 0)] | @tsv' <<<"$USAGE_JSON")"
  count=0
  while IFS=$'\t' read -r slot used reset minutes; do [[ -n "$slot" ]] || continue; reset="$(iso_to_epoch "$reset")"; used="${used%.*}"; [[ "$used" =~ ^[0-9]+$ ]] || used=0; [[ "$minutes" =~ ^[0-9]+$ ]] || minutes=0; count=$((count+1)); if ((count==1)); then first_slot=$slot; first_used=$used; first_reset=$reset; first_minutes=$minutes; else second_slot=$slot; second_used=$used; second_reset=$reset; second_minutes=$minutes; fi; done <<<"$rows"
  if ((count==2 && first_minutes==0 && second_minutes==0)); then if ((first_reset<second_reset)); then assign_window short "$first_used" "$first_reset" Short-term; cache_window "$first_slot" "$first_reset" short; assign_window weekly "$second_used" "$second_reset" Weekly; cache_window "$second_slot" "$second_reset" weekly; else assign_window weekly "$first_used" "$first_reset" Weekly; cache_window "$first_slot" "$first_reset" weekly; assign_window short "$second_used" "$second_reset" Short-term; cache_window "$second_slot" "$second_reset" short; fi
  else if ((count>=1)); then kind="$(classify_window "$first_slot" "$first_minutes" "$first_reset")"; label=Short-term; ((first_minutes>0 && first_minutes%60==0 && first_minutes<=720)) && label="$((first_minutes/60))-hour"; assign_window "$kind" "$first_used" "$first_reset" "$label"; [[ "$kind" != ambiguous ]] && cache_window "$first_slot" "$first_reset" "$kind"; fi; if ((count==2)); then kind="$(classify_window "$second_slot" "$second_minutes" "$second_reset")"; label=Short-term; ((second_minutes>0 && second_minutes%60==0 && second_minutes<=720)) && label="$((second_minutes/60))-hour"; assign_window "$kind" "$second_used" "$second_reset" "$label"; [[ "$kind" != ambiguous ]] && cache_window "$second_slot" "$second_reset" "$kind"; fi; fi
  save_cache
}

parse_api_data() {
  local credit
  PLAN="$(jq -r '.plan_type // "unknown"' <<<"$USAGE_JSON")"; ALLOWED="$(jq -r '.rate_limit.allowed // false' <<<"$USAGE_JSON")"; LIMIT_REACHED="$(jq -r '.rate_limit.limit_reached // false' <<<"$USAGE_JSON")"; parse_windows
  AVAILABLE_CREDITS="$(jq -r '.available_count // .rate_limit_reset_credits.available_count // empty' <<<"$CREDITS_JSON")"; [[ -n "$AVAILABLE_CREDITS" ]] || AVAILABLE_CREDITS="$(jq -r '.rate_limit_reset_credits.available_count // 0' <<<"$USAGE_JSON")"
  CREDIT_LINES=()
  while IFS= read -r credit; do [[ -n "$credit" ]] && CREDIT_LINES[${#CREDIT_LINES[@]}]="$credit"; done < <(jq -r '((.credits // .records // .rate_limit_reset_credits.credits // [])[]) | [(.status // .state // "unknown"),(.granted_at // .grantedAt // .created_at // ""),(.expires_at // .expiresAt // .expiration_at // "")] | @tsv' <<<"$CREDITS_JSON")
}

refresh_api_data() { local new_usage new_credits; if ! new_usage="$(fetch_json "$USAGE_ENDPOINT")" || ! jq empty <<<"$new_usage" >/dev/null 2>&1; then LAST_REFRESH_STATUS='Refresh failed; showing last successful data'; return 1; fi; new_credits="$(fetch_json "$CREDITS_ENDPOINT" 2>/dev/null || printf '{}')"; jq empty <<<"$new_credits" >/dev/null 2>&1 || new_credits='{}'; USAGE_JSON=$new_usage; CREDITS_JSON=$new_credits; parse_api_data; LAST_SUCCESSFUL_REFRESH="$(date '+%B %-d, %Y at %-I:%M:%S %p %Z')"; LAST_REFRESH_STATUS='Refresh successful'; return 0; }
plain_length() { printf '%s' "$1" | sed $'s/\033\\[[0-9;]*m//g' | awk '{print length}'; }
pad_line() { local text="$1" width="$2" length spaces; length="$(plain_length "$text")"; spaces=$((width-length)); ((spaces<0)) && spaces=0; printf '%b%*s' "$text" "$spaces" ''; }
usage_line() { local label="$1" present="$2" used="$3" reset="$4" unavailable="${5:-false}" remaining; if [[ "$unavailable" == true ]]; then printf '%-11s %-27s %-7s %-31s %s' "$label" 'Temporarily not enforced' '—' 'No reset scheduled' '—'; return; fi; [[ "$present" == true ]] || return; remaining=$((100-used)); ((remaining<0)) && remaining=0; ((remaining>100)) && remaining=100; printf '%-11s %s%-27s%s %3d%%   %-31s %s%s%s' "$label" "$GREEN" "$(ascii_bar "$remaining") $remaining%" "$RESET" "$used" "$(epoch_local "$reset")" "$YELLOW" "$(countdown_text "$reset")" "$RESET"; }

build_frame() {
  local line credit status granted expires access_color access_text
  FRAME=("${CYAN}+$(printf '%*s' "$((CANVAS_WIDTH-2))" '' | tr ' ' '-')+${RESET}")
  line="CODEX USAGE DASHBOARD V${VERSION}"; FRAME+=("${CYAN}${BOLD}|$(printf '%*s' "$(((CANVAS_WIDTH-2-${#line})/2))" '')${line}$(printf '%*s' "$((CANVAS_WIDTH-2-${#line}-(CANVAS_WIDTH-2-${#line})/2))" '')|${RESET}" "${CYAN}+$(printf '%*s' "$((CANVAS_WIDTH-2))" '' | tr ' ' '-')+${RESET}" "")
  [[ "$ALLOWED" == true && "$LIMIT_REACHED" != true ]] && { access_text=AVAILABLE; access_color=$GREEN; } || { access_text='LIMIT REACHED'; access_color=$RED; }
  FRAME+=("  ${BOLD}Plan${RESET}            ${PLAN}                         ${BOLD}Access${RESET}          ${access_color}${access_text}${RESET}" "  ${BOLD}Reset credits${RESET}   ${GREEN}${AVAILABLE_CREDITS}${RESET}                            ${BOLD}Auto-resume${RESET}     $([[ "$AUTO_RESUME" == true ]] && printf '%sENABLED%s' "$GREEN" "$RESET" || printf '%sOFF%s' "$DIM" "$RESET")" "  ${BOLD}Resume project${RESET}  ${RESUME_PROJECT}" "")
  FRAME+=("$(printf '%*s' "$CANVAS_WIDTH" '' | tr ' ' '-')" "  ${BOLD}WINDOW      REMAINING                    USED    RESETS                          TIME TO RESET${RESET}" "$(printf '%*s' "$CANVAS_WIDTH" '' | tr ' ' '-')")
  if [[ "$SHORT_PRESENT" == true ]]; then FRAME+=("$(usage_line "$SHORT_LABEL" true "$SHORT_USED" "$SHORT_RESET")"); else FRAME+=("$(usage_line Short-term false 0 0 true)"); fi
  [[ "$WEEK_PRESENT" == true ]] && FRAME+=("$(usage_line Weekly true "$WEEK_USED" "$WEEK_RESET")"); [[ "$AMBIG_PRESENT" == true ]] && FRAME+=("$(usage_line 'Usage window' true "$AMBIG_USED" "$AMBIG_RESET")")
  FRAME+=("" "-- RESET CREDIT STATUS $(printf '%*s' "$((CANVAS_WIDTH-23))" '' | tr ' ' '-')" "  ${BOLD}STATUS        GRANTED                           EXPIRES                           TIME REMAINING${RESET}" "$(printf '%*s' "$CANVAS_WIDTH" '' | tr ' ' '-')")
  if ((${#CREDIT_LINES[@]}==0)); then FRAME+=("  ${DIM}No individual reset-credit records were returned.${RESET}"); else for credit in "${CREDIT_LINES[@]}"; do IFS=$'\t' read -r status granted expires <<<"$credit"; FRAME+=("  ${GREEN}$(printf '%-13s' "$status")${RESET} $(printf '%-33s' "$(epoch_local "$(iso_to_epoch "$granted")")") $(printf '%-33s' "$(epoch_local "$(iso_to_epoch "$expires")")") ${YELLOW}$(countdown_text "$(iso_to_epoch "$expires")")${RESET}"); done; fi
  FRAME+=("" "  ${DIM}Automation status: ${RESUME_STATUS}${RESET}" "  ${DIM}API status:        ${LAST_REFRESH_STATUS}${RESET}" "  ${DIM}Last successful:   ${LAST_SUCCESSFUL_REFRESH}${RESET}" "  ${DIM}Terminal: ${TERM_COLS}x${TERM_ROWS} | API refresh: ${API_REFRESH_SECONDS}s | Countdown: 1s${RESET}" "  ${DIM}Press Control + C to exit.${RESET}")
}

render_frame() { local row text; build_frame; printf '\033[H'; row=0; for text in "${FRAME[@]}"; do printf '\033[%d;%dH' "$((row+1))" "$ORIGIN_COL"; pad_line "$text" "$CANVAS_WIDTH"; row=$((row+1)); done; while ((row<TERM_ROWS)); do printf '\033[%d;1H\033[2K' "$((row+1))"; row=$((row+1)); done; }
resume_last_session() { local log_file; log_file="${TMPDIR:-/tmp}/codex-auto-resume-$(date +%Y%m%d-%H%M%S).log"; RESUME_STATUS='Starting Codex resume'; (cd "$RESUME_PROJECT" && codex exec resume --last --sandbox workspace-write "$RESUME_PROMPT") >"$log_file" 2>&1 & RESUME_PID=$!; RESUME_LOG=$log_file; RESUME_STATUS="Started Codex resume as PID $RESUME_PID"; AUTO_RESUME_TRIGGERED=true; }

main() {
  local now last_api_fetch exit_code
  parse_arguments "$@"; command -v jq >/dev/null 2>&1 || error 'jq is required. Install it with: brew install jq'; command -v curl >/dev/null 2>&1 || error 'curl is required.'; [[ -f "$AUTH_PATH" ]] || error "Codex authentication file not found at $AUTH_PATH"; [[ -d "$RESUME_PROJECT" ]] || error "Project directory not found: $RESUME_PROJECT"
  TOKEN="$(jq -r '.tokens.access_token // .access_token // empty' "$AUTH_PATH")"; ACCOUNT_ID="$(jq -r '.tokens.account_id // .account_id // empty' "$AUTH_PATH")"; [[ -n "$TOKEN" && -n "$ACCOUNT_ID" ]] || error 'Authentication values were not found in auth.json.'
  load_cache; USAGE_JSON='{}'; CREDITS_JSON='{}'; CREDIT_LINES=(); read_terminal_size; refresh_api_data || error 'Unable to retrieve initial usage data.'
  if [[ "$LIMIT_REACHED" == true || "$ALLOWED" != true ]]; then WAS_BLOCKED=true; RESUME_STATUS='Waiting for Codex access to reset'; else RESUME_STATUS='Codex is available'; fi
  printf '\033[?1049h\033[?25l'; ALT_SCREEN_ACTIVE=true; printf '\033[2J\033[H'; render_frame; last_api_fetch=$(date +%s)
  while true; do read_terminal_size; now=$(date +%s); if ((now-last_api_fetch>=API_REFRESH_SECONDS)); then if refresh_api_data; then if [[ "$LIMIT_REACHED" == true || "$ALLOWED" != true ]]; then WAS_BLOCKED=true; RESUME_STATUS='Waiting for Codex access to reset'; elif [[ "$WAS_BLOCKED" == true && "$AUTO_RESUME" == true && "$AUTO_RESUME_TRIGGERED" == false ]]; then resume_last_session; else RESUME_STATUS='Codex is available'; fi; fi; last_api_fetch=$now; fi; if [[ "$AUTO_RESUME_TRIGGERED" == true && -n "$RESUME_PID" ]] && ! kill -0 "$RESUME_PID" 2>/dev/null; then wait "$RESUME_PID"; exit_code=$?; RESUME_STATUS="Resume process finished with exit code $exit_code"; RESUME_PID=''; fi; render_frame; sleep 1; done
}

main "$@"
