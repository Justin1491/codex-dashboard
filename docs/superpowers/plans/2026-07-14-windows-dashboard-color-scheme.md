# Windows Dashboard Color Scheme Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the Windows Codex Dashboard the same semantic color hierarchy as the macOS dashboard without changing layout, data, refresh behavior, keyboard controls, or auto-resume behavior.

**Architecture:** Keep the existing fixed-width layout calculations, but replace the single plain-text screen write with rows composed of colored text segments. One row model will drive both colored output and the plain-text fallback, preventing alignment or information drift between the two paths. The compatibility launcher will continue injecting interactive auto-resume behavior and will update its render-call substitutions for the new row helpers.

**Tech Stack:** PowerShell 7 / Windows PowerShell-compatible syntax, .NET `ConsoleColor`, Python `pytest` source-contract tests, existing GitHub repository workflow.

## Global Constraints

- Change only Windows rendering and Windows launcher overlays; do not modify macOS behavior.
- Use standard `ConsoleColor` values only: `Cyan`, `Green`, `Yellow`, `Red`, `DarkGray`, `Gray`, and `White` where needed.
- Do not add ANSI escape sequences, custom RGB values, or external dependencies.
- Preserve the current fixed-width layout, terminal-size requirements, refresh cadence, usage calculations, reset times, credits, keyboard controls, and auto-resume behavior.
- Every colored row must have a plain-text representation generated from the same segment data.
- A failed colored write must clear/reposition the console and redraw the complete dashboard in plain text.
- Increase the Windows dashboard display version from `2.6.0` to `2.7.0`; keep launcher filenames version-neutral.
- A real PowerShell 7 run on Windows is required for final visual validation.

---

## File Structure

- Modify `Windows/CodexDashboardCore.ps1`: define the segment model, semantic color helpers, colored/plain writers, and refactor `Render-Dashboard` to emit colored rows.
- Modify `Windows/CodexDashboard.ps1`: update the display version to `2.7.0`, adapt interactive footer/project substitutions to the new row-based renderer, and retain all current normalization and auto-resume overlays.
- Create `tests/test_windows_color_scheme.py`: assert the semantic palette, segmented renderer, fallback path, version, and updated launcher substitutions.
- Modify `tests/test_interactive_auto_resume.py`: update the expected Windows version while preserving all interactive markers.
- Use existing `tests/test_windows_dashboard_structure.py` and `tests/test_current_usage_schema.py` as regression coverage without changing their responsibilities.

---

### Task 1: Add Failing Windows Color-Renderer Contract Tests

**Files:**
- Create: `tests/test_windows_color_scheme.py`
- Modify: `tests/test_interactive_auto_resume.py:53-62`
- Test: `tests/test_windows_color_scheme.py`

**Interfaces:**
- Consumes: current PowerShell source files as UTF-8 text.
- Produces: source-contract expectations for `New-DashboardSegment`, `New-UsageBarSegments`, `Write-ColoredDashboardRow`, `Write-PlainDashboardRows`, `Write-DashboardRows`, semantic color helpers, the fallback path, and launcher version `2.7.0`.

- [ ] **Step 1: Write the failing color-renderer tests**

Create `tests/test_windows_color_scheme.py` with:

```python
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
```

Update the Windows assertion in `tests/test_interactive_auto_resume.py`:

```python
def test_windows_launcher_injects_interactive_auto_resume():
    text = (ROOT / "Windows" / "CodexDashboard.ps1").read_text()
    assert "`$Script:AppVersion = '2.7.0'" in text
    assert 'function Invoke-AutoResumeConfiguration' in text
    assert 'function Test-InteractiveDashboardKey' in text
    assert 'Press A to configure auto-resume | Control+C to exit.' in text
    assert 'Project directory not found:' in text
    assert '$Script:AutoResumeEnabled = $true' in text
    assert '$Script:ResumeProject = $candidate' in text
    assert '$autoResumeLine += " | Project: $($Script:ResumeProject)"' not in text
