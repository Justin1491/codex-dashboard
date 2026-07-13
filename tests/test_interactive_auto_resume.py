from pathlib import Path
import os
import pty
import select
import shutil
import subprocess
import tempfile
import termios
import time

ROOT = Path(__file__).resolve().parents[1]


def _read_until(fd: int, needle: bytes, timeout: float = 3.0) -> bytes:
    output = bytearray()
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        readable, _, _ = select.select([fd], [], [], 0.1)
        if not readable:
            continue
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        output.extend(chunk)
        if needle in output:
            return bytes(output)
    raise AssertionError(f"Did not receive {needle!r}. Output: {bytes(output)!r}")


def test_macos_launcher_injects_interactive_auto_resume():
    text = (ROOT / "macOS" / "codex-usage-dashboard.sh").read_text()
    assert 'VERSION="2.5.4"' in text
    assert '_codex_configure_auto_resume()' in text
    assert '_codex_poll_interactive_key()' in text
    assert '_codex_enable_key_mode()' in text
    assert '_codex_restore_tty_mode()' in text
    assert '_codex_start_key_listener()' in text
    assert '_codex_stop_key_listener()' in text
    assert 'dd bs=1 count=1' in text
    assert 'stty -icanon min 1 time 0 -echo' in text
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
        assert "version=2.5.4" in result.stdout
        assert "_codex_configure_auto_resume" in result.stdout
        assert f"resolved={tmp_path / 'project'}" in result.stdout
        assert "Press A to configure auto-resume" in result.stdout
        assert "_codex_poll_interactive_key" in result.stdout


def test_macos_background_listener_keeps_loop_alive_and_opens_configuration():
    launcher = ROOT / "macOS" / "codex-usage-dashboard.sh"
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        shutil.copy2(launcher, tmp_path / launcher.name)
        core = tmp_path / "codex-usage-dashboard-core.sh"
        core.write_text(
            '''#!/bin/bash
set -uo pipefail
VERSION="2.3.0"
DIM=''
RESET=''
FOOTER_HELP_ROW=1
AUTO_RESUME=false
RESUME_PROJECT="$PWD"
RESUME_PROMPT='continue'
ALT_SCREEN_ACTIVE=false
CREDIT_COUNT=0
TERM_COLS=120
TERM_ROWS=30
LIMIT_REACHED=false
ALLOWED=true
WAS_BLOCKED=false
AUTO_RESUME_TRIGGERED=false
RESUME_STATUS='Disabled'
CLEANED_UP=false
enter_dashboard_screen() { :; }
leave_dashboard_screen() { :; }
read_terminal_size() { :; }
calculate_layout() { :; }
draw_dashboard() { printf 'DASHBOARD READY\\n'; }
write_rel() { :; }
write_footer_fields() {
  write_rel "$FOOTER_HELP_ROW" 3 "${DIM}Press Control + C to exit.${RESET}"
}
cleanup() {
  if [[ "${CLEANED_UP:-false}" == 'true' ]]; then return; fi
  CLEANED_UP=true
}
trap 'cleanup' EXIT
trap 'exit 0' INT TERM HUP
main() {
  if [[ "$LIMIT_REACHED" == 'true' || "$ALLOWED" != 'true' ]]; then
    WAS_BLOCKED=true
    RESUME_STATUS='Waiting for Codex access to reset'
  else
    RESUME_STATUS='Codex is available'
  fi
  enter_dashboard_screen
  ALT_SCREEN_ACTIVE=true
  draw_dashboard
  while true; do
    if [[ "$LIMIT_REACHED" == 'true' || "$ALLOWED" != 'true' ]]; then
      WAS_BLOCKED=true
      RESUME_STATUS='Waiting for Codex access to reset'
    else
      RESUME_STATUS='Codex is available'
    fi
    printf 'TICK\\n'
    sleep 0.2
  done
}
main
'''
        )
        pid, fd = pty.fork()
        if pid == 0:
            os.chdir(tmp_path)
            os.execve(
                "/bin/bash",
                ["bash", str(tmp_path / launcher.name)],
                {**os.environ, "HOME": str(tmp_path), "BASH_COMPAT": "3.2"},
            )
        try:
            _read_until(fd, b"DASHBOARD READY")
            dashboard_attrs = termios.tcgetattr(fd)
            assert not dashboard_attrs[3] & termios.ICANON
            assert not dashboard_attrs[3] & termios.ECHO

            _read_until(fd, b"TICK")
            time.sleep(0.8)
            readable, _, _ = select.select([fd], [], [], 0.2)
            idle_output = os.read(fd, 4096) if readable else b""
            assert idle_output.count(b"TICK") >= 2

            os.write(fd, b"A")
            output = _read_until(fd, b"Project folder")
            assert b"Configure Automatic Resume" in output

            prompt_attrs = termios.tcgetattr(fd)
            assert prompt_attrs[3] & termios.ICANON
            assert prompt_attrs[3] & termios.ECHO
        finally:
            try:
                os.kill(pid, 15)
            except ProcessLookupError:
                pass
            try:
                os.waitpid(pid, 0)
            except ChildProcessError:
                pass
            restored_attrs = termios.tcgetattr(fd)
            assert restored_attrs[3] & termios.ICANON
            assert restored_attrs[3] & termios.ECHO
            os.close(fd)
