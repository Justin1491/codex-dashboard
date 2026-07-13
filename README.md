# Codex Dashboard

A lightweight terminal dashboard for viewing your current OpenAI Codex usage limits, reset times, reset credits, and remaining availability on macOS and Windows.

Codex Dashboard is designed for people who use Codex heavily and want a clear answer to two questions:

1. **How much Codex usage do I have left?**
2. **When will Codex be available again if I hit a limit?**

It can also optionally **resume the most recent non-interactive Codex session automatically after the relevant usage limit resets**.

> **Platforms:** macOS and Windows  
> **Repository:** https://github.com/Justin1491/codex-dashboard

## What the Dashboard Does

Codex Dashboard reads your existing local Codex authentication and displays the usage information returned by OpenAI.

Depending on what OpenAI currently provides for your account, the dashboard can show:

- Short-term usage used and remaining
- Weekly usage used and remaining
- Local reset date and time
- Live countdowns until each reset
- Reset-credit availability
- Individual reset-credit grant and expiration times
- Automatic refresh of usage data
- Optional automatic resume after a rate limit clears

OpenAI occasionally changes which usage windows are returned. For example, the traditional five-hour window may be temporarily removed, replaced, or omitted. Codex Dashboard normalizes the available response and continues showing the windows that actually exist instead of assuming a five-hour window is always present.

## What the Dashboard Does Not Do

Codex Dashboard does **not** monitor active Codex tasks, inspect task progress, show completed jobs, or track individual agent activity.

Its purpose is specifically to display Codex usage availability and optionally restart the most recent resumable Codex CLI session after a usage limit clears.

## Features

### Usage Monitoring

- Displays usage consumed and remaining
- Shows short-term and weekly limits when available
- Handles accounts where only one usage window is currently returned
- Converts reset timestamps to your computer's local time zone
- Updates countdown values continuously
- Preserves the last valid data if a refresh temporarily fails

### Reset Credits

When reset-credit data is available, the dashboard can show:

- Number of available credits
- Credit status
- Grant time
- Expiration time
- Countdown until expiration

### Auto-Resume

Auto-resume can watch for a rate-limited Codex session and resume the most recent non-interactive session after the relevant limit resets.

The resumed command is equivalent to:

```bash
codex exec resume --last "<continuation prompt>"
```

The resumed process runs inside the selected project directory.

Auto-resume is disabled by default and must be explicitly enabled.

### Terminal Experience

- Stable rendering without constant full-screen blinking
- Live countdown updates
- Resize-aware layout
- Centered dashboard in wider terminals
- Alternate-screen behavior where supported
- Original terminal contents restored when the dashboard exits

## Requirements

### All Platforms

- An OpenAI account with Codex access
- Codex installed and signed in
- Internet access
- A local Codex authentication file

The dashboard reads authentication from:

```text
$CODEX_HOME/auth.json
```

When `CODEX_HOME` is not set, the default is:

```text
~/.codex/auth.json
```

### macOS

- Bash
- `curl`
- `jq`
- Codex CLI, when using auto-resume

Install `jq` with Homebrew:

```bash
brew install jq
```

### Windows

- Windows PowerShell or PowerShell 7
- Codex CLI, when using auto-resume

## Installation

Clone the repository:

```bash
git clone https://github.com/Justin1491/codex-dashboard.git
cd codex-dashboard
```

## Running on macOS

Make the current macOS script executable:

```bash
chmod 700 codex-usage-dashboard-v*.sh
```

Run it:

```bash
./codex-usage-dashboard-v*.sh
```

Press **Control + C** to exit.

### macOS Auto-Resume

Start the dashboard with auto-resume enabled:

```bash
./codex-usage-dashboard-v*.sh \
  --auto-resume \
  --project ~/Developer/MyProject
```

Use a custom continuation prompt:

```bash
./codex-usage-dashboard-v*.sh \
  --auto-resume \
  --project ~/Developer/MyProject \
  --prompt "Review the repository and continue the current implementation plan from the last safe point. Do not repeat completed work."
```

## Running on Windows

Open PowerShell and navigate to the Windows folder:

```powershell
cd C:\Developer\codex-dashboard\Windows
```

For the current PowerShell session, allow the script to run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
```

Launch the dashboard:

```powershell
.\CodexDashboard.ps1
```

Press **Control + C** to exit.

### Windows Auto-Resume

Enable auto-resume from the command line:

```powershell
.\CodexDashboard.ps1 `
  -AutoResume `
  -Project "C:\Developer\MyProject"
```

Use a custom continuation prompt:

```powershell
.\CodexDashboard.ps1 `
  -AutoResume `
  -Project "C:\Developer\MyProject" `
  -Prompt "Review the repository and continue the current implementation plan from the last safe point. Do not repeat completed work."
```

The Windows dashboard also supports interactive auto-resume configuration. While the dashboard is running, press:

```text
A
```

From there you can select or change the project folder and enable or disable auto-resume.

## Command-Line Options

The macOS and Windows launchers support equivalent options using each platform's normal command syntax.

| Purpose | macOS | Windows |
|---|---|---|
| Enable auto-resume | `--auto-resume` | `-AutoResume` |
| Select project directory | `--project PATH` | `-Project PATH` |
| Change API refresh interval | `--refresh SECONDS` | `-Refresh SECONDS` |
| Set continuation prompt | `--prompt TEXT` | `-Prompt TEXT` |
| Show help | `--help` | `-Help` |
| Show version | varies by launcher | `-Version` |

The default API refresh interval is 60 seconds.

Example using a 30-second refresh interval:

```bash
./codex-usage-dashboard-v*.sh --refresh 30
```

