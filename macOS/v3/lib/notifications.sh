#!/usr/bin/env bash

notification_escape() {
  printf '%s' "${1:-}" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

notify_user() {
  local title="${1:-Codex Dashboard}"
  local message="${2:-}"
  local escaped_title escaped_message

  if [[ -n "${CODEX_DASHBOARD_NOTIFICATION_CAPTURE:-}" ]]; then
    printf '%s\t%s\n' "$title" "$message" >>"$CODEX_DASHBOARD_NOTIFICATION_CAPTURE"
    return 0
  fi

  command -v osascript >/dev/null 2>&1 || return 0

  escaped_title="$(notification_escape "$title")"
  escaped_message="$(notification_escape "$message")"

  osascript -e "display notification \"$escaped_message\" with title \"$escaped_title\"" \
    >/dev/null 2>&1 || true
}
