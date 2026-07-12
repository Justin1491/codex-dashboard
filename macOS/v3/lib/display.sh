#!/usr/bin/env bash

DASHBOARD_WIDTH=116
DASHBOARD_MIN_ROWS=24
DISPLAY_ORIGIN_COL=1
DISPLAY_TERM_ROWS=24
DISPLAY_TERM_COLS=80
DISPLAY_LAYOUT_OK=false
DISPLAY_CREDIT_FIRST_ROW=18
DISPLAY_FOOTER_ROW=22

terminal_size_read() {
  local size rows cols
  size="$(stty size </dev/tty 2>/dev/null || true)"
  read -r rows cols _ <<<"$size"

  if [[ "$rows" =~ ^[0-9]+$ && "$cols" =~ ^[0-9]+$ ]] &&
     ((rows > 0 && cols > 0)); then
    DISPLAY_TERM_ROWS="$rows"
    DISPLAY_TERM_COLS="$cols"
  fi
}

display_calculate_layout() {
  local credit_count="${1:-0}"
  local required_rows=$((DISPLAY_CREDIT_FIRST_ROW + (credit_count > 0 ? credit_count : 1) + 6))

  terminal_size_read

  if ((DISPLAY_TERM_COLS < DASHBOARD_WIDTH || DISPLAY_TERM_ROWS < required_rows)); then
    DISPLAY_LAYOUT_OK=false
    DISPLAY_ORIGIN_COL=1
    DISPLAY_FOOTER_ROW=$((required_rows - 4))
    return
  fi

  DISPLAY_LAYOUT_OK=true
  DISPLAY_ORIGIN_COL=$(((DISPLAY_TERM_COLS - DASHBOARD_WIDTH) / 2 + 1))
  DISPLAY_FOOTER_ROW=$((DISPLAY_CREDIT_FIRST_ROW + (credit_count > 0 ? credit_count : 1) + 2))
}

display_enter() {
  printf '\033[?1049h\033[?25l\033[2J\033[H'
}

display_leave() {
  printf '\033[?25h\033[0m\033[?1049l'
}

display_write() {
  local row="$1"
  local relative_col="$2"
  local text="${3:-}"
  printf '\033[%d;%dH%b' "$row" "$((DISPLAY_ORIGIN_COL + relative_col - 1))" "$text"
}

display_repeat() {
  local char="$1"
  local count="$2"
  local output
  printf -v output '%*s' "$count" ''
  printf '%s' "${output// /$char}"
}

display_center() {
  local text="$1"
  local width="$2"
  local left
  left=$(((width - ${#text}) / 2))
  ((left < 0)) && left=0
  printf '%*s%s' "$left" '' "$text"
}

display_bar() {
  local remaining="$1"
  local width=20 filled empty
  [[ "$remaining" =~ ^[0-9]+$ ]] || remaining=0
  ((remaining < 0)) && remaining=0
  ((remaining > 100)) && remaining=100
  filled=$((remaining * width / 100))
  empty=$((width - filled))
  printf '['
  display_repeat '#' "$filled"
  display_repeat '-' "$empty"
  printf ']'
}

display_usage_row() {
  local row="$1"
  local label="$2"
  local remaining="$3"
  local used="$4"
  local reset_at="$5"
  local bar local_time countdown

  bar="$(display_bar "$remaining")"
  local_time="$(epoch_to_local_time "$reset_at")"
  countdown="$(countdown_format "$reset_at")"

  display_write "$row" 3 "$(printf '%-10s' "$label")"
  display_write "$row" 16 "${GREEN}$(printf '%-27s' "$bar $remaining%")${RESET}"
  display_write "$row" 46 "$(printf '%3s%%' "$used")"
  display_write "$row" 56 "$(printf '%-31s' "$local_time")"
  display_write "$row" 89 "${YELLOW}$(printf '%-19s' "$countdown")${RESET}"
}

display_credit_row() {
  local row="$1"
  local record="$2"
  local status granted expires expiration_epoch countdown color

  status="$(jq -r '.status' <<<"$record")"
  granted="$(jq -r '.grantedAt // empty' <<<"$record")"
  expires="$(jq -r '.expiresAt // empty' <<<"$record")"
  expiration_epoch="$(iso_to_epoch "$expires")"
  countdown="$(countdown_format "$expiration_epoch")"

  case "$status" in
    available|active) color="$GREEN" ;;
    expired) color="$RED" ;;
    pending) color="$YELLOW" ;;
    *) color="$RESET" ;;
  esac

  display_write "$row" 3 "${color}$(printf '%-11s' "$status")${RESET}"
  display_write "$row" 16 "$(printf '%-32s' "$(epoch_to_local_time "$(iso_to_epoch "$granted")")")"
  display_write "$row" 50 "$(printf '%-32s' "$(epoch_to_local_time "$expiration_epoch")")"
  display_write "$row" 89 "${YELLOW}$(printf '%-19s' "$countdown")${RESET}"
}

