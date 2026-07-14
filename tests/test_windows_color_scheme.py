from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "Windows" / "CodexDashboardCore.ps1"
LAUNCHER = ROOT / "Windows" / "CodexDashboard.ps1"


def test_windows_core_uses_segmented_color_renderer():
    text = CORE.read_text()
    for marker in (
        "function New-DashboardSegment",
        "function New-UsageBarSegments",
        "function Write-ColoredDashboardRow",
        "function Write-PlainDashboardRows",
        "function Write-DashboardRows",
        "function Get-CountdownColor",
        "function Get-CreditStatusColor",
        "function Get-AutoResumeColor",
        "Write-Host $text -ForegroundColor $segment.Color -NoNewline",
    ):
        assert marker in text

    assert "Write-Host ($output -join [Environment]::NewLine)" not in text


def test_windows_core_contains_approved_semantic_palette():
    text = CORE.read_text()
    for color in (
        "[ConsoleColor]::Cyan",
        "[ConsoleColor]::Green",
        "[ConsoleColor]::Yellow",
        "[ConsoleColor]::Red",
        "[ConsoleColor]::DarkGray",
        "[ConsoleColor]::Gray",
    ):
        assert color in text


def test_windows_core_has_plain_text_fallback():
    text = CORE.read_text()
    assert "Write-PlainDashboardRows -Rows $Rows" in text
    assert "[Console]::ResetColor()" in text
    assert "[Console]::SetCursorPosition(0,0)" in text


def test_windows_launcher_updates_colored_renderer_overlays_and_version():
    text = LAUNCHER.read_text()
    assert "`$Script:AppVersion = '2.7.0'" in text
    assert "New-AutoResumeRow -Status `$Script:ResumeStatus -Project" in text
    assert "Press A to configure auto-resume | Control+C to exit." in text
