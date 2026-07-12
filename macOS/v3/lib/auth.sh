#!/usr/bin/env bash

resolve_auth_path() {
  printf '%s/auth.json' "${CODEX_HOME:-$HOME/.codex}"
}

load_codex_credentials() {
  local auth_path="${1:-$(resolve_auth_path)}"

  [[ -f "$auth_path" ]] || {
    printf 'Codex authentication file not found: %s\n' "$auth_path" >&2
    return 1
  }

  jq empty "$auth_path" >/dev/null 2>&1 || {
    printf 'Codex authentication file contains invalid JSON: %s\n' "$auth_path" >&2
    return 1
  }

  CODEX_ACCESS_TOKEN="$(jq -r '.tokens.access_token // empty' "$auth_path")"
  CODEX_ACCOUNT_ID="$(jq -r '.tokens.account_id // empty' "$auth_path")"

  [[ -n "$CODEX_ACCESS_TOKEN" ]] || {
    printf 'Codex access token is missing from: %s\n' "$auth_path" >&2
    return 1
  }

  [[ -n "$CODEX_ACCOUNT_ID" ]] || {
    printf 'Codex account ID is missing from: %s\n' "$auth_path" >&2
    return 1
  }

  export CODEX_ACCESS_TOKEN CODEX_ACCOUNT_ID
}
