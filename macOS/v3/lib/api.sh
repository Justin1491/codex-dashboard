#!/usr/bin/env bash

CODEX_USAGE_ENDPOINT_DEFAULT='https://chatgpt.com/backend-api/wham/usage'
CODEX_CREDITS_ENDPOINT_DEFAULT='https://chatgpt.com/backend-api/wham/rate-limit-reset-credits'

api_request_json() {
  local endpoint="$1"
  local response

  response="$(
    curl --fail --silent --show-error "$endpoint" \
      -H "Authorization: Bearer $CODEX_ACCESS_TOKEN" \
      -H "ChatGPT-Account-ID: $CODEX_ACCOUNT_ID" \
      -H 'originator: Codex Desktop'
  )" || return 1

  jq empty <<<"$response" >/dev/null 2>&1 || return 1
  printf '%s' "$response"
}

fetch_usage_json() {
  api_request_json "${CODEX_USAGE_ENDPOINT:-$CODEX_USAGE_ENDPOINT_DEFAULT}"
}

fetch_credits_json() {
  api_request_json "${CODEX_CREDITS_ENDPOINT:-$CODEX_CREDITS_ENDPOINT_DEFAULT}"
}

refresh_raw_state() {
  local usage_json
  local credits_json

  usage_json="$(fetch_usage_json)" || return 1

  if credits_json="$(fetch_credits_json)"; then
    :
  else
    credits_json='{}'
  fi

  RAW_USAGE_JSON="$usage_json"
  RAW_CREDITS_JSON="$credits_json"
  export RAW_USAGE_JSON RAW_CREDITS_JSON
}
