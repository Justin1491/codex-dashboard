#!/bin/bash

# Deliberately avoid `set -e`: transient terminal-size and network failures are
# handled explicitly so resizing the Terminal window cannot terminate the app.
set -uo pipefail

VERSION="2.2.0"

AUTH_PATH="${CODEX_HOME:-$HOME/.codex}/auth.json"
USAGE_ENDPOINT="${CODEX_USAGE_ENDPOINT:-https://chatgpt.com/backend-api/wham/usage}"
CREDITS_ENDPOINT="${CODEX_CREDITS_ENDPOINT:-https://chatgpt.com/backend-api/wham/rate-limit-reset-credits}"

RESET=$'\033[0m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
CYAN=$'\033[36m'
RED=$'\033[31m'

AUTO_RESUME=false
RESUME_PROJECT="$PWD"
RESUME_PROMPT="The rate limit has reset. Review the current repository and session state, then continue the interrupted task from the last safe point. Do not repeat completed work."
API_REFRESH_SECONDS=60

MINIMUM_WIDTH=116
MAXIMUM_CANVAS_WIDTH=160
MINIMUM_FALLBACK_ROWS=24
MINIMUM_FALLBACK_COLS=80

# Fixed row layout inside the alternate-screen dashboard.
USAGE_ROW_5H=12
USAGE_ROW_WEEKLY=13
CREDIT_FIRST_ROW=18

# Fixed 1-based columns relative to the dashboard canvas.
USAGE_WINDOW_REL_COL=3
USAGE_REMAINING_REL_COL=16
USAGE_USED_REL_COL=48
USAGE_RESETS_REL_COL=59
USAGE_COUNTDOWN_REL_COL=94

CREDIT_STATUS_REL_COL=3
CREDIT_GRANTED_REL_COL=16
CREDIT_EXPIRES_REL_COL=50
CREDIT_COUNTDOWN_REL_COL=94

usage() {
  cat <<EOF_HELP
Codex Usage Dashboard v$VERSION

Usage:
  $(basename "$0") [options]

Options:
  --auto-resume          Resume the most recent non-interactive Codex session
                         after the five-hour limit resets.
  --project PATH         Project directory used for resume --last.
                         Default: current directory.
  --refresh SECONDS      API refresh interval. Default: 60.
  --prompt TEXT          Continuation instruction sent to Codex.
  --help                 Show this help.

Examples:
  $(basename "$0")
  $(basename "$0") --auto-resume --project ~/Developer/MyProject
EOF_HELP
}

error() {
  printf "\n${RED}${BOLD}Error:${RESET} %s\n\n" "$1" >&2
  exit 1
}

