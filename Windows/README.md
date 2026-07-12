# Codex Dashboard for Windows

A native PowerShell implementation of Codex Dashboard with feature parity to the stable macOS V2.2 release.

## Features

- Five-hour and weekly Codex usage windows
- Remaining and used percentages
- Local reset dates and live countdowns
- Reset-credit availability and expiration details
- Automatic API refresh with last-known-good fallback
- Resize-aware centered terminal layout
- Optional Codex auto-resume after a rate limit clears
- Existing Codex authentication is read locally from `auth.json`
- No credentials are stored in this repository

## Requirements

- Windows 10 or Windows 11
- Windows PowerShell 5.1 or PowerShell 7+
- Codex installed and signed in
- Codex CLI available on `PATH` only when using auto-resume

The dashboard reads authentication from:

```text
%USERPROFILE%\.codex\auth.json
```

Set `CODEX_HOME` to use a different Codex directory.

## Run without installing

From PowerShell:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\CodexDashboard.ps1
```

## Install as a global command

From the `Windows` folder:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\install.ps1
```

Open a new Windows Terminal or PowerShell window, then run:

```powershell
codex-dashboard
```

The installer copies the application to:

```text
%LOCALAPPDATA%\CodexDashboard\
```

and creates the command shim at:

```text
%LOCALAPPDATA%\Microsoft\WindowsApps\codex-dashboard.cmd
```

## Options

```text
-AutoResume          Resume the most recent non-interactive Codex session
                     after the five-hour rate limit resets.

-Project PATH        Project directory used for Codex resume.
                     Default: current directory.

-Refresh SECONDS     API refresh interval. Default: 60.

-Prompt TEXT         Custom continuation instruction sent to Codex.

-Version             Print the version.

-Help                Display command help.
```

Example:

```powershell
codex-dashboard -AutoResume -Project C:\Developer\MyProject
```

## Environment variables

```powershell
$env:CODEX_HOME = "$HOME\.custom-codex"
$env:CODEX_USAGE_ENDPOINT = "https://example.com/usage"
$env:CODEX_CREDITS_ENDPOINT = "https://example.com/credits"
```

## Uninstall

From the repository's `Windows` folder:

```powershell
.\uninstall.ps1
```

## Security

The dashboard reads the access token and ChatGPT account ID from the user's local Codex authentication file at runtime. It does not print, copy, log, or persist either credential.

## Current validation status

The script was reviewed for Windows PowerShell 5.1-compatible syntax and follows the macOS V2.2 data flow and safety behavior. A native Windows runtime was not available in the build environment, so the first run should be treated as the platform smoke test.

## Known constraint

The usage and reset-credit endpoints are undocumented backend endpoints and may change without notice. The dashboard supports environment-variable endpoint overrides and preserves the last successful data when a refresh fails.
