# Windows Dashboard Color Scheme Design

## Goal

Give the Windows Codex Dashboard the same visual language as the macOS dashboard without changing its data, layout, refresh cadence, auto-resume behavior, or terminal-size requirements.

## Scope

This change affects only Windows rendering in `Windows/CodexDashboardCore.ps1` and the compatibility overlay in `Windows/CodexDashboard.ps1` where version and runtime markers are injected.

No macOS behavior changes are included.

## Color Palette

The Windows dashboard will use standard `ConsoleColor` values so it works in Windows Terminal, PowerShell 7, and traditional PowerShell hosts.

- Cyan: title, horizontal rules, and section headings
- Green: available status, remaining percentages, filled usage bars, active credits, and enabled auto-resume
- Yellow: countdowns, reset times, waiting states, and caution messages
- Red: rate-limited status, failures, expired credit states, and API warnings
- DarkGray: column labels, unavailable-window details, help text, and low-priority metadata
- Gray or White: normal values and unclassified table content

The design will not depend on custom RGB colors or ANSI escape sequences.

## Rendering Architecture

The current renderer builds the dashboard as plain strings and writes the entire screen in one `Write-Host` call. The new renderer will preserve the same layout calculations but represent each visible row as a sequence of colored text segments.

A small rendering helper will accept ordered segments with text and `ConsoleColor`, write each segment with `Write-Host -NoNewline`, and then terminate the row. Padding will remain part of the rendered output so old content is fully overwritten during refreshes.

The existing plain-text formatting functions will continue to generate fixed-width values. The color layer will not alter alignment, truncation, percentages, reset times, countdown calculations, or the number of screen rows.

## Color Assignment

### Header and Structure

The centered dashboard title, platform subtitle, section names, and separator rules will render in Cyan.

### Access Status

- `AVAILABLE` renders in Green.
- `RATE LIMITED` renders in Red.
- The last-refresh timestamp remains Gray.

### Usage Windows

- Window names and column labels render in DarkGray or Cyan as appropriate.
- Remaining percentages and filled portions of bars render in Green.
- Unfilled bar portions render in DarkGray.
- Used percentages render in Gray.
- Reset timestamps and active countdowns render in Yellow.
- `Ready` renders in Green.
- `Unknown` renders in Red.
- A temporarily unenforced short-term window renders in DarkGray.

### Reset Credits

- Available or active credit statuses render in Green.
- Pending or cautionary statuses render in Yellow.
- Expired, failed, or invalid statuses render in Red.
- Unrecognized statuses render in Gray.
- Granted and expiration timestamps render in Gray.
- Countdown values follow the same Green, Yellow, and Red rules used by usage windows.

### Auto-Resume and Diagnostics

- Enabled, armed, or started states render in Green.
- Waiting states render in Yellow.
- Disabled states and project metadata render in DarkGray or Gray.
- Failed states and API warnings render in Red.
- Footer controls and terminal details render in DarkGray.

## Fallback Behavior

Rendering will be wrapped so a host that rejects colored console output falls back to the existing plain-text dashboard instead of terminating the application.

The fallback must preserve all information and alignment. Color is an enhancement, not a runtime requirement.

## Versioning

The Windows dashboard display version will increase from `2.6.0` to `2.7.0`. The launcher filename remains version-neutral.

## Testing

Tests will verify:

1. The PowerShell files remain structurally valid with balanced delimiters and complete here-strings.
2. The launcher injects version `2.7.0` and preserves all interactive auto-resume markers.
3. The renderer defines a segmented color-writing helper and uses all approved semantic colors.
4. The plain-text fallback remains present.
5. Existing usage-schema, auto-resume, and Windows structural tests continue to pass.

A real Windows PowerShell 7 run remains the final visual validation because console color behavior cannot be fully reproduced in the current non-Windows environment.

## Acceptance Criteria

- The Windows dashboard visually matches the macOS color hierarchy.
- All text remains aligned exactly as before.
- Refreshes do not leave stale colored characters behind.
- The dashboard works when color output is unavailable.
- Usage calculations, reset times, keyboard controls, and auto-resume behavior are unchanged.