```

- [ ] **Step 2: Run the new tests and verify they fail**

Run:

```bash
pytest -q tests/test_windows_color_scheme.py tests/test_interactive_auto_resume.py::test_windows_launcher_injects_interactive_auto_resume
```

Expected: failures for missing segmented-renderer functions and because the launcher still injects version `2.6.0`.

- [ ] **Step 3: Commit the failing tests**

```bash
git add tests/test_windows_color_scheme.py tests/test_interactive_auto_resume.py
git commit -m "test: define Windows dashboard color contract"
```

---

### Task 2: Add the Segment Model, Palette Helpers, and Fallback Writers

**Files:**
- Modify: `Windows/CodexDashboardCore.ps1:204-226`
- Test: `tests/test_windows_color_scheme.py`

**Interfaces:**
- Consumes: formatted strings from the existing dashboard and standard `ConsoleColor` values.
- Produces:
  - `New-DashboardSegment -Text <string> -Color <ConsoleColor> -> PSCustomObject`
  - `Get-DashboardRowText -Segments <object[]> -> string`
  - `New-UsageBarSegments -Remaining <int> -Width <int> -> object[]`
  - `Get-CountdownColor -Countdown <string> -> ConsoleColor`
  - `Get-CreditStatusColor -Status <string> -> ConsoleColor`
  - `Get-AutoResumeColor -Status <string> -> ConsoleColor`
  - `Write-ColoredDashboardRow -Segments <object[]> -Pad <string> -Canvas <int> -ScreenWidth <int>`
  - `Write-PlainDashboardRows -Rows <IEnumerable> -Pad <string> -Canvas <int> -ScreenWidth <int>`
  - `Write-DashboardRows -Rows <IEnumerable> -Pad <string> -Canvas <int> -ScreenWidth <int>`

- [ ] **Step 1: Add the segment and semantic color helpers**

Insert the following immediately after `Center-Line` in `Windows/CodexDashboardCore.ps1`:

```powershell
function New-DashboardSegment {
    param(
        [AllowEmptyString()][string]$Text,
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )
    [pscustomobject]@{ Text = $Text; Color = $Color }
}

function Get-DashboardRowText {
    param([object[]]$Segments)
    -join @($Segments | ForEach-Object { [string]$_.Text })
}

function New-UsageBarSegments {
    param([int]$Remaining, [int]$Width = 20)
    $remainingValue = [math]::Max(0,[math]::Min(100,$Remaining))
    $filled = [int][math]::Floor($remainingValue * $Width / 100)
    $empty = $Width - $filled
    @(
        New-DashboardSegment -Text '[' -Color ([ConsoleColor]::Gray)
        New-DashboardSegment -Text ('#' * $filled) -Color ([ConsoleColor]::Green)
        New-DashboardSegment -Text ('-' * $empty) -Color ([ConsoleColor]::DarkGray)
        New-DashboardSegment -Text ']' -Color ([ConsoleColor]::Gray)
    )
}

function Get-CountdownColor {
    param([string]$Countdown)
    if ($Countdown -eq 'Ready') { return [ConsoleColor]::Green }
    if ($Countdown -eq 'Unknown') { return [ConsoleColor]::Red }
    return [ConsoleColor]::Yellow
}

function Get-CreditStatusColor {
    param([string]$Status)
    if ($Status -match '(?i)available|active|unused') { return [ConsoleColor]::Green }
    if ($Status -match '(?i)pending|waiting|queued') { return [ConsoleColor]::Yellow }
    if ($Status -match '(?i)expired|failed|invalid|revoked') { return [ConsoleColor]::Red }
    return [ConsoleColor]::Gray
}

