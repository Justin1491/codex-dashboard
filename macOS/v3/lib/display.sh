#!/usr/bin/env bash

DASHBOARD_WIDTH=132
DASHBOARD_MIN_ROWS=30
DISPLAY_ORIGIN_COL=1
DISPLAY_TERM_ROWS=24
DISPLAY_TERM_COLS=80
DISPLAY_LAYOUT_OK=false
DISPLAY_USAGE_FIRST_ROW=18
DISPLAY_CREDIT_FIRST_ROW=24
DISPLAY_FOOTER_ROW=28

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
  local credit_rows
  local required_rows

  credit_rows="$credit_count"
  ((credit_rows < 1)) && credit_rows=1
  required_rows=$((DISPLAY_CREDIT_FIRST_ROW + credit_rows + 6))

  terminal_size_read

  if ((DISPLAY_TERM_COLS < DASHBOARD_WIDTH || DISPLAY_TERM_ROWS < required_rows)); then
    DISPLAY_LAYOUT_OK=false
    DISPLAY_ORIGIN_COL=1
    DISPLAY_FOOTER_ROW=$((required_rows - 4))
    return
  fi

  DISPLAY_LAYOUT_OK=true
  DISPLAY_ORIGIN_COL=$(((DISPLAY_TERM_COLS - DASHBOARD_WIDTH) / 2 + 1))
  DISPLAY_FOOTER_ROW=$((DISPLAY_CREDIT_FIRST_ROW + credit_rows + 2))
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

