#!/usr/bin/env bash

resume_state_dir() {
  printf '%s' "${CODEX_DASHBOARD_STATE_DIR:-$HOME/.local/state/codex-dashboard}"
}

resume_log_dir() {
  printf '%s/logs' "$(resume_state_dir)"
}

resume_event_id() {
  local reset_epoch="${1:-0}"
  printf 'five-hour-%s' "$reset_epoch"
}

resume_is_codex_running() {
  pgrep -f 'codex exec resume' >/dev/null 2>&1
}

resume_git_status() {
  local project_path="$1"

  if git -C "$project_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$project_path" status --porcelain 2>/dev/null || true
  fi
}

resume_safety_check() {
  local project_path="$1"

  [[ -d "$project_path" ]] || {
    RESUME_BLOCK_REASON="Project directory is missing: $project_path"
    return 1
  }

  if resume_is_codex_running; then
    RESUME_BLOCK_REASON='Another Codex resume process is already running.'
    return 1
  fi

  RESUME_GIT_STATUS="$(resume_git_status "$project_path")"
  RESUME_BLOCK_REASON=''
  return 0
}

resume_mark_event_handled() {
  local event_id="$1"
  config_update '.resume.lastHandledEventId = $eventId' --arg eventId "$event_id"
}

resume_event_was_handled() {
  local event_id="$1"
  [[ "$(config_get '.resume.lastHandledEventId // empty')" == "$event_id" ]]
}

resume_launch() {
  local project_path="$1"
  local prompt="$2"
  local log_dir log_file

  mkdir -p "$(resume_log_dir)"
  log_dir="$(resume_log_dir)"
  log_file="$log_dir/resume-$(date +%Y%m%d-%H%M%S).log"

  (
    cd "$project_path"
    codex exec resume --last "$prompt"
  ) >"$log_file" 2>&1 &

  RESUME_PID=$!
  RESUME_LOG_FILE="$log_file"
  export RESUME_PID RESUME_LOG_FILE
}

resume_handle_transition() {
  local previous_allowed="$1"
  local current_allowed="$2"
  local reset_epoch="$3"
  local mode="$4"
  local project_json="$5"
  local event_id project_name project_path prompt answer

  [[ "$previous_allowed" == 'false' && "$current_allowed" == 'true' ]] || return 0
  [[ "$mode" != 'off' ]] || return 0

  event_id="$(resume_event_id "$reset_epoch")"
  resume_event_was_handled "$event_id" && return 0

  if [[ -z "$project_json" ]]; then
    printf 'Codex is available, but no default project is configured.\n' >&2
    return 1
  fi

  project_name="$(jq -r '.name' <<<"$project_json")"
  project_path="$(jq -r '.path' <<<"$project_json")"
  prompt="$(config_get '.resume.prompt')"

  if [[ "$mode" == 'notify' ]]; then
    printf '\aCodex is available again for project: %s\n' "$project_name"
    resume_mark_event_handled "$event_id"
    return 0
  fi

  resume_safety_check "$project_path" || {
    printf 'Resume blocked: %s\n' "$RESUME_BLOCK_REASON" >&2
    return 1
  }

  if [[ "$mode" == 'confirm' ]]; then
    printf '\nCodex is available again.\n'
    printf 'Project: %s\nPath: %s\n' "$project_name" "$project_path"
    if [[ -n "$RESUME_GIT_STATUS" ]]; then
      printf 'Git status:\n%s\n' "$RESUME_GIT_STATUS"
    else
      printf 'Git status: clean or not a Git repository\n'
    fi
    printf 'Resume the most recent Codex session? [y/N] '
    read -r answer
    [[ "$answer" == 'y' || "$answer" == 'Y' ]] || {
      resume_mark_event_handled "$event_id"
      return 0
    }
  elif [[ "$mode" == 'automatic' && -n "$RESUME_GIT_STATUS" ]]; then
    printf 'Automatic resume blocked because the Git working tree has changes.\n' >&2
    return 1
  fi

  command -v codex >/dev/null 2>&1 || {
    printf 'Codex CLI is not installed or not on PATH.\n' >&2
    return 1
  }

  resume_launch "$project_path" "$prompt"
  resume_mark_event_handled "$event_id"
  printf 'Started Codex resume. Log: %s\n' "$RESUME_LOG_FILE"
}