function Get-AutoResumeColor {
    param([string]$Status)
    if ($Status -match '(?i)failed|error') { return [ConsoleColor]::Red }
    if ($Status -match '(?i)waiting') { return [ConsoleColor]::Yellow }
    if ($Status -match '(?i)enabled|armed|started') { return [ConsoleColor]::Green }
    if ($Status -match '(?i)disabled|off') { return [ConsoleColor]::DarkGray }
    return [ConsoleColor]::Gray
}
```

- [ ] **Step 2: Add colored and plain row writers**

Insert after the semantic color helpers:

```powershell
function Write-ColoredDashboardRow {
    param(
        [object[]]$Segments,
        [string]$Pad,
        [int]$Canvas,
        [int]$ScreenWidth
    )

    Write-Host $Pad -NoNewline
    $written = 0
    foreach ($segment in @($Segments)) {
        $available = $Canvas - $written
        if ($available -le 0) { break }
        $text = [string]$segment.Text
        if ($text.Length -gt $available) { $text = $text.Substring(0,$available) }
        if ($text.Length -gt 0) {
            Write-Host $text -ForegroundColor $segment.Color -NoNewline
            $written += $text.Length
        }
    }

    $tail = [math]::Max(0,$ScreenWidth - $Pad.Length - $written)
    Write-Host (' ' * $tail)
}

function Write-PlainDashboardRows {
    param(
        [System.Collections.IEnumerable]$Rows,
        [string]$Pad,
        [int]$Canvas,
        [int]$ScreenWidth
    )

    foreach ($row in $Rows) {
        $text = Get-DashboardRowText -Segments @($row)
        if ($text.Length -gt $Canvas) { $text = $text.Substring(0,$Canvas) }
        $line = ($Pad + $text.PadRight($Canvas)).PadRight($ScreenWidth)
        Write-Host $line
    }
}

function Write-DashboardRows {
    param(
        [System.Collections.IEnumerable]$Rows,
        [string]$Pad,
        [int]$Canvas,
        [int]$ScreenWidth
    )

    try {
        foreach ($row in $Rows) {
            Write-ColoredDashboardRow -Segments @($row) -Pad $Pad -Canvas $Canvas -ScreenWidth $ScreenWidth
        }
    }
    catch {
        try { [Console]::ResetColor() } catch {}
        try { [Console]::SetCursorPosition(0,0) } catch { Clear-Host }
        Write-PlainDashboardRows -Rows $Rows -Pad $Pad -Canvas $Canvas -ScreenWidth $ScreenWidth
    }
}
```

- [ ] **Step 3: Run focused helper-contract tests**

Run:

```bash
pytest -q tests/test_windows_color_scheme.py::test_windows_core_uses_segmented_color_renderer tests/test_windows_color_scheme.py::test_windows_core_contains_approved_semantic_palette tests/test_windows_color_scheme.py::test_windows_core_has_plain_text_fallback
```

Expected: palette and fallback tests pass; the renderer test may still fail only because the old whole-screen `Write-Host ($output -join ...)` remains until Task 3.

- [ ] **Step 4: Run the PowerShell structural test**

```bash
pytest -q tests/test_windows_dashboard_structure.py
```

Expected: `2 passed` with balanced delimiters and complete here-strings.

- [ ] **Step 5: Commit the helper layer**

```bash
git add Windows/CodexDashboardCore.ps1
git commit -m "feat: add Windows dashboard color primitives"
```

---

### Task 3: Refactor the Windows Dashboard to Emit Semantic Colored Rows

**Files:**
- Modify: `Windows/CodexDashboardCore.ps1:258-311`
- Test: `tests/test_windows_color_scheme.py`

**Interfaces:**
- Consumes: Task 2 helpers and the existing dashboard state object.
- Produces:
  - `New-UsageWindowRow` for aligned usage rows.
  - `New-CreditRow` for status-colored reset-credit rows.
  - `New-AutoResumeRow` for semantic status and optional project display.
  - `New-FooterRow` for dim footer text.
  - A row-based `Render-Dashboard` that calls `Write-DashboardRows` once per refresh.

- [ ] **Step 1: Add row-construction helpers**

Insert immediately before `Render-Dashboard`:

```powershell
function New-UsageWindowRow {
    param(
        [string]$Label,
        [bool]$Available,
        [int]$Remaining,
        [int]$Used,
        [long]$Reset
    )

    if (-not $Available) {
        return @(
            New-DashboardSegment -Text ('{0,-11} ' -f $Label) -Color ([ConsoleColor]::DarkGray)
            New-DashboardSegment -Text ('{0,-50} {1,-36} {2}' -f 'Temporarily not enforced','No reset scheduled','-') -Color ([ConsoleColor]::DarkGray)
        )
    }

    $segments = [System.Collections.Generic.List[object]]::new()
    [void]$segments.Add((New-DashboardSegment -Text ('{0,-11} ' -f $Label) -Color ([ConsoleColor]::DarkGray)))
    [void]$segments.Add((New-DashboardSegment -Text ('{0,3}% ' -f $Remaining) -Color ([ConsoleColor]::Green)))
    foreach ($segment in @(New-UsageBarSegments -Remaining $Remaining)) { [void]$segments.Add($segment) }
    [void]$segments.Add((New-DashboardSegment -Text ('   {0,3}%       ' -f $Used) -Color ([ConsoleColor]::Gray)))
    [void]$segments.Add((New-DashboardSegment -Text ('{0,-36} ' -f (Format-LocalTime $Reset)) -Color ([ConsoleColor]::Yellow)))
    $countdown = Format-Countdown $Reset
    [void]$segments.Add((New-DashboardSegment -Text $countdown -Color (Get-CountdownColor $countdown)))
    return @($segments)
}

