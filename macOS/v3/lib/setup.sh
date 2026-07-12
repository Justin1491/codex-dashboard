#!/usr/bin/env bash

setup_resume_mode_description() {
  case "${1:-}" in
    off) printf 'Dashboard only. No notifications or resume actions.' ;;
    notify) printf 'Notify when Codex becomes available.' ;;
    confirm) printf 'Notify and ask before resuming. Recommended.' ;;
    automatic) printf 'Resume automatically after safety checks pass.' ;;
    *) return 1 ;;
  esac
}

setup_select_resume_mode() {
  local choice

  printf '\nHow should Codex Dashboard handle a cleared rate limit?\n\n' >&2
  printf '  1. Off       - %s\n' "$(setup_resume_mode_description off)" >&2
  printf '  2. Notify    - %s\n' "$(setup_resume_mode_description notify)" >&2
  printf '  3. Confirm   - %s\n' "$(setup_resume_mode_description confirm)" >&2
  printf '  4. Automatic - %s\n' "$(setup_resume_mode_description automatic)" >&2
  printf '\nChoose 1-4 [3]: ' >&2
  read -r choice

  case "${choice:-3}" in
    1) printf 'off' ;;
    2) printf 'notify' ;;
    3|'') printf 'confirm' ;;
    4) printf 'automatic' ;;
    *)
      printf 'Invalid selection.\n' >&2
      return 1
      ;;
  esac
}

setup_apply() {
  local mode="$1"
  local refresh_seconds="$2"
  local project_path="${3:-}"
  local project_name="${4:-}"
  local path backup

  config_validate_resume_mode "$mode" || return 1
  config_validate_refresh_seconds "$refresh_seconds" || return 1

  if [[ -n "$project_path" && ! -d "$project_path" ]]; then
    printf 'Project directory does not exist: %s\n' "$project_path" >&2
    return 1
  fi

  ensure_config || return 1
  path="$(config_path)"
  backup="${path}.setup-backup.$$"
  cp "$path" "$backup" || return 1

  if ! config_set_resume_mode "$mode" ||
     ! config_set_refresh_seconds "$refresh_seconds"; then
    mv "$backup" "$path"
    return 1
  fi

  if [[ -n "$project_path" ]]; then
    if ! project_add "$project_path" "$project_name"; then
      mv "$backup" "$path"
      return 1
    fi
  fi

  config_mark_setup_complete || {
    mv "$backup" "$path"
    return 1
  }

  rm -f "$backup"
}

setup_wizard() {
  local mode refresh_seconds register_answer project_path project_name confirm_answer

  printf 'Codex Dashboard first-run setup\n'
  printf '================================\n'

  if ! load_codex_credentials "$(resolve_auth_path)"; then
    printf '\nSign in to Codex, then run setup again.\n' >&2
    return 1
  fi

  printf '\nCodex authentication found.\n'

  mode="$(setup_select_resume_mode)" || return 1

  printf '\nAPI refresh interval in seconds [60]: '
  read -r refresh_seconds
  refresh_seconds="${refresh_seconds:-60}"
  config_validate_refresh_seconds "$refresh_seconds" || return 1

  printf '\nRegister a default Codex project now? [Y/n] '
  read -r register_answer

  project_path=''
  project_name=''

  if [[ ! "$register_answer" =~ ^[Nn]$ ]]; then
    project_path="$(project_select_folder)" || {
      printf 'No project selected. Setup cancelled.\n'
      return 1
    }

    printf 'Project display name [%s]: ' "$(basename "$project_path")"
    read -r project_name
  fi

  printf '\nSetup summary\n'
  printf '  Resume mode: %s\n' "$mode"
  printf '  Refresh:     %ss\n' "$refresh_seconds"
  if [[ -n "$project_path" ]]; then
    printf '  Project:     %s\n' "$project_path"
  else
    printf '  Project:     none\n'
  fi

  printf '\nSave these settings? [Y/n] '
  read -r confirm_answer
  if [[ "$confirm_answer" =~ ^[Nn]$ ]]; then
    printf 'Setup cancelled. No settings were changed.\n'
    return 1
  fi

  setup_apply "$mode" "$refresh_seconds" "$project_path" "$project_name" || return 1

  printf '\nSetup complete. Run: codex-dashboard\n'
}
