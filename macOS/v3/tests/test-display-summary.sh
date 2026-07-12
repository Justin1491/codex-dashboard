#!/usr/bin/env bash
set -uo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$TEST_DIR/.." && pwd -P)"

RESET=''
BOLD=''
DIM=''
GREEN=''
YELLOW=''
CYAN=''
RED=''

source "$ROOT/lib/display.sh"

TESTS_RUN=0
TESTS_FAILED=0

assert_equal() {
  local expected="$1" actual="$2" message="$3"
  TESTS_RUN=$((TESTS_RUN + 1))

  if [[ "$expected" == "$actual" ]]; then
    printf 'PASS: %s\n' "$message"
  else
    printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' \
      "$message" "$expected" "$actual" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

printf '\n== Resume action copy ==\n'
assert_equal \
  'Dashboard only; no resume action' \
  "$(display_resume_action_text off)" \
  'describes off mode'
assert_equal \
  'Notify when Codex becomes available' \
  "$(display_resume_action_text notify)" \
  'describes notify mode'
assert_equal \
  'Ask before resuming the latest safe Codex session' \
  "$(display_resume_action_text confirm)" \
  'describes confirm mode'
assert_equal \
  'Automatically resume the latest safe Codex session' \
  "$(display_resume_action_text automatic)" \
  'describes automatic mode'

printf '\n== Project summary ==\n'
tmp="$(mktemp -d)"
project_json="$(jq -cn --arg id chatpaste --arg name ChatPaste --arg path "$tmp" \
  '{id:$id,name:$name,path:$path}')"
assert_equal 'ChatPaste' "$(display_project_name "$project_json")" 'shows project name'
assert_equal "$tmp" "$(display_project_path "$project_json")" 'shows project path'
assert_equal 'Ready (folder exists)' \
  "$(display_project_readiness "$project_json")" \
  'recognizes an existing project folder'

missing_json="$(jq -cn --arg path "$tmp/missing" '{id:"missing",name:"Missing",path:$path}')"
assert_equal 'Missing folder' \
  "$(display_project_readiness "$missing_json")" \
  'warns when the configured folder is missing'

assert_equal 'Not configured' "$(display_project_name '')" 'handles no default project'
assert_equal 'Not configured' "$(display_project_path '')" 'handles no project path'
assert_equal 'No default project' \
  "$(display_project_readiness '')" \
  'handles no default project readiness'

rm -rf "$tmp"

printf '\n%d tests, %d failures\n' "$TESTS_RUN" "$TESTS_FAILED"
((TESTS_FAILED == 0))
