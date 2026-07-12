#!/usr/bin/env bash

config_dir() {
  printf '%s' "${CODEX_DASHBOARD_CONFIG_DIR:-$HOME/.config/codex-dashboard}"
}

config_path() {
  printf '%s/config.json' "$(config_dir)"
}

config_exists() {
  [[ -f "$(config_path)" ]]
}

default_config_json() {
  cat <<'JSON'
{
  "version": 1,
  "setupComplete": false,
  "refreshSeconds": 60,
  "resumeMode": "confirm",
  "defaultProjectId": null,
  "projects": [],
  "display": {
    "compact": false,
    "showSeconds": true
  },
  "resume": {
    "prompt": "The rate limit has reset. Review the repository and continue from the last safe point without repeating completed work.",
    "lastHandledEventId": null
  }
}
JSON
}

validate_config_json() {
  local path="${1:-$(config_path)}"

  [[ -f "$path" ]] || return 1
  jq empty "$path" >/dev/null 2>&1 || return 1

  jq -e '
    .resumeMode as $mode |
    .version == 1 and
    ((.setupComplete // false) | type == "boolean") and
    (.refreshSeconds | type == "number") and
    (.refreshSeconds >= 1) and
    (["off", "notify", "confirm", "automatic"] | index($mode)) != null and
    (.projects | type == "array") and
    (.display | type == "object") and
    (.resume | type == "object")
  ' "$path" >/dev/null 2>&1
}

config_migrate() {
  local path temp
  path="$(config_path)"
  temp="${path}.migrate.$$"

  jq '
    if has("setupComplete") then .
    else . + {setupComplete: true}
    end
  ' "$path" >"$temp" || {
    rm -f "$temp"
    return 1
  }

  mv "$temp" "$path"
  chmod 600 "$path"
}

ensure_config() {
  local dir path
  dir="$(config_dir)"
  path="$(config_path)"

  mkdir -p "$dir"

  if [[ ! -f "$path" ]]; then
    default_config_json >"$path"
    chmod 600 "$path"
  else
    config_migrate || return 1
  fi

  validate_config_json "$path" || {
    printf 'Configuration is invalid: %s\n' "$path" >&2
    printf 'Run: codex-dashboard config reset\n' >&2
    return 1
  }
}

config_show() {
  ensure_config || return 1
  jq . "$(config_path)"
}

config_reset() {
  local path
  path="$(config_path)"
  mkdir -p "$(config_dir)"
  default_config_json >"$path"
  chmod 600 "$path"
  printf 'Configuration reset: %s\n' "$path"
}

config_get() {
  local expression="$1"
  ensure_config || return 1
  jq -r "$expression" "$(config_path)"
}

config_update() {
  local filter="$1"
  shift
  local path temp
  path="$(config_path)"
  temp="${path}.tmp.$$"

  ensure_config || return 1
  jq "$@" "$filter" "$path" >"$temp" || {
    rm -f "$temp"
    return 1
  }
  mv "$temp" "$path"
  chmod 600 "$path"
}

config_validate_resume_mode() {
  case "${1:-}" in
    off|notify|confirm|automatic) return 0 ;;
    *)
      printf 'Invalid resume mode: %s\n' "${1:-}" >&2
      printf 'Choose: off, notify, confirm, or automatic.\n' >&2
      return 1
      ;;
  esac
}

config_validate_refresh_seconds() {
  local seconds="${1:-}"
  [[ "$seconds" =~ ^[1-9][0-9]*$ ]] || {
    printf 'Refresh interval must be a positive whole number.\n' >&2
    return 1
  }
}

config_set_resume_mode() {
  local mode="${1:-}"
  config_validate_resume_mode "$mode" || return 1
  config_update '.resumeMode = $mode' --arg mode "$mode"
  printf 'Resume mode set to: %s\n' "$mode"
}

config_set_refresh_seconds() {
  local seconds="${1:-}"
  config_validate_refresh_seconds "$seconds" || return 1
  config_update '.refreshSeconds = $seconds' --argjson seconds "$seconds"
  printf 'Refresh interval set to: %ss\n' "$seconds"
}

config_mark_setup_complete() {
  config_update '.setupComplete = true'
}