function New-CreditRow {
    param($Credit)
    $countdown = Format-Countdown $Credit.ExpiresAt
    @(
        New-DashboardSegment -Text ('{0,-14} ' -f $Credit.Status) -Color (Get-CreditStatusColor $Credit.Status)
        New-DashboardSegment -Text ('{0,-36} ' -f (Format-LocalTime $Credit.GrantedAt)) -Color ([ConsoleColor]::Gray)
        New-DashboardSegment -Text ('{0,-36} ' -f (Format-LocalTime $Credit.ExpiresAt)) -Color ([ConsoleColor]::Gray)
        New-DashboardSegment -Text $countdown -Color (Get-CountdownColor $countdown)
    )
}

function New-AutoResumeRow {
    param([string]$Status, [string]$Project = $null)
    $segments = [System.Collections.Generic.List[object]]::new()
    [void]$segments.Add((New-DashboardSegment -Text 'Auto-resume: ' -Color ([ConsoleColor]::DarkGray)))
    [void]$segments.Add((New-DashboardSegment -Text $Status -Color (Get-AutoResumeColor $Status)))
    if (-not [string]::IsNullOrWhiteSpace($Project)) {
        [void]$segments.Add((New-DashboardSegment -Text ' | Project: ' -Color ([ConsoleColor]::DarkGray)))
        [void]$segments.Add((New-DashboardSegment -Text $Project -Color ([ConsoleColor]::Gray)))
    }
    return @($segments)
}

