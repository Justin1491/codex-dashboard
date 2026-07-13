from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_macos_key_poll_avoids_fractional_read_timeout():
    text = (ROOT / "macOS" / "codex-usage-dashboard.sh").read_text()
    assert "read -r -s -n 1 -t" not in text
    assert "read -r -s -n 1 key </dev/tty" in text
    assert "stty -icanon min 0 time 0 -echo" in text
    assert 'VERSION="2.5.2"' in text