display_truncate() {
  local text="${1:-}"
  local width="${2:-1}"

  if ((${#text} <= width)); then
    printf '%s' "$text"
  elif ((width > 3)); then
    printf '%.*s...' "$((width - 3))" "$text"
  else
    printf '%.*s' "$width" "$text"
  fi
}

display_section_title() {
  local row="$1"
  local title="$2"
  local prefix="-- $title "
  local remaining=$((DASHBOARD_WIDTH - ${#prefix}))
  ((remaining < 0)) && remaining=0
  display_write "$row" 1 "${CYAN}${BOLD}${prefix}$(display_repeat '-' "$remaining")${RESET}"
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

display_resume_action_text() {
  case "${1:-off}" in
    off)
      printf 'Dashboard only; no resume action'
      ;;
    notify)
      printf 'Notify when Codex becomes available'
      ;;
    confirm)
      printf 'Ask before resuming the latest safe Codex session'
      ;;
    automatic)
      printf 'Automatically resume the latest safe Codex session'
      ;;
    *)
      printf 'Unknown resume mode'
      ;;
  esac
}

display_project_name() {
  local project_json="${1:-}"

  if [[ -z "$project_json" ]]; then
    printf 'Not configured'
    return
  fi

  jq -r '.name // "Not configured"' <<<"$project_json" 2>/dev/null ||
    printf 'Not configured'
}

display_project_path() {
  local project_json="${1:-}"

  if [[ -z "$project_json" ]]; then
    printf 'Not configured'
    return
  fi

  jq -r '.path // "Not configured"' <<<"$project_json" 2>/dev/null ||
    printf 'Not configured'
}

display_project_readiness() {
  local project_json="${1:-}"
  local path

  if [[ -z "$project_json" ]]; then
    printf 'No default project'
    return
  fi

  path="$(jq -r '.path // empty' <<<"$project_json" 2>/dev/null || true)"

  if [[ -z "$path" ]]; then
    printf 'No default project'
  elif [[ ! -d "$path" ]]; then
    printf 'Missing folder'
  elif git -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if [[ -n "$(git -C "$path" status --porcelain 2>/dev/null)" ]]; then
      printf 'Working tree has changes'
    else
      printf 'Ready (clean Git repository)'
    fi
  else
    printf 'Ready (folder exists)'
  fi
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
  local resume_mode="${4:-}"
  local project_json="${5:-}"
  local plan allowed credits_count credit_count i record
  local five_remaining five_used five_reset week_remaining week_used week_reset
  local project_name project_path project_readiness resume_action

  if [[ -z "$resume_mode" ]] && declare -F config_get >/dev/null 2>&1; then
    resume_mode="$(config_get '.resumeMode' 2>/dev/null || printf 'off')"
  fi
  [[ -n "$resume_mode" ]] || resume_mode='off'

  if [[ -z "$project_json" ]] && declare -F project_default_json >/dev/null 2>&1; then
    project_json="$(project_default_json 2>/dev/null || true)"
  fi

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

  project_name="$(display_project_name "$project_json")"
  project_path="$(display_project_path "$project_json")"
  project_readiness="$(display_project_readiness "$project_json")"
  resume_action="$(display_resume_action_text "$resume_mode")"

  display_write 1 1 "${CYAN}${BOLD}$(display_repeat '-' "$DASHBOARD_WIDTH")${RESET}"
  display_write 2 1 "${CYAN}${BOLD}$(display_center 'CODEX DASHBOARD V3 ALPHA 2' "$DASHBOARD_WIDTH")${RESET}"
  display_write 3 1 "${CYAN}${BOLD}$(display_repeat '-' "$DASHBOARD_WIDTH")${RESET}"

  display_section_title 5 'OVERVIEW'
  display_write 6 3 "${BOLD}Plan:${RESET} $(printf '%-18s' "$plan")"
  if [[ "$allowed" == 'true' ]]; then
    display_write 6 35 "${BOLD}Access:${RESET} ${GREEN}AVAILABLE${RESET}"
  else
    display_write 6 35 "${BOLD}Access:${RESET} ${RED}LIMIT REACHED${RESET}"
  fi
  display_write 6 70 "${BOLD}Reset credits:${RESET} ${GREEN}$credits_count${RESET}"
  display_write 7 3 "${DIM}API: $(display_truncate "$api_status" 120)${RESET}"

  display_section_title 9 'AUTO-RESUME'
  display_write 10 3 "${BOLD}Mode:${RESET} $(printf '%-14s' "$resume_mode")"
  display_write 10 30 "${BOLD}Default project:${RESET} ${GREEN}$(display_truncate "$project_name" 35)${RESET}"
  display_write 11 3 "${BOLD}Project path:${RESET} $(display_truncate "$project_path" 113)"
  display_write 12 3 "${BOLD}Action on reset:${RESET} $(display_truncate "$resume_action" 109)"
  display_write 13 3 "${BOLD}Project status:${RESET} $(display_truncate "$project_readiness" 109)"

  display_section_title 15 'USAGE WINDOWS'
  display_write 16 3 "${BOLD}$(printf '%-10s %-27s %-8s %-31s %-19s' 'WINDOW' 'REMAINING' 'USED' 'RESETS' 'TIME TO RESET')${RESET}"
  display_write 17 1 "${DIM}$(display_repeat '-' "$DASHBOARD_WIDTH")${RESET}"

  display_usage_row "$DISPLAY_USAGE_FIRST_ROW" '5-hour' "$five_remaining" "$five_used" "$five_reset"
  display_usage_row "$((DISPLAY_USAGE_FIRST_ROW + 1))" 'Weekly' "$week_remaining" "$week_used" "$week_reset"

  display_section_title 21 'RESET CREDIT STATUS'
  display_write 22 3 "${BOLD}$(printf '%-11s %-32s %-32s %-19s' 'STATUS' 'GRANTED' 'EXPIRES' 'TIME REMAINING')${RESET}"
  display_write 23 1 "${DIM}$(display_repeat '-' "$DASHBOARD_WIDTH")${RESET}"

  if ((credit_count == 0)); then
    display_write "$DISPLAY_CREDIT_FIRST_ROW" 3 "${DIM}No individual reset-credit records returned.${RESET}"
  else
    for ((i = 0; i < credit_count; i++)); do
      record="$(jq -c ".resetCredits.records[$i]" <<<"$state_json")"
      display_credit_row "$((DISPLAY_CREDIT_FIRST_ROW + i))" "$record"
    done
  fi

  display_write "$DISPLAY_FOOTER_ROW" 3 "${DIM}Automation: $(printf '%-112s' "$automation_status")${RESET}"
  display_write "$((DISPLAY_FOOTER_ROW + 1))" 3 "${DIM}Terminal: ${DISPLAY_TERM_COLS}x${DISPLAY_TERM_ROWS} | Control + C to exit${RESET}"
}

display_update_countdowns() {
  local state_json="$1"
  local credit_count i record expires reset_at

  [[ "$DISPLAY_LAYOUT_OK" == 'true' ]] || return

  reset_at="$(jq -r '.usageWindows[0].resetAt' <<<"$state_json")"
  display_write "$DISPLAY_USAGE_FIRST_ROW" 89 \
    "${YELLOW}$(printf '%-19s' "$(countdown_format "$reset_at")")${RESET}"

  reset_at="$(jq -r '.usageWindows[1].resetAt' <<<"$state_json")"
  display_write "$((DISPLAY_USAGE_FIRST_ROW + 1))" 89 \
    "${YELLOW}$(printf '%-19s' "$(countdown_format "$reset_at")")${RESET}"

  credit_count="$(jq '.resetCredits.records | length' <<<"$state_json")"
  for ((i = 0; i < credit_count; i++)); do
    record="$(jq -c ".resetCredits.records[$i]" <<<"$state_json")"
    expires="$(jq -r '.expiresAt // empty' <<<"$record")"
    display_write "$((DISPLAY_CREDIT_FIRST_ROW + i))" 89 \
      "${YELLOW}$(printf '%-19s' "$(countdown_format "$(iso_to_epoch "$expires")")")${RESET}"
  done
}