function New-FooterRow {
    param([string]$Text)
    @((New-DashboardSegment -Text $Text -Color ([ConsoleColor]::DarkGray)))
}
```

- [ ] **Step 2: Replace `Render-Dashboard` with the row-based implementation**

Replace the complete existing `Render-Dashboard` function with:

```powershell
function Render-Dashboard {
    param($State)
    $size = Get-ConsoleSize
    try { [Console]::SetCursorPosition(0,0) } catch { Clear-Host }

    if ($size.Width -lt $Script:MinimumWidth -or $size.Height -lt $Script:MinimumHeight) {
        Clear-Host
        Write-ColoredLine 'Codex Dashboard' Cyan
        Write-Host "Terminal is too small. Current: $($size.Width)x$($size.Height). Required: at least $($Script:MinimumWidth)x$($Script:MinimumHeight)."
        Write-Host 'Resize the window. The dashboard will redraw automatically.'
        return
    }

    $canvas = [math]::Min(160,$size.Width - 4)
    $pad = ' ' * [math]::Max(0,[int](($size.Width - $canvas) / 2))
    $rows = [System.Collections.Generic.List[object]]::new()

    [void]$rows.Add(@(New-DashboardSegment -Text (Center-Line "CODEX USAGE DASHBOARD v$($Script:AppVersion)" $canvas) -Color ([ConsoleColor]::Cyan)))
    [void]$rows.Add(@(New-DashboardSegment -Text (Center-Line "Windows PowerShell | Plan: $($State.Plan)" $canvas) -Color ([ConsoleColor]::Cyan)))
    [void]$rows.Add(@(New-DashboardSegment -Text ('-' * $canvas) -Color ([ConsoleColor]::Cyan)))

    $access = if ($State.Allowed -and -not $State.LimitReached) { 'AVAILABLE' } else { 'RATE LIMITED' }
    $accessColor = if ($access -eq 'AVAILABLE') { [ConsoleColor]::Green } else { [ConsoleColor]::Red }
    [void]$rows.Add(@(
        New-DashboardSegment -Text 'Access: ' -Color ([ConsoleColor]::DarkGray)
        New-DashboardSegment -Text ('{0,-14}' -f $access) -Color $accessColor
        New-DashboardSegment -Text '  Last API refresh: ' -Color ([ConsoleColor]::DarkGray)
        New-DashboardSegment -Text $State.RefreshedAt.ToString('h:mm:ss tt') -Color ([ConsoleColor]::Gray)
    ))

    [void]$rows.Add(@())
    [void]$rows.Add(@(New-DashboardSegment -Text 'USAGE WINDOWS' -Color ([ConsoleColor]::Cyan)))
    [void]$rows.Add(@(New-DashboardSegment -Text 'Window      Remaining                    Used       Resets                               Countdown' -Color ([ConsoleColor]::DarkGray)))
    [void]$rows.Add((New-UsageWindowRow -Label $State.PrimaryWindowLabel -Available $State.PrimaryWindowAvailable -Remaining $State.FiveRemaining -Used $State.FiveUsed -Reset $State.FiveReset))
    [void]$rows.Add((New-UsageWindowRow -Label 'Weekly' -Available $true -Remaining $State.WeekRemaining -Used $State.WeekUsed -Reset $State.WeekReset))

    [void]$rows.Add(@())
    [void]$rows.Add(@(
        New-DashboardSegment -Text 'RESET CREDITS  ' -Color ([ConsoleColor]::Cyan)
        New-DashboardSegment -Text 'Available: ' -Color ([ConsoleColor]::DarkGray)
        New-DashboardSegment -Text ([string]$State.AvailableCredits) -Color ([ConsoleColor]::Green)
    ))
    [void]$rows.Add(@(New-DashboardSegment -Text 'Status         Granted                              Expires                              Countdown' -Color ([ConsoleColor]::DarkGray)))

    if (@($State.Credits).Count -eq 0) {
        [void]$rows.Add(@(New-DashboardSegment -Text 'No reset-credit records returned.' -Color ([ConsoleColor]::DarkGray)))
    }
    else {
        foreach ($credit in @($State.Credits)) { [void]$rows.Add((New-CreditRow -Credit $credit)) }
    }

    [void]$rows.Add(@())
    [void]$rows.Add((New-AutoResumeRow -Status $Script:ResumeStatus))
    if ($Script:ResumeLog) {
        [void]$rows.Add(@(
            New-DashboardSegment -Text 'Resume log: ' -Color ([ConsoleColor]::DarkGray)
            New-DashboardSegment -Text $Script:ResumeLog -Color ([ConsoleColor]::Gray)
        ))
    }
    if ($Script:LastRefreshError) {
        [void]$rows.Add(@(
            New-DashboardSegment -Text 'Warning: ' -Color ([ConsoleColor]::Red)
            New-DashboardSegment -Text $Script:LastRefreshError -Color ([ConsoleColor]::Red)
        ))
    }
    [void]$rows.Add((New-FooterRow -Text "Terminal: $($size.Width)x$($size.Height)  |  API refresh: ${Refresh}s  |  Ctrl+C to exit"))

    while ($rows.Count -lt ($size.Height - 1)) { [void]$rows.Add(@()) }
    Write-DashboardRows -Rows $rows -Pad $pad -Canvas $canvas -ScreenWidth $size.Width
}
```

- [ ] **Step 3: Run the complete color-renderer contract tests**

```bash
pytest -q tests/test_windows_color_scheme.py
```

Expected: helper, palette, and fallback tests pass; only the launcher-version/overlay test may remain failing until Task 4.

- [ ] **Step 4: Run Windows structural regression tests**

```bash
pytest -q tests/test_windows_dashboard_structure.py
```

Expected: all tests pass.

- [ ] **Step 5: Commit the row-based renderer**

```bash
git add Windows/CodexDashboardCore.ps1
git commit -m "feat: colorize Windows dashboard rendering"
```

---

### Task 4: Update the Windows Compatibility Overlay and Version

**Files:**
- Modify: `Windows/CodexDashboard.ps1:193-366`
- Test: `tests/test_windows_color_scheme.py`
- Test: `tests/test_interactive_auto_resume.py`

**Interfaces:**
- Consumes: `New-AutoResumeRow` and `New-FooterRow` from Task 3.
- Produces: v2.7.0 transformed core, project-aware colored auto-resume row, and the interactive `Press A` footer.

- [ ] **Step 1: Update the transformed Windows version**

Change:

```powershell
$coreText = $coreText.Replace("`$Script:AppVersion = '2.3.0'", "`$Script:AppVersion = '2.6.0'")
```

to:

```powershell
$coreText = $coreText.Replace("`$Script:AppVersion = '2.3.0'", "`$Script:AppVersion = '2.7.0'")
```

- [ ] **Step 2: Replace the obsolete plain-text display overlay**

Delete the existing `$oldDisplay`, `$newDisplay`, and their `$coreText.Replace(...)` call. Replace them with:

```powershell
$coreText = $coreText.Replace(
    '    [void]$rows.Add((New-AutoResumeRow -Status $Script:ResumeStatus))',
    '    [void]$rows.Add((New-AutoResumeRow -Status $Script:ResumeStatus -Project $(if ($Script:AutoResumeEnabled) { $Script:ResumeProject } else { $null })))'
)
$coreText = $coreText.Replace(
    '    [void]$rows.Add((New-FooterRow -Text "Terminal: $($size.Width)x$($size.Height)  |  API refresh: ${Refresh}s  |  Ctrl+C to exit"))',
    '    [void]$rows.Add((New-FooterRow -Text "Terminal: $($size.Width)x$($size.Height)  |  API refresh: ${Refresh}s  |  Press A to configure auto-resume | Control+C to exit."))'
)
```

- [ ] **Step 3: Update runtime guard markers**

Replace the version marker and add a project-row marker in `$requiredOverlays`:

```powershell
$requiredOverlays = @(
    "`$Script:AppVersion = '2.7.0'",
    'function Invoke-AutoResumeConfiguration',
    'function Test-InteractiveDashboardKey',
    'Press A to configure auto-resume',
    '$Script:AutoResumeEnabled',
    'if (-not $Script:AutoResumeEnabled) { return }',
    '-WorkingDirectory $Script:ResumeProject',
    '$Script:ResumePrompt.Replace',
    'New-AutoResumeRow -Status $Script:ResumeStatus -Project',
    'Test-InteractiveDashboardKey'
)
```

- [ ] **Step 4: Run overlay and interactive tests**

```bash
pytest -q tests/test_windows_color_scheme.py tests/test_interactive_auto_resume.py tests/test_windows_dashboard_structure.py
```

Expected: all tests pass.

- [ ] **Step 5: Commit launcher integration**

```bash
git add Windows/CodexDashboard.ps1 tests/test_windows_color_scheme.py tests/test_interactive_auto_resume.py
git commit -m "feat: integrate Windows color renderer overlay"
```

---

### Task 5: Run Full Regression and Validate on Windows PowerShell 7

**Files:**
- Verify: `Windows/CodexDashboardCore.ps1`
- Verify: `Windows/CodexDashboard.ps1`
- Verify: `tests/test_windows_color_scheme.py`
- Verify: `tests/test_interactive_auto_resume.py`
- Verify: `tests/test_windows_dashboard_structure.py`
- Verify: `tests/test_current_usage_schema.py`

**Interfaces:**
- Consumes: completed v2.7.0 Windows dashboard.
- Produces: regression evidence and real Windows visual approval.

- [ ] **Step 1: Run the targeted repository test suite**

```bash
pytest -q \
  tests/test_windows_color_scheme.py \
  tests/test_interactive_auto_resume.py \
  tests/test_windows_dashboard_structure.py \
  tests/test_current_usage_schema.py
