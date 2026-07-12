#!/usr/bin/env bash
set -uo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$TEST_DIR/.." && pwd -P)"
FIXTURES="$TEST_DIR/fixtures"
COMMAND_FILE="$ROOT/bin/codex-dashboard"

source "$ROOT/lib/auth.sh"
source "$ROOT/lib/model.sh"
source "$ROOT/lib/countdown.sh"
source "$ROOT/lib/config.sh"
source "$ROOT/lib/projects.sh"
source "$ROOT/lib/notifications.sh"
source "$ROOT/lib/resume.sh"
source "$ROOT/lib/setup.sh"

TESTS_RUN=0
TESTS_FAILED=0

assert_equal() {
  local expected="$1" actual="$2" message="$3"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ "$expected" == "$actual" ]]; then
    printf 'PASS: %s\n' "$message"
  else
    printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$message" "$expected" "$actual" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

assert_success() {
  local message="$1"
  shift
  TESTS_RUN=$((TESTS_RUN + 1))
  if "$@"; then
    printf 'PASS: %s\n' "$message"
  else
    printf 'FAIL: %s\n' "$message" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

assert_failure() {
  local message="$1"
  shift
  TESTS_RUN=$((TESTS_RUN + 1))
  if "$@"; then
    printf 'FAIL: %s\n' "$message" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
  else
    printf 'PASS: %s\n' "$message"
  fi
}

assert_file_contains() {
  local file="$1" pattern="$2" message="$3"
  TESTS_RUN=$((TESTS_RUN + 1))
  if grep -Fq -- "$pattern" "$file"; then
    printf 'PASS: %s\n' "$message"
  else
    printf 'FAIL: %s\n  missing pattern: %s\n' "$message" "$pattern" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

printf '\n== Authentication ==\n'
auth_tmp="$(mktemp -d)"
mkdir -p "$auth_tmp/.codex"
printf '%s\n' '{"tokens":{"access_token":"test-token","account_id":"test-account"}}' >"$auth_tmp/.codex/auth.json"
assert_equal "$auth_tmp/.codex/auth.json" "$(HOME="$auth_tmp" resolve_auth_path)" 'resolves default auth path'
assert_success 'loads valid credentials' load_codex_credentials "$auth_tmp/.codex/auth.json"
assert_equal 'test-token' "$CODEX_ACCESS_TOKEN" 'loads access token'
assert_equal 'test-account' "$CODEX_ACCOUNT_ID" 'loads account ID'
assert_failure 'rejects missing auth file' load_codex_credentials "$auth_tmp/missing.json"
rm -rf "$auth_tmp"

printf '\n== Countdown ==\n'
assert_equal '1d 01h 01m 01s' "$(countdown_format 90061 0)" 'formats day/hour/minute/second countdown'
assert_equal 'READY' "$(countdown_format 100 100)" 'returns ready at expiration'
assert_equal 'UNKNOWN' "$(countdown_format 0 100)" 'returns unknown for missing expiration'

printf '\n== Model ==\n'
usage="$(cat "$FIXTURES/usage-rate-limited.json")"
credits="$(cat "$FIXTURES/credits-multiple.json")"
state="$(normalize_codex_state "$usage" "$credits")"
assert_equal 'prolite' "$(jq -r '.plan' <<<"$state")" 'normalizes plan'
assert_equal '0' "$(jq -r '.usageWindows[0].remainingPercent' <<<"$state")" 'calculates five-hour remaining'
assert_equal '68' "$(jq -r '.usageWindows[1].remainingPercent' <<<"$state")" 'calculates weekly remaining'
assert_equal '2' "$(jq -r '.resetCredits.records | length' <<<"$state")" 'normalizes credit records'
missing="$(normalize_codex_state "$(cat "$FIXTURES/usage-missing-fields.json")" '{}')"
assert_equal 'unknown' "$(jq -r '.plan' <<<"$missing")" 'defaults missing plan'
assert_equal '100' "$(jq -r '.usageWindows[0].remainingPercent' <<<"$missing")" 'defaults missing usage window'

printf '\n== Configuration, setup, and projects ==\n'
config_tmp="$(mktemp -d)"
export CODEX_DASHBOARD_CONFIG_DIR="$config_tmp/config"
mkdir -p "$config_tmp/Project One" "$config_tmp/Project Two"
assert_success 'creates default config' ensure_config
assert_equal 'confirm' "$(config_get '.resumeMode')" 'uses safe default resume mode'
assert_equal 'false' "$(config_get '.setupComplete')" 'new config requires first-run setup'
assert_success 'sets notify resume mode' config_set_resume_mode notify
assert_equal 'notify' "$(config_get '.resumeMode')" 'stores notify resume mode'
assert_failure 'rejects invalid resume mode' config_set_resume_mode reckless
assert_success 'sets refresh interval' config_set_refresh_seconds 30
assert_equal '30' "$(config_get '.refreshSeconds')" 'stores refresh interval'
assert_success 'adds project' project_add "$config_tmp/Project One" 'Project One'
assert_equal '1' "$(jq '.projects | length' "$(config_path)")" 'stores project'
assert_equal 'project-one' "$(jq -r '.defaultProjectId' "$(config_path)")" 'sets first project as default'
assert_failure 'rejects duplicate project' project_add "$config_tmp/Project One" 'Project One'
export CODEX_DASHBOARD_FOLDER_PICKER_RESULT="$config_tmp/Project Two"
expected_picker_path="$(cd "$config_tmp/Project Two" && pwd -P)"
assert_equal "$expected_picker_path" "$(project_select_folder)" 'folder picker returns selected project'
unset CODEX_DASHBOARD_FOLDER_PICKER_RESULT
assert_success 'removes project' project_remove 'project-one'
assert_equal '0' "$(jq '.projects | length' "$(config_path)")" 'removes project from config'
assert_success 'applies confirmed setup atomically' setup_apply automatic 45 "$config_tmp/Project Two" 'Project Two'
assert_equal 'true' "$(config_get '.setupComplete')" 'marks setup complete'
assert_equal 'automatic' "$(config_get '.resumeMode')" 'automatic mode requires explicit setup selection'
assert_equal '45' "$(config_get '.refreshSeconds')" 'setup stores refresh interval'

printf '\n== Notifications ==\n'
notification_file="$config_tmp/notifications.log"
export CODEX_DASHBOARD_NOTIFICATION_CAPTURE="$notification_file"
assert_success 'captures notification' notify_user 'Codex Dashboard' 'Codex is available.'
assert_file_contains "$notification_file" $'Codex Dashboard\tCodex is available.' 'stores notification title and message'
unset CODEX_DASHBOARD_NOTIFICATION_CAPTURE

printf '\n== Resume state ==\n'
export CODEX_DASHBOARD_STATE_DIR="$config_tmp/state"
assert_equal 'five-hour-1234' "$(resume_event_id 1234)" 'creates stable reset event ID'
assert_success 'accepts existing project path' resume_safety_check "$config_tmp"
resume_mark_event_handled 'five-hour-1234'
assert_success 'recognizes handled reset event' resume_event_was_handled 'five-hour-1234'
rm -rf "$config_tmp"

printf '\n== Dashboard exit handling ==\n'
assert_file_contains "$COMMAND_FILE" 'trap dashboard_cleanup EXIT' 'registers cleanup for normal exit'
assert_file_contains "$COMMAND_FILE" 'trap dashboard_handle_interrupt INT' 'registers terminating interrupt handler'
assert_file_contains "$COMMAND_FILE" 'trap dashboard_handle_terminate TERM' 'registers terminating terminate handler'
assert_file_contains "$COMMAND_FILE" 'exit 130' 'interrupt handler exits the process'
assert_file_contains "$COMMAND_FILE" 'exit 143' 'terminate handler exits the process'

printf '\n%d tests, %d failures\n' "$TESTS_RUN" "$TESTS_FAILED"
((TESTS_FAILED == 0))
