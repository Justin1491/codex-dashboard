from pathlib import Path
import os
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def test_macos_launcher_injects_interactive_auto_resume():
    text = (ROOT / "macOS" / "codex-usage-dashboard.sh").read_text()
    assert 'VERSION="2.5.0"' in text
    assert '_codex_configure_auto_resume()' in text
    assert '_codex_poll_interactive_key()' in text
    assert 'Press A to configure auto-resume | Control+C to exit.' in text
    assert 'Project directory not found:' in text
    assert 'AUTO_RESUME=true' in text
    assert 'RESUME_PROJECT="$candidate"' in text


def test_macos_overlay_is_loaded_without_command_substitution():
    text = (ROOT / "macOS" / "codex-usage-dashboard.sh").read_text()
    assert 'interactive_overlay="$(cat <<\'EOF_OVERLAY\'' not in text
    assert "IFS= read -r -d '' interactive_overlay <<'EOF_OVERLAY' || true" in text


def test_windows_launcher_injects_interactive_auto_resume():
    text = (ROOT / "Windows" / "CodexDashboard.ps1").read_text()
    assert "`$Script:AppVersion = '2.5.0'" in text
    assert 'function Invoke-AutoResumeConfiguration' in text
    assert 'function Test-InteractiveDashboardKey' in text
    assert 'Press A to configure auto-resume | Control+C to exit.' in text
    assert 'Project directory not found:' in text
    assert '$Script:AutoResumeEnabled = $true' in text
    assert '$Script:ResumeProject = $candidate' in text
    assert '$autoResumeLine += " | Project: $($Script:ResumeProject)"' in text


def test_existing_command_line_controls_remain_available():
    mac = (ROOT / "macOS" / "codex-usage-dashboard.sh").read_text()
    windows = (ROOT / "Windows" / "CodexDashboard.ps1").read_text()
    assert '"$@"' in mac
    assert '& $coreScript @PSBoundParameters' in windows
    assert '--auto-resume' in mac
    assert '[switch]$AutoResume' in windows


def test_macos_launcher_transforms_and_executes_core_overlay():
    launcher = ROOT / "macOS" / "codex-usage-dashboard.sh"
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        shutil.copy2(launcher, tmp_path / launcher.name)
        (tmp_path / "project").mkdir()
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
printf 'version=%s\\n' "$VERSION"
declare -F _codex_configure_auto_resume
printf 'resolved=%s\n' "$(_codex_resolve_project_path '~/project')"
declare -f write_footer_fields
declare -f main_loop_fixture
'''
        )
        result = subprocess.run(
            ["bash", str(tmp_path / launcher.name)],
            cwd=tmp_path,
            env={**os.environ, "HOME": str(tmp_path)},
            text=True,
            capture_output=True,
            check=True,
        )
        assert "version=2.5.0" in result.stdout
        assert "_codex_configure_auto_resume" in result.stdout
        assert f"resolved={tmp_path / 'project'}" in result.stdout
        assert "Press A to configure auto-resume" in result.stdout
        assert "_codex_poll_interactive_key" in result.stdout