```

Expected: all targeted tests pass with no skips introduced by this feature.

- [ ] **Step 2: Inspect the final branch diff**

```bash
git diff main...HEAD -- Windows/CodexDashboardCore.ps1 Windows/CodexDashboard.ps1 tests/test_windows_color_scheme.py tests/test_interactive_auto_resume.py
```

Expected: only Windows color rendering, v2.7.0 overlay integration, and associated tests are present; no macOS changes.

- [ ] **Step 3: Pull and launch on the Windows PC**

Run in PowerShell 7:

```powershell
cd C:\Developer\codex-dashboard
git pull
Set-ExecutionPolicy -Scope Process Bypass
.\Windows\CodexDashboard.ps1
```

Expected: header shows `v2.7.0`; title and structure are cyan; available/remaining values are green; countdowns and reset times are yellow; warnings/failures are red; metadata and help text are dark gray.

- [ ] **Step 4: Validate interactive auto-resume**

Press `A`, choose or enter a project path, confirm, and return to the dashboard.

Expected: prompt input remains readable; the dashboard redraws in color; auto-resume state changes color semantically; the footer still advertises the `A` shortcut.

- [ ] **Step 5: Validate refresh clearing and fallback assumptions**

Let the dashboard refresh for at least two API cycles and resize the terminal once.

Expected: no stale colored characters remain, alignment is unchanged, and the terminal-size warning still appears correctly. Temporarily forcing the colored writer to throw during development must result in a complete plain-text redraw rather than application termination; revert any forced throw before commit.

- [ ] **Step 6: Record final verification commit if Windows validation requires no code changes**

No empty commit is required. If Windows validation finds a defect, add a failing regression test first, apply the smallest fix, rerun Task 5 Steps 1-5, and commit with:

```bash
git add Windows/CodexDashboardCore.ps1 Windows/CodexDashboard.ps1 tests
git commit -m "fix: stabilize Windows dashboard color output"
```

---

## Plan Self-Review

- Spec coverage: palette, segmented rows, status semantics, full-width clearing, fallback, version `2.7.0`, automated tests, and real Windows validation each have an implementation task.
- Placeholder scan: no `TBD`, `TODO`, deferred implementation language, or undefined helper is present.
- Type consistency: every renderer helper consumed by a later task is defined with matching PowerShell names and parameters in an earlier task.
- Scope check: the plan changes only Windows rendering and launcher integration; macOS and usage calculations remain untouched.
