from pathlib import Path
import json
import os
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def _run_macos_normalizer(payload: dict, cache: dict | None = None) -> tuple[dict, dict]:
    launcher = ROOT / "macOS" / "codex-usage-dashboard.sh"
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        shutil.copy2(launcher, tmp_path / launcher.name)
        core = tmp_path / "codex-usage-dashboard-core.sh"
        core.write_text(
            '''#!/bin/bash
VERSION="2.3.0"
DIM=''
RESET=''
FOOTER_HELP_ROW=1
AUTO_RESUME=false
RESUME_PROJECT="$PWD"
ALT_SCREEN_ACTIVE=false
CREDIT_COUNT=0
TERM_COLS=120
TERM_ROWS=30
LIMIT_REACHED=false
ALLOWED=true
WAS_BLOCKED=false
AUTO_RESUME_TRIGGERED=false
RESUME_STATUS='Disabled'
enter_dashboard_screen() { :; }
leave_dashboard_screen() { :; }
read_terminal_size() { :; }
calculate_layout() { :; }
draw_dashboard() { :; }
write_rel() { printf '%s\\n' "$3"; }
write_footer_fields() {
  write_rel "$FOOTER_HELP_ROW" 3 "${DIM}Press Control + C to exit.${RESET}"
}
cleanup() { :; }
main_loop_fixture() {
  while false; do
    sleep 0.2
  done
}
printf 'normalized=%s\\n' "$(_codex_normalize_usage "$SAMPLE_USAGE")"
'''
        )
        codex_home = tmp_path / ".codex"
        codex_home.mkdir()
        cache_path = codex_home / "dashboard-window-cache.json"
        if cache is not None:
            cache_path.write_text(json.dumps(cache))
        result = subprocess.run(
            ["bash", str(tmp_path / launcher.name)],
            cwd=tmp_path,
            env={
                **os.environ,
                "HOME": str(tmp_path),
                "CODEX_HOME": str(codex_home),
                "SAMPLE_USAGE": json.dumps(payload, separators=(",", ":")),
            },
            text=True,
            capture_output=True,
            check=True,
        )
        line = next(line for line in result.stdout.splitlines() if line.startswith("normalized="))
        normalized = json.loads(line.removeprefix("normalized="))
        saved_cache = json.loads(cache_path.read_text())
        return normalized, saved_cache


def test_current_seconds_schema_overrides_stale_cache_and_keeps_used_percent_semantics():
    payload = {
        "plan_type": "prolite",
        "rate_limit": {
            "allowed": True,
            "limit_reached": False,
            "primary_window": {
                "used_percent": 19,
                "limit_window_seconds": 604800,
                "reset_after_seconds": 508343,
                "reset_at": 1784497992,
            },
            "secondary_window": None,
        },
    }
    normalized, cache = _run_macos_normalizer(
        payload,
        cache={"primary": {"reset_at": 1784497992, "kind": "short"}},
    )
    assert normalized["rate_limit"]["primary_window"] is None
    weekly = normalized["rate_limit"]["secondary_window"]
    assert weekly["window_minutes"] == 10080
    assert weekly["used_percent"] == 19
    assert cache["primary"]["kind"] == "weekly"


def test_explicit_remaining_percent_is_converted_to_used_percent_for_the_legacy_core():
    payload = {
        "rate_limit": {
            "allowed": True,
            "limit_reached": False,
            "primary_window": {
                "remaining_percent": 81,
                "used_percent": 99,
                "limit_window_seconds": 604800,
                "reset_at": 1784497992,
            },
            "secondary_window": None,
        }
    }
    normalized, _ = _run_macos_normalizer(payload)
    weekly = normalized["rate_limit"]["secondary_window"]
    assert weekly["used_percent"] == 19


def test_legacy_minutes_schema_keeps_used_percent_semantics():
    payload = {
        "rate_limit": {
            "allowed": True,
            "limit_reached": False,
            "primary_window": {
                "used_percent": 20,
                "window_minutes": 300,
                "reset_at": 1784000000,
            },
            "secondary_window": None,
        }
    }
    normalized, cache = _run_macos_normalizer(payload)
    short = normalized["rate_limit"]["primary_window"]
    assert short["used_percent"] == 20
    assert short["window_minutes"] == 300
    assert normalized["rate_limit"]["secondary_window"] is None
    assert cache["primary"]["kind"] == "short"


def test_windows_launcher_distinguishes_used_and_remaining_fields():
    text = (ROOT / "Windows" / "CodexDashboard.ps1").read_text()
    assert "Normalize-WindowForCore" in text
    assert "limit_window_seconds" in text
    assert "Get-NormalizedProperty $Window @('remaining_percent','remainingPercent') $null" in text
    assert "Get-NormalizedProperty $Window @('used_percent','usedPercent') 0" in text
    assert "Set-NormalizedProperty -Object $Window -Name 'window_minutes'" in text
    assert "Set-NormalizedProperty -Object $Window -Name 'used_percent' -Value $used" in text
    assert "`$Script:AppVersion = '2.7.0'" in text