```powershell
.\CodexDashboard.ps1 -Refresh 30
```

## How Auto-Resume Works

Auto-resume is intended for a Codex CLI task that stopped because the account reached a usage limit.

The basic flow is:

1. The dashboard detects that Codex usage is blocked.
2. It tracks the relevant reset time.
3. It waits for the usage limit to clear.
4. It launches `codex exec resume --last` in the selected project folder.
5. It sends the configured continuation prompt.
6. It records and displays the resume status and log location.

Auto-resume targets the **most recent non-interactive Codex session** associated with the selected project.

### Auto-Resume Safety Notes

Auto-resume cannot determine whether every interrupted action is safe to repeat.

It may require intervention when Codex:

- Was waiting for approval
- Was waiting for clarification
- Was running an external command
- Had multiple suspended sessions
- Stopped at an ambiguous point

For important repositories:

- Review `git status` before enabling auto-resume
- Use source control
- Review the generated changes afterward
- Check the resume log
- Test the feature on a non-critical project first

## Refresh Behavior

The dashboard uses separate refresh cycles:

- Countdown values update continuously
- Usage and reset-credit data refresh from OpenAI at the configured API interval

If a refresh fails, the dashboard keeps the last successful data visible and displays a warning.

## OpenAI Usage-Window Changes

Codex Dashboard does not assume that OpenAI will always return the same limit structure.

The application currently accounts for situations where:

- Both a short-term and weekly window are returned
- Only a weekly window is returned
- Window names or response fields change
- Reset values arrive in different timestamp formats
- OpenAI temporarily removes the five-hour window

Because the dashboard relies on undocumented ChatGPT backend endpoints, OpenAI may change the response again in the future.

## Environment Variables

### Custom Codex Home

macOS:

```bash
export CODEX_HOME="$HOME/.custom-codex"
./codex-usage-dashboard-v*.sh
```

Windows:

```powershell
$env:CODEX_HOME = "$HOME\.custom-codex"
.\CodexDashboard.ps1
```

### Custom Usage Endpoint

macOS:

```bash
export CODEX_USAGE_ENDPOINT="https://example.com/usage"
```

Windows:

```powershell
$env:CODEX_USAGE_ENDPOINT = "https://example.com/usage"
```

### Custom Reset-Credit Endpoint

macOS:

```bash
export CODEX_CREDITS_ENDPOINT="https://example.com/credits"
```

Windows:

```powershell
$env:CODEX_CREDITS_ENDPOINT = "https://example.com/credits"
```

Endpoint overrides are mainly intended as a compatibility fallback if OpenAI changes a backend path.

## Security and Privacy

The dashboard reads the Codex access token and account ID from your local `auth.json` file at runtime.

It does **not**:

- Print your access token
- Copy your authentication file
- Commit credentials to the repository
- Save authentication details in logs
- Ask you to paste credentials into the script
- Upload your project source code
- Add analytics or telemetry

Never commit or share:

```text
~/.codex/auth.json
```

Recommended `.gitignore` entries:

```gitignore
auth.json
.codex/
.env
.env.*
*.token
*.key
.DS_Store
```

## Updating

Pull the latest version:

```bash
cd ~/Developer/codex-dashboard
git pull
```

On Windows:

```powershell
cd C:\Developer\codex-dashboard
git pull
```

## Troubleshooting

### Authentication file not found

Confirm Codex is installed and signed in.

macOS:

```bash
ls -l ~/.codex/auth.json
```

Windows:

```powershell
Test-Path "$HOME\.codex\auth.json"
```

### `jq is required` on macOS

Install it with Homebrew:

```bash
brew install jq
```

### Permission denied on macOS

```bash
chmod 700 codex-usage-dashboard-v*.sh
```

### PowerShell blocks the script

Run this in the same PowerShell window before launching:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
```

### Auto-resume does not start

Confirm that the Codex CLI is installed:

```bash
codex --version
```

Then confirm that the selected project directory exists.

### Usage data does not refresh

Confirm that:

- Codex is signed in
- Your internet connection is working
- `auth.json` exists
- OpenAI has not changed the backend response format

### Only one usage window appears

This may be expected. OpenAI sometimes returns only the weekly window or temporarily removes the shorter window. The dashboard displays the limits provided for the account rather than inventing a missing window.

## Known Constraints

- The dashboard relies on undocumented ChatGPT backend endpoints
- OpenAI may change endpoint paths or response fields without notice
- Auto-resume only targets the most recent non-interactive session
- Auto-resume cannot select among multiple suspended sessions
- The dashboard does not monitor task progress
- This project is not affiliated with or endorsed by OpenAI

## Contributing

Issues and pull requests are welcome.

Useful contribution areas include:

- Compatibility fixes when OpenAI changes usage responses
- macOS and Windows feature parity
- Terminal layout improvements
- Safer auto-resume behavior
- Session selection
- Notifications
- Installation and packaging improvements
- Documentation and screenshots

Before submitting a change, test the relevant platform and avoid including credentials or local authentication files.

## Screenshot

A screenshot can be added at:

```text
docs/codex-dashboard.png
```

Then embedded with:

```markdown
![Codex Dashboard](docs/codex-dashboard.png)
```

## License

No license has been selected yet. Until a license is added, normal copyright protections apply and reuse rights are not automatically granted.

If the goal is broad community adoption and contribution, consider adding an open-source license such as MIT, Apache 2.0, or GPLv3.

## Disclaimer

Codex Dashboard is an independent community utility and is not an official OpenAI product.

Use auto-resume carefully. Always review important repositories and generated changes before committing, merging, or deploying them.
