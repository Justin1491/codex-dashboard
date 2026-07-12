# Codex Dashboard

A live terminal dashboard for monitoring Codex usage limits, reset credits, and countdowns on macOS.

Codex Dashboard shows your current five-hour and weekly usage windows, converts reset times to your Mac’s local time zone, tracks individual reset-credit expirations, and can optionally resume the most recent non-interactive Codex task after a rate limit clears.

> **Current version:** 2.2.0  
> **Platform:** macOS  
> **Repository:** https://github.com/Justin1491/codex-dashboard

## Features

- Five-hour usage used and remaining
- Weekly usage used and remaining
- Local reset date and time
- Live countdowns in days, hours, minutes, and seconds
- Available reset-credit count
- Individual reset-credit status, grant time, expiration time, and countdown
- Automatic API refresh
- Stable terminal rendering without full-screen blinking
- Resize-aware centered dashboard
- Alternate-screen mode, so your original Terminal contents return when you exit
- Optional Codex auto-resume after a rate limit resets
- Support for custom `CODEX_HOME` and endpoint environment variables
- No credentials stored in the repository

## Screenshot

Add a screenshot to the repository at:

```text
docs/codex-dashboard.png
```

Then replace this section with:

```markdown
![Codex Dashboard](docs/codex-dashboard.png)
```

## Requirements

- macOS
- Codex installed and signed in
- Bash
- `curl`
- `jq`
- Codex CLI, only when using auto-resume

Install `jq` with Homebrew:

```bash
brew install jq
```

The script reads your existing Codex authentication file from:

```text
$CODEX_HOME/auth.json
```

When `CODEX_HOME` is not set, it defaults to:

```text
~/.codex/auth.json
```

## Installation

Clone the repository:

```bash
git clone https://github.com/Justin1491/codex-dashboard.git
cd codex-dashboard
```

Make the script executable:

```bash
chmod 700 codex-usage-dashboard-v2.2.sh
```

## Run the Dashboard

From the repository folder:

```bash
./codex-usage-dashboard-v2.2.sh
```

From anywhere:

```bash
~/Developer/codex-dashboard/codex-usage-dashboard-v2.2.sh
```

Press **Control + C** to exit.

## Command-Line Options

```text
--auto-resume          Resume the most recent non-interactive Codex session
                       after the five-hour rate limit resets.

--project PATH         Project directory used for Codex resume.
                       Default: the current directory.

--refresh SECONDS      API refresh interval.
                       Default: 60 seconds.

--prompt TEXT          Custom continuation instruction sent to Codex.

--help                 Display command help.
```

Display the built-in help:

```bash
./codex-usage-dashboard-v2.2.sh --help
```

## Auto-Resume

Auto-resume is disabled by default.

To monitor a project and resume its most recent non-interactive Codex session after the rate limit clears:

```bash
./codex-usage-dashboard-v2.2.sh \
  --auto-resume \
  --project ~/Developer/MyProject
```

With a custom continuation prompt:

```bash
./codex-usage-dashboard-v2.2.sh \
  --auto-resume \
  --project ~/Developer/MyProject \
  --prompt "Review the repository and continue the current implementation plan from the last safe point. Do not repeat completed work."
```

The dashboard launches Codex using the equivalent of:

```bash
codex exec resume --last "<continuation prompt>"
```

The resumed process runs in the selected project directory. Output is written to a temporary log file, and the dashboard displays the process status.

### Auto-Resume Limitations

Auto-resume:

- Resumes the most recent non-interactive Codex session for the selected project
- Does not currently select among multiple suspended sessions
- Cannot guarantee that an interrupted command is safe to repeat
- May require intervention when Codex is waiting for approval or clarification
- Should be tested on a non-critical project before regular use

For important repositories, review `git status`, current changes, and the resume log after an automated continuation.

## Refresh Behavior

The dashboard uses two refresh cycles:

- Countdown values update once per second
- Usage and credit data refresh from the server every 60 seconds by default

Change the API refresh interval:

```bash
./codex-usage-dashboard-v2.2.sh --refresh 30
```

Only positive whole-number values are accepted.

## Terminal Behavior

The dashboard:

- Uses Terminal’s alternate screen
- Centers itself in wider windows
- Detects both terminal width and height
- Preserves the last valid dimensions during transient resize events
- Shows a narrow-window message when the available space is insufficient
- Restores your original Terminal screen when you exit

For the best layout, use a terminal at least **116 columns wide**.

## Environment Variables

### Custom Codex home

```bash
export CODEX_HOME="$HOME/.custom-codex"
./codex-usage-dashboard-v2.2.sh
```

### Custom usage endpoint

```bash
export CODEX_USAGE_ENDPOINT="https://example.com/usage"
```

### Custom reset-credit endpoint

```bash
export CODEX_CREDITS_ENDPOINT="https://example.com/credits"
```

These overrides are primarily useful if the backend endpoint changes.

## Security

The script reads your Codex access token and account ID from your local `auth.json` file at runtime.

It does **not**:

- Print your access token
- Write credentials into the repository
- Copy `auth.json`
- Save authentication details in logs
- Require credentials to be entered into the script

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

Pull the latest changes:

```bash
cd ~/Developer/codex-dashboard
git pull
```

Make sure the script remains executable:

```bash
chmod 700 codex-usage-dashboard-v2.2.sh
```

## Development Workflow

After modifying the dashboard:

```bash
git status
git add codex-usage-dashboard-v2.2.sh README.md
git commit -m "Describe the dashboard update"
git push
```

Run a Bash syntax check before committing:

```bash
bash -n codex-usage-dashboard-v2.2.sh
```

## Troubleshooting

### `jq is required`

Install it with Homebrew:

```bash
brew install jq
```

### Authentication file not found

Confirm Codex is installed and signed in, then check:

```bash
ls -l ~/.codex/auth.json
```

When using a custom Codex location:

```bash
echo "$CODEX_HOME"
ls -l "$CODEX_HOME/auth.json"
```

### Permission denied

Make the script executable:

```bash
chmod 700 codex-usage-dashboard-v2.2.sh
```

### Dashboard says the terminal is too small

Make the Terminal window wider or taller. The dashboard will automatically redraw when enough space becomes available.

### Usage data does not refresh

Confirm that Codex is signed in and that your internet connection is working. The dashboard preserves the last successful data when a refresh fails.

### Auto-resume does not start

Confirm the Codex CLI is available:

```bash
codex --version
```

Then confirm the project folder exists:

```bash
ls -ld ~/Developer/MyProject
```

## Known Constraints

Codex Dashboard relies on ChatGPT backend endpoints that are not documented as a stable public API. Their paths, response fields, or behavior may change without notice.

The dashboard is an independent utility and is not an official OpenAI product.

## Roadmap

Potential future improvements:

- Windows PowerShell V2.2 parity
- Installation script
- Homebrew formula
- Compact terminal layout
- Multi-project task monitoring
- Session selection instead of only `--last`
- Notification-only mode
- Interactive resume confirmation
- JSON output mode
- Config file support
- Release packaging and version checks

## License

No license has been selected yet. Until one is added, normal copyright protections apply and reuse rights are not automatically granted.

## Disclaimer

Use auto-resume carefully. Codex may have stopped while waiting for approval, clarification, or completion of an external command. Always review important repositories and generated changes before committing or deploying them.