display_render_full() {
  local state_json="$1"
  local automation_status="${2:-Waiting}"
  local api_status="${3:-Connected}"
  local plan allowed credits_count credit_count i record
  local five_remaining five_used five_reset week_remaining week_used week_reset

  credit_count="$(jq '.resetCredits.records | length' <<<"$state_json")"
  display_calculate_layout "$credit_count"
  printf '\033[2J\033[H'

  if [[ "$DISPLAY_LAYOUT_OK" != 'true' ]]; then
    display_write 2 1 "${YELLOW}${BOLD}Terminal window is too small.${RESET}"
    display_write 4 1 "Current: ${DISPLAY_TERM_COLS}x${DISPLAY_TERM_ROWS}"
    display_write 5 1 "Required: ${DASHBOARD_WIDTH} columns and enough rows for credit records."
    return
  fi

  plan="$(jq -r '.plan' <<<"$state_json")"
  allowed="$(jq -r '.access.allowed' <<<"$state_json")"
  credits_count="$(jq -r '.resetCredits.availableCount' <<<"$state_json")"

  five_remaining="$(jq -r '.usageWindows[0].remainingPercent' <<<"$state_json")"
  five_used="$(jq -r '.usageWindows[0].usedPercent' <<<"$state_json")"
  five_reset="$(jq -r '.usageWindows[0].resetAt' <<<"$state_json")"
  week_remaining="$(jq -r '.usageWindows[1].remainingPercent' <<<"$state_json")"
  week_used="$(jq -r '.usageWindows[1].usedPercent' <<<"$state_json")"
  week_reset="$(jq -r '.usageWindows[1].resetAt' <<<"$state_json")"

  display_write 1 1 "${CYAN}${BOLD}$(display_repeat '-' "$DASHBOARD_WIDTH")${RESET}"
  display_write 2 1 "${CYAN}${BOLD}$(display_center 'CODEX DASHBOARD V3' "$DASHBOARD_WIDTH")${RESET}"
  display_write 3 1 "${CYAN}${BOLD}$(display_repeat '-' "$DASHBOARD_WIDTH")${RESET}"

  display_write 5 3 "${BOLD}Plan:${RESET} $(printf '%-18s' "$plan")"
  if [[ "$allowed" == 'true' ]]; then
    display_write 5 35 "${BOLD}Access:${RESET} ${GREEN}AVAILABLE${RESET}"
  else
    display_write 5 35 "${BOLD}Access:${RESET} ${RED}LIMIT REACHED${RESET}"
  fi
  display_write 6 3 "${BOLD}Reset credits:${RESET} ${GREEN}$credits_count${RESET}"

  display_write 8 1 "${DIM}$(display_repeat '-' "$DASHBOARD_WIDTH")${RESET}"
  display_write 9 3 "${BOLD}$(printf '%-10s %-27s %-8s %-31s %-19s' 'WINDOW' 'REMAINING' 'USED' 'RESETS' 'TIME TO RESET')${RESET}"
  display_write 10 1 "${DIM}$(display_repeat '-' "$DASHBOARD_WIDTH")${RESET}"

  display_usage_row 12 '5-hour' "$five_remaining" "$five_used" "$five_reset"
  display_usage_row 13 'Weekly' "$week_remaining" "$week_used" "$week_reset"

  display_write 15 1 "${DIM}$(display_repeat '-' "$DASHBOARD_WIDTH")${RESET}"
  display_write 16 3 "${BOLD}$(printf '%-11s %-32s %-32s %-19s' 'STATUS' 'GRANTED' 'EXPIRES' 'TIME REMAINING')${RESET}"
  display_write 17 1 "${DIM}$(display_repeat '-' "$DASHBOARD_WIDTH")${RESET}"

  if ((credit_count == 0)); then
    display_write "$DISPLAY_CREDIT_FIRST_ROW" 3 "${DIM}No individual reset-credit records returned.${RESET}"
  else
    for ((i = 0; i < credit_count; i++)); do
      record="$(jq -c ".resetCredits.records[$i]" <<<"$state_json")"
      display_credit_row "$((DISPLAY_CREDIT_FIRST_ROW + i))" "$record"
    done
  fi

  display_write "$DISPLAY_FOOTER_ROW" 3 "${DIM}Automation: $(printf '%-88s' "$automation_status")${RESET}"
  display_write "$((DISPLAY_FOOTER_ROW + 1))" 3 "${DIM}API:        $(printf '%-88s' "$api_status")${RESET}"
  display_write "$((DISPLAY_FOOTER_ROW + 2))" 3 "${DIM}Terminal: ${DISPLAY_TERM_COLS}x${DISPLAY_TERM_ROWS} | Control + C to exit${RESET}"
}

display_update_countdowns() {
  local state_json="$1"
  local credit_count i record expires reset_at

  [[ "$DISPLAY_LAYOUT_OK" == 'true' ]] || return

  reset_at="$(jq -r '.usageWindows[0].resetAt' <<<"$state_json")"
  display_write 12 89 "${YELLOW}$(printf '%-19s' "$(countdown_format "$reset_at")")${RESET}"

  reset_at="$(jq -r '.usageWindows[1].resetAt' <<<"$state_json")"
  display_write 13 89 "${YELLOW}$(printf '%-19s' "$(countdown_format "$reset_at")")${RESET}"

  credit_count="$(jq '.resetCredits.records | length' <<<"$state_json")"
  for ((i = 0; i < credit_count; i++)); do
    record="$(jq -c ".resetCredits.records[$i]" <<<"$state_json")"
    expires="$(jq -r '.expiresAt // empty' <<<"$record")"
    display_write "$((DISPLAY_CREDIT_FIRST_ROW + i))" 89 \
      "${YELLOW}$(printf '%-19s' "$(countdown_format "$(iso_to_epoch "$expires")")")${RESET}"
  done
}