parse_arguments() {
  while (($#)); do
    case "$1" in
      --auto-resume)
        AUTO_RESUME=true
        shift
        ;;
      --project)
        [[ $# -ge 2 ]] || error "--project requires a path."
        RESUME_PROJECT="$2"
        shift 2
        ;;
      --refresh)
        [[ $# -ge 2 ]] || error "--refresh requires seconds."
        API_REFRESH_SECONDS="$2"
        [[ "$API_REFRESH_SECONDS" =~ ^[1-9][0-9]*$ ]] ||
          error "Refresh must be a positive integer."
        shift 2
        ;;
      --prompt)
        [[ $# -ge 2 ]] || error "--prompt requires text."
        RESUME_PROMPT="$2"
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        error "Unknown option: $1"
        ;;
    esac
  done
}

parse_terminal_size_text() {
  local text="${1:-}"
  local fallback_rows="${2:-24}"
  local fallback_cols="${3:-80}"
  local rows=""
  local cols=""

  read -r rows cols _ <<<"$text"

  if [[ "$rows" =~ ^[0-9]+$ ]] &&
     [[ "$cols" =~ ^[0-9]+$ ]] &&
     ((rows > 0)) && ((cols > 0)); then
    TERM_ROWS="$rows"
    TERM_COLS="$cols"
  else
    TERM_ROWS="$fallback_rows"
    TERM_COLS="$fallback_cols"
  fi
}

read_terminal_size() {
  local size=""
  local fallback_rows="${TERM_ROWS:-$MINIMUM_FALLBACK_ROWS}"
  local fallback_cols="${TERM_COLS:-$MINIMUM_FALLBACK_COLS}"

  # `stty` may fail briefly while Terminal is resizing. Preserve the last
  # confirmed dimensions instead of exiting or pretending the window is 80x24.
  size="$(stty size </dev/tty 2>/dev/null || true)"
  parse_terminal_size_text "$size" "$fallback_rows" "$fallback_cols"
}

calculate_layout() {
  local cols="${1:-80}"
  local rows="${2:-24}"
  local credit_count="${3:-0}"
  local credit_rows

  credit_rows="$credit_count"
  ((credit_rows < 1)) && credit_rows=1

  FOOTER_AUTOMATION_ROW=$((CREDIT_FIRST_ROW + credit_rows + 1))
  FOOTER_API_ROW=$((FOOTER_AUTOMATION_ROW + 1))
  FOOTER_SUCCESS_ROW=$((FOOTER_AUTOMATION_ROW + 2))
  FOOTER_TERMINAL_ROW=$((FOOTER_AUTOMATION_ROW + 3))
  FOOTER_HELP_ROW=$((FOOTER_AUTOMATION_ROW + 4))
  REQUIRED_ROWS=$((FOOTER_HELP_ROW + 1))

  if ((cols < MINIMUM_WIDTH)) || ((rows < REQUIRED_ROWS)); then
    LAYOUT_OK=false
    CANVAS_WIDTH="$MINIMUM_WIDTH"
    ORIGIN_COL=1
    return
  fi

  CANVAS_WIDTH=$((cols - 4))
  ((CANVAS_WIDTH > MAXIMUM_CANVAS_WIDTH)) &&
    CANVAS_WIDTH="$MAXIMUM_CANVAS_WIDTH"
  ((CANVAS_WIDTH < MINIMUM_WIDTH)) &&
    CANVAS_WIDTH="$MINIMUM_WIDTH"

  ORIGIN_COL=$(((cols - CANVAS_WIDTH) / 2 + 1))
  LAYOUT_OK=true
}

build_clear_sequence() {
  printf '\033[2J\033[H'
}

clear_screen() {
  printf '%s' "$(build_clear_sequence)"
}

enter_dashboard_screen() {
  printf '\033[?1049h\033[?25l'
}

leave_dashboard_screen() {
  printf '\033[?25h\033[0m\033[?1049l'
}

write_abs() {
  local row="$1"
  local col="$2"
  local text="${3:-}"
  printf '\033[%d;%dH%b' "$row" "$col" "$text"
}

write_rel() {
  local row="$1"
  local rel_col="$2"
  local text="${3:-}"
  write_abs "$row" "$((ORIGIN_COL + rel_col - 1))" "$text"
}

clear_rel_field() {
  local row="$1"
  local rel_col="$2"
  local width="$3"
  local spaces
  printf -v spaces '%*s' "$width" ''
  write_rel "$row" "$rel_col" "$spaces"
}

repeat_char() {
  local char="$1"
  local count="$2"
  local output

  printf -v output '%*s' "$count" ''
  output="${output// /$char}"
  printf '%s' "$output"
}

center_text() {
  local text="$1"
  local width="$2"
  local left right

  if ((${#text} >= width)); then
    printf '%.*s' "$width" "$text"
    return
  fi

  left=$(((width - ${#text}) / 2))
  right=$((width - ${#text} - left))
  printf '%*s%s%*s' "$left" '' "$text" "$right" ''
}

truncate_text() {
  local text="$1"
  local max="$2"

  if ((${#text} <= max)); then
    printf '%s' "$text"
  elif ((max > 3)); then
    printf '%.*s...' "$((max - 3))" "$text"
  else
    printf '%.*s' "$max" "$text"
  fi
}

draw_separator() {
  local row="$1"
  local label="${2:-}"
  local line
  local prefix
  local remaining

  if [[ -z "$label" ]]; then
    line="$(repeat_char '-' "$CANVAS_WIDTH")"
  else
    prefix="-- $label "
    remaining=$((CANVAS_WIDTH - ${#prefix}))
    ((remaining < 0)) && remaining=0
    line="${prefix}$(repeat_char '-' "$remaining")"
  fi

  write_rel "$row" 1 "${DIM}${line}${RESET}"
}

iso_to_epoch() {
  local timestamp="${1:-}"

  if [[ -z "$timestamp" || "$timestamp" == "null" ]]; then
    printf '0'
    return
  fi

  timestamp="$(printf '%s' "$timestamp" | sed -E 's/\.[0-9]+Z$/Z/')"

  TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' \
    "$timestamp" '+%s' 2>/dev/null || printf '0'
}

epoch_local() {
  local epoch="${1:-0}"

  if [[ ! "$epoch" =~ ^[0-9]+$ ]] || ((epoch <= 0)); then
    printf '—'
    return
  fi

  date -r "$epoch" '+%b %-d, %Y %-I:%M:%S %p %Z'
}

countdown_parts_at() {
  local epoch="${1:-0}"
  local now="${2:-0}"
  local remaining

  COUNTDOWN_STATE='UNKNOWN'
  COUNTDOWN_DAYS=0
  COUNTDOWN_HOURS=0
  COUNTDOWN_MINUTES=0
  COUNTDOWN_SECONDS=0

  if [[ ! "$epoch" =~ ^[0-9]+$ ]] ||
     [[ ! "$now" =~ ^[0-9]+$ ]] ||
     ((epoch <= 0)); then
    return
  fi

  remaining=$((epoch - now))

  if ((remaining <= 0)); then
    COUNTDOWN_STATE='READY'
    return
  fi

  COUNTDOWN_STATE='ACTIVE'
  COUNTDOWN_DAYS=$((remaining / 86400))
  COUNTDOWN_HOURS=$(((remaining % 86400) / 3600))
  COUNTDOWN_MINUTES=$(((remaining % 3600) / 60))
  COUNTDOWN_SECONDS=$((remaining % 60))
}

countdown_parts() {
  countdown_parts_at "$1" "$(date +%s)"
}

ascii_bar() {
  local remaining="${1:-0}"
  local width=20
  local filled
  local empty

  [[ "$remaining" =~ ^-?[0-9]+$ ]] || remaining=0
  ((remaining < 0)) && remaining=0
  ((remaining > 100)) && remaining=100

  filled=$((remaining * width / 100))
  empty=$((width - filled))

  printf '['
  repeat_char '#' "$filled"
  repeat_char '-' "$empty"
  printf ']'
}

fetch_json() {
  local endpoint="$1"
  local response

  if ! response="$(
    curl --fail --silent --show-error "$endpoint" \
      -H "Authorization: Bearer $TOKEN" \
      -H "ChatGPT-Account-ID: $ACCOUNT_ID" \
      -H 'originator: Codex Desktop'
  )"; then
    return 1
  fi

  jq empty <<<"$response" >/dev/null 2>&1 || return 1
  printf '%s' "$response"
}

parse_api_data() {
  local status granted expires

  PLAN="$(jq -r '.plan_type // "unknown"' <<<"$USAGE_JSON")"
  ALLOWED="$(jq -r '.rate_limit.allowed // false' <<<"$USAGE_JSON")"
  LIMIT_REACHED="$(jq -r '.rate_limit.limit_reached // false' <<<"$USAGE_JSON")"

  FIVE_USED="$(jq -r '.rate_limit.primary_window.used_percent // 0' <<<"$USAGE_JSON")"
  FIVE_RESET="$(jq -r '.rate_limit.primary_window.reset_at // 0' <<<"$USAGE_JSON")"
  WEEK_USED="$(jq -r '.rate_limit.secondary_window.used_percent // 0' <<<"$USAGE_JSON")"
  WEEK_RESET="$(jq -r '.rate_limit.secondary_window.reset_at // 0' <<<"$USAGE_JSON")"

  [[ "$FIVE_USED" =~ ^[0-9]+$ ]] || FIVE_USED=0
  [[ "$WEEK_USED" =~ ^[0-9]+$ ]] || WEEK_USED=0

  FIVE_REMAINING=$((100 - FIVE_USED))
  WEEK_REMAINING=$((100 - WEEK_USED))

  ((FIVE_REMAINING < 0)) && FIVE_REMAINING=0
  ((FIVE_REMAINING > 100)) && FIVE_REMAINING=100
  ((WEEK_REMAINING < 0)) && WEEK_REMAINING=0
  ((WEEK_REMAINING > 100)) && WEEK_REMAINING=100

  AVAILABLE_CREDITS="$(jq -r '.available_count // empty' <<<"$CREDITS_JSON")"

  if [[ -z "$AVAILABLE_CREDITS" ]]; then
    AVAILABLE_CREDITS="$(
      jq -r '.rate_limit_reset_credits.available_count // 0' \
        <<<"$USAGE_JSON"
    )"
  fi

  CREDIT_STATUSES=()
  CREDIT_GRANTED_LOCAL=()
  CREDIT_EXPIRES_LOCAL=()
  CREDIT_EXPIRATION_EPOCHS=()

  while IFS=$'\t' read -r status granted expires; do
    [[ -n "$status" ]] || continue

    CREDIT_STATUSES+=("$status")
    CREDIT_GRANTED_LOCAL+=("$(epoch_local "$(iso_to_epoch "$granted")")")
    CREDIT_EXPIRES_LOCAL+=("$(epoch_local "$(iso_to_epoch "$expires")")")
    CREDIT_EXPIRATION_EPOCHS+=("$(iso_to_epoch "$expires")")
  done < <(
    jq -r '
      (.credits // [])[]?
      | [
          (.status // "unknown"),
          (.granted_at // ""),
          (.expires_at // "")
        ]
      | @tsv
    ' <<<"$CREDITS_JSON"
  )

  CREDIT_COUNT="${#CREDIT_STATUSES[@]}"
  CREDIT_SIGNATURE="$(
    jq -c '(.credits // []) | map({status, granted_at, expires_at})' \
      <<<"$CREDITS_JSON"
  )"
}

refresh_api_data() {
  local new_usage
  local new_credits

  if ! new_usage="$(fetch_json "$USAGE_ENDPOINT")"; then
    LAST_REFRESH_STATUS='Refresh failed; showing last successful data'
    return 1
  fi

  if new_credits="$(fetch_json "$CREDITS_ENDPOINT")"; then
    CREDITS_JSON="$new_credits"
  else
    CREDITS_JSON='{}'
  fi

  USAGE_JSON="$new_usage"
  parse_api_data

  LAST_SUCCESSFUL_REFRESH="$(date '+%B %-d, %Y at %-I:%M:%S %p %Z')"
  LAST_REFRESH_STATUS='Refresh successful'
  return 0
}

refresh_render_action() {
  local old_signature="${1:-}"
  local new_signature="${2:-}"

  if [[ "$old_signature" == "$new_signature" ]]; then
    printf 'UPDATE'
  else
    printf 'REDRAW'
  fi
}

status_color() {
  case "${1:-unknown}" in
    available|active)
      printf '%s' "$GREEN"
      ;;
    expired)
      printf '%s' "$RED"
      ;;
    pending)
      printf '%s' "$YELLOW"
      ;;
    *)
      printf '%s' "$RESET"
      ;;
  esac
}

array_get() {
  local array_name="$1"
  local index="$2"
  local value
  eval "value=\${${array_name}[${index}]-}"
  printf '%s' "${value:-}"
}

array_set() {
  local array_name="$1"
  local index="$2"
  local value="$3"
  eval "${array_name}[${index}]=\"\$value\""
}

reset_countdown_cache() {
  local i

  PREV_USAGE_DAYS=('' '')
  PREV_USAGE_HOURS=('' '')
  PREV_USAGE_MINUTES=('' '')
  PREV_USAGE_SECONDS=('' '')
  PREV_USAGE_STATE=('' '')

  PREV_CREDIT_DAYS=()
  PREV_CREDIT_HOURS=()
  PREV_CREDIT_MINUTES=()
  PREV_CREDIT_SECONDS=()
  PREV_CREDIT_STATE=()

  for ((i = 0; i < CREDIT_COUNT; i++)); do
    PREV_CREDIT_DAYS[i]=''
    PREV_CREDIT_HOURS[i]=''
    PREV_CREDIT_MINUTES[i]=''
    PREV_CREDIT_SECONDS[i]=''
    PREV_CREDIT_STATE[i]=''
  done
}

reset_usage_countdown_cache() {
  local index="$1"
  PREV_USAGE_DAYS[index]=''
  PREV_USAGE_HOURS[index]=''
  PREV_USAGE_MINUTES[index]=''
  PREV_USAGE_SECONDS[index]=''
  PREV_USAGE_STATE[index]=''
}

write_countdown_number_if_changed() {
  local row="$1"
  local rel_col="$2"
  local value="$3"
  local format="$4"
  local array_name="$5"
  local index="$6"
  local previous
  local text

  previous="$(array_get "$array_name" "$index")"

  if [[ "$previous" != "$value" ]]; then
    printf -v text "$format" "$value"
    write_rel "$row" "$rel_col" "${YELLOW}${text}${RESET}"
    array_set "$array_name" "$index" "$value"
  fi
}

update_one_countdown() {
  local row="$1"
  local rel_col="$2"
  local epoch="$3"
  local prefix="$4"
  local index="$5"
  local state_array="${prefix}_STATE"
  local previous_state

  previous_state="$(array_get "$state_array" "$index")"
  countdown_parts "$epoch"

  case "$COUNTDOWN_STATE" in
    UNKNOWN)
      if [[ "$previous_state" != 'UNKNOWN' ]]; then
        clear_rel_field "$row" "$rel_col" 18
        write_rel "$row" "$rel_col" "${RED}UNKNOWN${RESET}"
        array_set "$state_array" "$index" 'UNKNOWN'
      fi
      ;;
    READY)
      if [[ "$previous_state" != 'READY' ]]; then
        clear_rel_field "$row" "$rel_col" 18
        write_rel "$row" "$rel_col" "${GREEN}READY${RESET}"
        array_set "$state_array" "$index" 'READY'
      fi
      ;;
    ACTIVE)
      if [[ "$previous_state" != 'ACTIVE' ]]; then
        clear_rel_field "$row" "$rel_col" 18
        write_rel "$row" "$rel_col" "${YELLOW}  0d 00h 00m 00s${RESET}"
        array_set "${prefix}_DAYS" "$index" ''
        array_set "${prefix}_HOURS" "$index" ''
        array_set "${prefix}_MINUTES" "$index" ''
        array_set "${prefix}_SECONDS" "$index" ''
        array_set "$state_array" "$index" 'ACTIVE'
      fi

      write_countdown_number_if_changed \
        "$row" "$rel_col" "$COUNTDOWN_DAYS" '%3d' "${prefix}_DAYS" "$index"

      write_countdown_number_if_changed \
        "$row" "$((rel_col + 5))" "$COUNTDOWN_HOURS" '%02d' "${prefix}_HOURS" "$index"

      write_countdown_number_if_changed \
        "$row" "$((rel_col + 9))" "$COUNTDOWN_MINUTES" '%02d' "${prefix}_MINUTES" "$index"

      write_countdown_number_if_changed \
        "$row" "$((rel_col + 13))" "$COUNTDOWN_SECONDS" '%02d' "${prefix}_SECONDS" "$index"
      ;;
  esac
}

update_all_countdowns() {
  local i

  [[ "$DISPLAY_MODE" == 'DASHBOARD' ]] || return

  update_one_countdown \
    "$USAGE_ROW_5H" "$USAGE_COUNTDOWN_REL_COL" "$FIVE_RESET" 'PREV_USAGE' 0

  update_one_countdown \
    "$USAGE_ROW_WEEKLY" "$USAGE_COUNTDOWN_REL_COL" "$WEEK_RESET" 'PREV_USAGE' 1

  for ((i = 0; i < CREDIT_COUNT; i++)); do
    update_one_countdown \
      "$((CREDIT_FIRST_ROW + i))" \
      "$CREDIT_COUNTDOWN_REL_COL" \
      "${CREDIT_EXPIRATION_EPOCHS[i]}" \
      'PREV_CREDIT' \
      "$i"
  done
}

write_summary_fields() {
  local access_text
  local access_color
  local auto_text
  local project_max
  local project_text

  if [[ "$ALLOWED" == 'true' ]]; then
    access_text='AVAILABLE'
    access_color="$GREEN"
  else
    access_text='LIMIT REACHED'
    access_color="$RED"
  fi

  if [[ "$AUTO_RESUME" == 'true' ]]; then
    auto_text="${GREEN}ENABLED${RESET}"
  else
    auto_text="${DIM}OFF${RESET}"
  fi

  clear_rel_field 5 3 48
  write_rel 5 3 "${BOLD}Plan${RESET}"
  write_rel 5 20 "$(truncate_text "$PLAN" 24)"
  write_rel 5 54 "${BOLD}Access${RESET}"
  write_rel 5 70 "${access_color}${access_text}${RESET}"

  clear_rel_field 6 3 90
  write_rel 6 3 "${BOLD}Reset credits${RESET}"
  write_rel 6 20 "${GREEN}${AVAILABLE_CREDITS}${RESET}"
  write_rel 6 54 "${BOLD}Auto-resume${RESET}"
  write_rel 6 70 "$auto_text"

  project_max=$((CANVAS_WIDTH - 19))
  project_text="$(truncate_text "$RESUME_PROJECT" "$project_max")"
  clear_rel_field 7 3 "$((CANVAS_WIDTH - 2))"
  write_rel 7 3 "${BOLD}Resume project${RESET}"
  write_rel 7 20 "$project_text"
}

write_usage_static_fields() {
  local five_remaining_text
  local week_remaining_text

  five_remaining_text="$(ascii_bar "$FIVE_REMAINING") $FIVE_REMAINING%"
  week_remaining_text="$(ascii_bar "$WEEK_REMAINING") $WEEK_REMAINING%"

  clear_rel_field "$USAGE_ROW_5H" "$USAGE_REMAINING_REL_COL" 28
  clear_rel_field "$USAGE_ROW_5H" "$USAGE_USED_REL_COL" 8
  clear_rel_field "$USAGE_ROW_5H" "$USAGE_RESETS_REL_COL" 31
  write_rel "$USAGE_ROW_5H" "$USAGE_REMAINING_REL_COL" "${GREEN}${five_remaining_text}${RESET}"
  write_rel "$USAGE_ROW_5H" "$USAGE_USED_REL_COL" "$(printf '%3d%%' "$FIVE_USED")"
  write_rel "$USAGE_ROW_5H" "$USAGE_RESETS_REL_COL" "$(epoch_local "$FIVE_RESET")"

  clear_rel_field "$USAGE_ROW_WEEKLY" "$USAGE_REMAINING_REL_COL" 28
  clear_rel_field "$USAGE_ROW_WEEKLY" "$USAGE_USED_REL_COL" 8
  clear_rel_field "$USAGE_ROW_WEEKLY" "$USAGE_RESETS_REL_COL" 31
  write_rel "$USAGE_ROW_WEEKLY" "$USAGE_REMAINING_REL_COL" "${GREEN}${week_remaining_text}${RESET}"
  write_rel "$USAGE_ROW_WEEKLY" "$USAGE_USED_REL_COL" "$(printf '%3d%%' "$WEEK_USED")"
  write_rel "$USAGE_ROW_WEEKLY" "$USAGE_RESETS_REL_COL" "$(epoch_local "$WEEK_RESET")"
}

write_footer_fields() {
  local terminal_text

  [[ "$DISPLAY_MODE" == 'DASHBOARD' ]] || return

  clear_rel_field "$FOOTER_AUTOMATION_ROW" 3 "$((CANVAS_WIDTH - 2))"
  write_rel "$FOOTER_AUTOMATION_ROW" 3 "${DIM}Automation status: ${RESUME_STATUS}${RESET}"

  clear_rel_field "$FOOTER_API_ROW" 3 "$((CANVAS_WIDTH - 2))"
  write_rel "$FOOTER_API_ROW" 3 "${DIM}API status:        ${LAST_REFRESH_STATUS}${RESET}"

  clear_rel_field "$FOOTER_SUCCESS_ROW" 3 "$((CANVAS_WIDTH - 2))"
  write_rel "$FOOTER_SUCCESS_ROW" 3 "${DIM}Last successful:   ${LAST_SUCCESSFUL_REFRESH}${RESET}"

  terminal_text="Terminal: ${TERM_COLS}x${TERM_ROWS} | API refresh: ${API_REFRESH_SECONDS}s | Countdown: 1s"
  clear_rel_field "$FOOTER_TERMINAL_ROW" 3 "$((CANVAS_WIDTH - 2))"
  write_rel "$FOOTER_TERMINAL_ROW" 3 "${DIM}${terminal_text}${RESET}"

  clear_rel_field "$FOOTER_HELP_ROW" 3 "$((CANVAS_WIDTH - 2))"
  write_rel "$FOOTER_HELP_ROW" 3 "${DIM}Press Control + C to exit.${RESET}"
}

update_static_fields() {
  [[ "$DISPLAY_MODE" == 'DASHBOARD' ]] || return
  write_summary_fields
  write_usage_static_fields
  write_footer_fields
}

draw_dashboard() {
  local top_line
  local title_line
  local i
  local color
  local credit_rows

  clear_screen

  calculate_layout "$TERM_COLS" "$TERM_ROWS" "$CREDIT_COUNT"

  if [[ "$LAYOUT_OK" != 'true' ]]; then
    DISPLAY_MODE='NARROW'
    write_abs 2 3 "${YELLOW}${BOLD}Terminal window is too small for the dashboard.${RESET}"
    write_abs 4 3 "Current size:  ${TERM_COLS}x${TERM_ROWS}"
    write_abs 5 3 "Required:      at least ${MINIMUM_WIDTH} columns x ${REQUIRED_ROWS} rows"
    write_abs 7 3 "${DIM}Resize the window. The dashboard will redraw automatically.${RESET}"
    return
  fi

  DISPLAY_MODE='DASHBOARD'

  top_line="+$(repeat_char '-' "$((CANVAS_WIDTH - 2))")+"
  title_line="|$(center_text "CODEX USAGE DASHBOARD V${VERSION}" "$((CANVAS_WIDTH - 2))")|"

  write_rel 1 1 "${CYAN}${top_line}${RESET}"
  write_rel 2 1 "${CYAN}${BOLD}${title_line}${RESET}"
  write_rel 3 1 "${CYAN}${top_line}${RESET}"

  write_summary_fields

  draw_separator 9
  write_rel 10 "$USAGE_WINDOW_REL_COL" "${BOLD}WINDOW${RESET}"
  write_rel 10 "$USAGE_REMAINING_REL_COL" "${BOLD}REMAINING${RESET}"
  write_rel 10 "$USAGE_USED_REL_COL" "${BOLD}USED${RESET}"
  write_rel 10 "$USAGE_RESETS_REL_COL" "${BOLD}RESETS${RESET}"
  write_rel 10 "$USAGE_COUNTDOWN_REL_COL" "${BOLD}TIME TO RESET${RESET}"
  draw_separator 11

  write_rel "$USAGE_ROW_5H" "$USAGE_WINDOW_REL_COL" '5-hour'
  write_rel "$USAGE_ROW_WEEKLY" "$USAGE_WINDOW_REL_COL" 'Weekly'
  write_usage_static_fields

  draw_separator 15 'RESET CREDIT STATUS'
  write_rel 16 "$CREDIT_STATUS_REL_COL" "${BOLD}STATUS${RESET}"
  write_rel 16 "$CREDIT_GRANTED_REL_COL" "${BOLD}GRANTED${RESET}"
  write_rel 16 "$CREDIT_EXPIRES_REL_COL" "${BOLD}EXPIRES${RESET}"
  write_rel 16 "$CREDIT_COUNTDOWN_REL_COL" "${BOLD}TIME REMAINING${RESET}"
  draw_separator 17

  if ((CREDIT_COUNT == 0)); then
    write_rel "$CREDIT_FIRST_ROW" 3 "${DIM}No individual reset-credit records were returned.${RESET}"
  else
    for ((i = 0; i < CREDIT_COUNT; i++)); do
      color="$(status_color "${CREDIT_STATUSES[i]}")"
      write_rel "$((CREDIT_FIRST_ROW + i))" "$CREDIT_STATUS_REL_COL" \
        "${color}${CREDIT_STATUSES[i]}${RESET}"
      write_rel "$((CREDIT_FIRST_ROW + i))" "$CREDIT_GRANTED_REL_COL" \
        "${CREDIT_GRANTED_LOCAL[i]}"
      write_rel "$((CREDIT_FIRST_ROW + i))" "$CREDIT_EXPIRES_REL_COL" \
        "${CREDIT_EXPIRES_LOCAL[i]}"
    done
  fi

  credit_rows="$CREDIT_COUNT"
  ((credit_rows < 1)) && credit_rows=1

  reset_countdown_cache
  write_footer_fields
  update_all_countdowns
}

resume_last_session() {
  local log_file

  log_file="${TMPDIR:-/tmp}/codex-auto-resume-$(date +%Y%m%d-%H%M%S).log"
  RESUME_STATUS='Starting Codex resume'
  write_footer_fields

  (
    cd "$RESUME_PROJECT" || exit 1
    codex exec resume --last --sandbox workspace-write "$RESUME_PROMPT"
  ) >"$log_file" 2>&1 &

  RESUME_PID=$!
  RESUME_LOG="$log_file"
  RESUME_STATUS="Started Codex resume as PID $RESUME_PID"
  AUTO_RESUME_TRIGGERED=true
  write_footer_fields
}

cleanup() {
  if [[ "${CLEANED_UP:-false}" == 'true' ]]; then
    return
  fi

  CLEANED_UP=true

  if [[ "${ALT_SCREEN_ACTIVE:-false}" == 'true' ]]; then
    leave_dashboard_screen
    ALT_SCREEN_ACTIVE=false
  fi
}

install_signal_traps() {
  trap 'cleanup' EXIT
  trap 'exit 0' INT TERM HUP
}

main() {
  local old_rows
  local old_cols
  local old_signature
  local old_five_reset
  local old_week_reset
  local action
  local now
  local current_second
  local last_countdown_second=-1
  local last_api_fetch=0
  local exit_code

  parse_arguments "$@"

  command -v jq >/dev/null 2>&1 ||
    error "jq is required. Install it with: brew install jq"
  command -v curl >/dev/null 2>&1 || error "curl is required."

  [[ -f "$AUTH_PATH" ]] ||
    error "Codex authentication file not found at $AUTH_PATH"
  [[ -d "$RESUME_PROJECT" ]] ||
    error "Project directory not found: $RESUME_PROJECT"

  if [[ "$AUTO_RESUME" == 'true' ]]; then
    command -v codex >/dev/null 2>&1 ||
      error "Codex CLI is required for --auto-resume."
  fi

  TOKEN="$(jq -r '.tokens.access_token // empty' "$AUTH_PATH")"
  ACCOUNT_ID="$(jq -r '.tokens.account_id // empty' "$AUTH_PATH")"

  [[ -n "$TOKEN" ]] || error "No access token found in auth.json."
  [[ -n "$ACCOUNT_ID" ]] || error "No account ID found in auth.json."

  USAGE_JSON='{}'
  CREDITS_JSON='{}'
  PLAN='unknown'
  ALLOWED=false
  LIMIT_REACHED=false
  FIVE_USED=0
  FIVE_REMAINING=100
  FIVE_RESET=0
  WEEK_USED=0
  WEEK_REMAINING=100
  WEEK_RESET=0
  AVAILABLE_CREDITS=0
  CREDIT_STATUSES=()
  CREDIT_GRANTED_LOCAL=()
  CREDIT_EXPIRES_LOCAL=()
  CREDIT_EXPIRATION_EPOCHS=()
  CREDIT_COUNT=0
  CREDIT_SIGNATURE=''

  RESUME_STATUS='Waiting'
  RESUME_LOG=''
  RESUME_PID=''
  AUTO_RESUME_TRIGGERED=false
  WAS_BLOCKED=false

  LAST_REFRESH_STATUS='Not yet refreshed'
  LAST_SUCCESSFUL_REFRESH='—'
  DISPLAY_MODE=''

  PREV_USAGE_DAYS=()
  PREV_USAGE_HOURS=()
  PREV_USAGE_MINUTES=()
  PREV_USAGE_SECONDS=()
  PREV_USAGE_STATE=()
  PREV_CREDIT_DAYS=()
  PREV_CREDIT_HOURS=()
  PREV_CREDIT_MINUTES=()
  PREV_CREDIT_SECONDS=()
  PREV_CREDIT_STATE=()

  TERM_ROWS="$MINIMUM_FALLBACK_ROWS"
  TERM_COLS="$MINIMUM_FALLBACK_COLS"
  read_terminal_size

  if ! refresh_api_data; then
    error "Unable to retrieve initial usage data."
  fi

  if [[ "$LIMIT_REACHED" == 'true' || "$ALLOWED" != 'true' ]]; then
    WAS_BLOCKED=true
    RESUME_STATUS='Waiting for five-hour limit reset'
  else
    RESUME_STATUS='Codex is available'
  fi

  calculate_layout "$TERM_COLS" "$TERM_ROWS" "$CREDIT_COUNT"

  CLEANED_UP=false
  ALT_SCREEN_ACTIVE=false
  install_signal_traps
  enter_dashboard_screen
  ALT_SCREEN_ACTIVE=true
  draw_dashboard

  last_api_fetch="$(date +%s)"

  while true; do
    old_rows="$TERM_ROWS"
    old_cols="$TERM_COLS"
    read_terminal_size

    if [[ "$TERM_ROWS" != "$old_rows" || "$TERM_COLS" != "$old_cols" ]]; then
      calculate_layout "$TERM_COLS" "$TERM_ROWS" "$CREDIT_COUNT"
      draw_dashboard
    fi

    now="$(date +%s)"

    if ((now - last_api_fetch >= API_REFRESH_SECONDS)); then
      old_signature="$CREDIT_SIGNATURE"
      old_five_reset="$FIVE_RESET"
      old_week_reset="$WEEK_RESET"

      if refresh_api_data; then
        action="$(refresh_render_action "$old_signature" "$CREDIT_SIGNATURE")"

        if [[ "$LIMIT_REACHED" == 'true' || "$ALLOWED" != 'true' ]]; then
          WAS_BLOCKED=true
          RESUME_STATUS='Waiting for five-hour limit reset'
        elif [[ "$WAS_BLOCKED" == 'true' &&
                "$AUTO_RESUME" == 'true' &&
                "$AUTO_RESUME_TRIGGERED" == 'false' ]]; then
          resume_last_session
        else
          RESUME_STATUS='Codex is available'
        fi

        if [[ "$action" == 'REDRAW' ]]; then
          calculate_layout "$TERM_COLS" "$TERM_ROWS" "$CREDIT_COUNT"
          draw_dashboard
        else
          if [[ "$old_five_reset" != "$FIVE_RESET" ]]; then
            reset_usage_countdown_cache 0
          fi
          if [[ "$old_week_reset" != "$WEEK_RESET" ]]; then
            reset_usage_countdown_cache 1
          fi
          update_static_fields
          update_all_countdowns
        fi
      else
        write_footer_fields
      fi

      last_api_fetch="$now"
    fi

    if [[ "$AUTO_RESUME_TRIGGERED" == 'true' && -n "$RESUME_PID" ]]; then
      if ! kill -0 "$RESUME_PID" 2>/dev/null; then
        wait "$RESUME_PID"
        exit_code=$?
        RESUME_STATUS="Resume process finished with exit code $exit_code"
        RESUME_PID=''
        write_footer_fields
      fi
    fi

    current_second="$now"
    if [[ "$current_second" != "$last_countdown_second" ]]; then
      update_all_countdowns
      last_countdown_second="$current_second"
    fi

    sleep 0.2
  done
}

if [[ "${CODEX_DASHBOARD_SOURCE_ONLY:-0}" != '1' ]]; then
  main "$@"
fi
