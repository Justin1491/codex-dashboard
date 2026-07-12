#!/usr/bin/env bash

config_dir() {
  printf '%s' "${CODEX_DASHBOARD_CONFIG_DIR:-$HOME/.config/codex-dashboard}"
}

config_path() {
  printf '%s/config.json' "$(config_dir)"
}

default_config_json() {
  cat <<'JSON'
{
  "version": 1,
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
    (.refreshSeconds | type == "number") and
    (.refreshSeconds >= 1) and
    (["off", "notify", "confirm", "automatic"] | index($mode)) != null and
    (.projects | type == "array") and
    (.display | type == "object") and
    (.resume | type == "object")
  ' "$path" >/dev/null 2>&1
}

ensure_config() {
  local dir path
  dir="$(config_dir)"
  path="$(config_path)"

  mkdir -p "$dir"

  if [[ ! -f "$path" ]]; then
    default_config_json >"$path"
    chmod 600 "$path"
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
