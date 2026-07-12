# Codex Dashboard Project Architecture

## 1. Purpose

Codex Dashboard is a cross-platform terminal utility for monitoring Codex usage limits, reset credits, and rate-limit recovery. It is intended to give users a clear real-time view of:

- Five-hour usage and reset timing
- Weekly usage and reset timing
- Available reset-credit count
- Individual reset-credit status and expiration
- Codex availability after a rate limit
- Optional resumption of interrupted Codex work

The project currently has a working macOS implementation. A Windows PowerShell implementation is planned.

## 2. Product Goals

### Primary goals

1. Provide a stable, readable terminal dashboard.
2. Work without users manually entering access tokens or account IDs.
3. Use each user’s existing Codex authentication securely.
4. Install as a global command that can be launched from any directory.
5. Support safe, understandable Codex resume behavior.
6. Maintain macOS and Windows implementations under one repository.

### Secondary goals

- Make installation and updates simple.
- Support multiple projects and saved settings.
- Provide testable modules rather than one increasingly large script.
- Package releases through GitHub and eventually Homebrew.

### Non-goals for the current release

- Replacing the official Codex application
- Managing every Codex thread through a graphical interface
- Guaranteeing that all interrupted commands are safe to repeat
- Persisting or transmitting authentication credentials
- Depending on undocumented response fields without graceful fallbacks

## 3. Repository Structure

Target repository structure:

```text
codex-dashboard/
├── README.md
├── LICENSE
├── CHANGELOG.md
├── .gitignore
├── docs/
│   ├── PROJECT_ARCHITECTURE.md
│   ├── SECURITY.md
│   ├── RELEASE_PROCESS.md
│   └── screenshots/
│       └── codex-dashboard-macos.png
├── macOS/
│   ├── README.md
│   ├── bin/
│   │   └── codex-dashboard
│   ├── lib/
│   │   ├── api.sh
│   │   ├── auth.sh
│   │   ├── config.sh
│   │   ├── countdown.sh
│   │   ├── display.sh
│   │   ├── projects.sh
│   │   └── resume.sh
│   ├── install.sh
│   ├── uninstall.sh
│   └── tests/
│       ├── fixtures/
│       ├── test_api.sh
│       ├── test_countdown.sh
│       ├── test_display.sh
│       └── test_resume.sh
├── Windows/
│   ├── README.md
│   ├── CodexDashboard.ps1
│   ├── modules/
│   │   ├── Api.psm1
│   │   ├── Auth.psm1
│   │   ├── Config.psm1
│   │   ├── Countdown.psm1
│   │   ├── Display.psm1
│   │   ├── Projects.psm1
│   │   └── Resume.psm1
│   ├── install.ps1
│   ├── uninstall.ps1
│   └── tests/
│       ├── fixtures/
│       └── CodexDashboard.Tests.ps1
└── .github/
    └── workflows/
        ├── macos-tests.yml
        ├── windows-tests.yml
        └── release.yml
```

The project may remain simpler during early development, but new work should move toward this layout.

## 4. Platform Strategy

The repository contains two platform implementations with matching behavior but native scripting technologies.

### macOS

- Language: Bash
- Shell: zsh-compatible launch environment, Bash execution
- Package dependencies: `curl`, `jq`
- Global command: `codex-dashboard`
- Installation target:
  - Application files: `~/.local/share/codex-dashboard/`
  - Executable wrapper: `~/.local/bin/codex-dashboard`
  - Configuration: `~/.config/codex-dashboard/config.json`

### Windows

- Language: PowerShell
- Supported shells: Windows PowerShell 5.1 and PowerShell 7+
- Global command: `codex-dashboard`
- Installation target:
  - Application files: `%LOCALAPPDATA%\CodexDashboard\`
  - Command shim or PowerShell profile integration
  - Configuration: `%APPDATA%\CodexDashboard\config.json`

### Shared behavior

Both implementations should expose equivalent commands and configuration where practical:

```text
codex-dashboard
codex-dashboard setup
codex-dashboard config
codex-dashboard project add
codex-dashboard project list
codex-dashboard project remove
codex-dashboard update
codex-dashboard uninstall
codex-dashboard --version
codex-dashboard --help
```

## 5. High-Level Architecture

```text
┌──────────────────────────┐
│        User Command      │
│    codex-dashboard ...   │
└────────────┬─────────────┘
             │
             ▼
┌──────────────────────────┐
│     Command Router       │
│ dashboard/setup/config   │
└────────────┬─────────────┘
             │
     ┌───────┼────────┐
     ▼       ▼        ▼
┌────────┐ ┌────────┐ ┌──────────┐
│ Config │ │  Auth  │ │ Projects │
└────┬───┘ └────┬───┘ └────┬─────┘
     │          │          │
     └──────┬───┴──────────┘
            ▼
┌──────────────────────────┐
│       API Client         │
│ usage + reset credits    │
└────────────┬─────────────┘
             │
             ▼
┌──────────────────────────┐
│ Normalized Domain State  │
│ limits, credits, status  │
└───────┬──────────┬───────┘
        │          │
        ▼          ▼
┌──────────────┐ ┌──────────────┐
│ Terminal UI  │ │ Resume Logic │
│ render/update│ │ notify/confirm│
└──────────────┘ └──────────────┘
```

## 6. Core Components

### 6.1 Command router

Responsibilities:

- Parse command-line arguments
- Dispatch setup, dashboard, project, update, and uninstall actions
- Validate command combinations
- Print consistent help and version output

The command router should not contain API, rendering, or resume logic.

### 6.2 Authentication

Responsibilities:

- Resolve `CODEX_HOME`
- Default to the platform-standard Codex authentication location
- Read `auth.json`
- Extract the access token and account ID
- Validate required fields
- Never display or persist credentials

Expected macOS path:

```text
${CODEX_HOME:-$HOME/.codex}/auth.json
```

Expected Windows path:

```text
$env:CODEX_HOME\auth.json
```

or:

```text
$HOME\.codex\auth.json
```

Authentication data must remain in memory only.

### 6.3 API client

Responsibilities:

- Request Codex usage data
- Request reset-credit records
- Apply required authorization headers
- Validate JSON responses
- Preserve last known good data on refresh failure
- Return normalized values to the rest of the application

Current endpoints:

```text
https://chatgpt.com/backend-api/wham/usage
https://chatgpt.com/backend-api/wham/rate-limit-reset-credits
```

These endpoints are not documented as stable public APIs. The client must therefore:

- Use environment-variable overrides
- Handle missing fields
- Avoid crashing on null or changed response structures
- Clearly report degraded or unavailable data

### 6.4 Domain model

API responses should be converted into a stable internal model before rendering.

Conceptual model:

```json
{
  "plan": "prolite",
  "access": {
    "allowed": false,
    "limitReached": true
  },
  "usageWindows": [
    {
      "id": "five-hour",
      "label": "5-hour",
      "usedPercent": 100,
      "remainingPercent": 0,
      "windowSeconds": 18000,
      "resetAt": 1783863315
    },
    {
      "id": "weekly",
      "label": "Weekly",
      "usedPercent": 32,
      "remainingPercent": 68,
      "windowSeconds": 604800,
      "resetAt": 1784424739
    }
  ],
  "resetCredits": {
    "availableCount": 3,
    "records": []
  }
}
```

Rendering code should consume this normalized model rather than raw API JSON.

### 6.5 Countdown engine

Responsibilities:

- Convert API reset times into local system time
- Calculate days, hours, minutes, and seconds remaining
- Treat expired timestamps consistently
- Update only values that changed
- Remain independent from the terminal renderer

The countdown engine should be unit-tested using fixed timestamps.

### 6.6 Terminal renderer

Responsibilities:

- Draw the dashboard
- Align columns consistently
- Detect terminal width and height
- Center content in wide windows
- Show a compact or narrow-window fallback when needed
- Update countdown fields without clearing the full screen every second
- Restore terminal state on exit or interruption

Rendering requirements:

- Use the terminal alternate screen where supported
- Hide the cursor only while running
- Always restore the cursor
- Do not crash when dimensions temporarily report zero or invalid values
- Redraw only when dimensions or structural data change
- Avoid characters whose display width differs between terminal implementations unless width behavior is verified

### 6.7 Configuration

Configuration location:

```text
macOS:   ~/.config/codex-dashboard/config.json
Windows: %APPDATA%\CodexDashboard\config.json
```

Proposed schema:

```json
{
  "version": 1,
  "refreshSeconds": 60,
  "resumeMode": "confirm",
  "defaultProjectId": "chatpaste",
  "projects": [
    {
      "id": "chatpaste",
      "name": "ChatPaste",
      "path": "/Users/example/Developer/ChatPaste"
    }
  ],
  "display": {
    "compact": false,
    "showSeconds": true
  }
}
```

Supported resume modes:

- `off`
- `notify`
- `confirm`
- `automatic`

Invalid configuration should produce a clear error and offer repair or reset options.

### 6.8 Project registry

Responsibilities:

- Save project names and paths
- Validate that paths exist
- Select a default project
- Allow project selection without requiring directory changes
- Prevent duplicate project entries

Users should be able to run:

```bash
codex-dashboard project add ~/Developer/ChatPaste
codex-dashboard project default ChatPaste
codex-dashboard
```

The dashboard should not require the script itself to live inside a monitored project.

### 6.9 Resume controller

Responsibilities:

- Detect transition from rate-limited to available
- Select the configured project
- Check for an existing Codex process
- Avoid duplicate resume attempts
- Respect `off`, `notify`, `confirm`, and `automatic` modes
- Record resume attempts and output logs
- Run Codex from the project directory

Initial resume command:

```bash
codex exec resume --last "<continuation prompt>"
```

Before an automatic or confirmed resume, the controller should inspect:

- Project directory existence
- Git working-tree status when the folder is a Git repository
- Whether another resume process is already running
- Whether a resume has already fired for the current reset event
- Whether the current state requires user approval or clarification

A later version should support selecting a specific Codex session rather than relying only on `--last`.

### 6.10 Installer and updater

Installer responsibilities:

- Detect platform
- Validate dependencies
- Install files to a user-owned location
- Create a global command
- Add the command directory to PATH when required
- Preserve user configuration
- Avoid administrator privileges unless unavoidable

Updater responsibilities:

- Check the latest GitHub release
- Download the appropriate platform package
- Verify checksum
- Replace application files atomically
- Preserve configuration
- Support rollback when update installation fails

## 7. Data Flow

### Dashboard startup

1. Parse command and options.
2. Load configuration.
3. Resolve authentication path.
4. Read authentication credentials into memory.
5. Fetch usage and reset-credit data.
6. Normalize API responses.
7. Detect terminal dimensions.
8. Render dashboard.
9. Begin countdown loop.
10. Refresh API data at the configured interval.

### API refresh

1. Fetch new usage response.
2. Validate JSON.
3. Fetch reset-credit response.
4. Normalize new state.
5. Compare structural changes against current state.
6. Update values in place when possible.
7. Perform a full redraw only when rows, dimensions, or layout requirements change.
8. Preserve prior data and show a warning if refresh fails.

### Resume transition

1. Observe rate-limited state.
2. Store the relevant reset event.
3. Poll usage at the configured interval.
4. Detect transition to allowed state.
5. Apply configured resume mode.
6. Validate project and process state.
7. Notify, request confirmation, or resume.
8. Write output to a log file.
9. Prevent another resume for the same reset event.

## 8. Error Handling

Errors should be grouped by severity.

### Fatal startup errors

Examples:

- Authentication file missing
- Required dependency missing
- Invalid command-line options
- Configuration cannot be read and cannot be repaired

Behavior:

- Restore terminal state
- Print a direct explanation
- Include the corrective command when possible
- Exit non-zero

### Recoverable runtime errors

Examples:

- Temporary API failure
- Reset-credit endpoint unavailable
- Terminal dimensions temporarily invalid
- Project path removed after startup

Behavior:

- Keep running when safe
- Preserve last successful data
- Show a visible warning
- Retry at the next interval

### Resume errors

Examples:

- Codex CLI missing
- No resumable session found
- Resume process exits non-zero
- Another Codex process is already active

Behavior:

- Do not retry continuously
- Record the failure once
- Display the log location
- Require user action or wait for the next distinct reset event

## 9. Security Model

### Credential handling

- Read credentials only from the local Codex authentication file
- Never print the access token
- Never store credentials in configuration
- Never copy `auth.json`
- Never send credentials to any host other than the configured Codex endpoint

### Logging

Logs may contain:

- Timestamps
- Project paths
- Codex process output
- Error messages

Logs must not contain:

- Access tokens
- Account IDs unless redacted
- Email addresses unless already emitted by Codex and clearly necessary
- Full API responses by default

### Git hygiene

Required ignore patterns:

```gitignore
.DS_Store
auth.json
.codex/
.env
.env.*
*.token
*.key
*.log
```

### Undocumented API risk

Because the usage endpoints are not documented as stable public APIs:

- Endpoint URLs must be configurable
- Response parsing must be defensive
- Missing fields must not reveal secrets through debug output
- Releases must state that functionality can change without notice

## 10. Testing Strategy

### Unit tests

Test independently:

- Percentage clamping
- Remaining-percentage calculation
- Epoch conversion
- ISO timestamp conversion
- Countdown calculation
- Expired and missing timestamps
- Configuration validation
- Project registry operations
- Resume-trigger deduplication

### Fixture tests

Store sanitized API examples under each platform’s test fixtures.

Required cases:

- Normal available account
- Five-hour limit reached
- Weekly limit reached
- No reset credits
- Multiple reset credits
- Missing secondary window
- Null additional limits
- Malformed response
- Endpoint failure

### Renderer tests

Test at representative terminal sizes:

- Narrow
- Minimum supported width
- Typical laptop size
- Very wide window
- Resize during countdown
- Rapid resize and move events

The renderer should be tested against captured output so duplicate dashboards, misaligned fields, and stale digits can be detected.

### Integration tests

- Mock API server
- Temporary authentication file
- Temporary config directory
- Mock Codex executable
- Verify resume occurs once and only once
- Verify no resume in `off` or `notify` mode

### Continuous integration

macOS workflow:

- `bash -n`
- `shellcheck`
- unit and fixture tests

Windows workflow:

- PowerShell parser validation
- PSScriptAnalyzer
- Pester tests

## 11. Release Strategy

Use semantic versioning:

```text
MAJOR.MINOR.PATCH
```

Examples:

- Patch: rendering or parsing bug fix
- Minor: installer, config, or new resume mode
- Major: incompatible config format or architecture change

Each release should include:

- Release notes
- macOS package
- Windows package when supported
- SHA-256 checksums
- Known limitations
- Upgrade instructions

Suggested milestones:

### V2.2.x: Stability baseline

- Preserve current working macOS dashboard
- Fix only defects
- Add architecture and security documentation
- Add basic CI

### V2.3: Installation and configuration

- Global command
- Installer and uninstaller
- Persistent configuration
- Project registry
- First-run setup
- `off`, `notify`, `confirm`, and `automatic` resume modes

### V2.4: Testing and packaging

- Mock API tests
- Renderer regression tests
- GitHub Actions
- GitHub Releases
- Update command

### V3.0: Structured session management

- Discover actual Codex sessions
- Select a specific suspended session
- Multi-project monitoring
- Safer resume state detection
- Replace reliance on `resume --last` where possible

### V3.x: Platform parity

- Windows feature parity
- PowerShell installer
- Common configuration schema
- Consistent release packaging

## 12. Development Rules

1. Do not add features directly to the stable release without tests.
2. Keep API parsing separate from rendering.
3. Keep countdown calculations separate from cursor updates.
4. Never hardcode a user-specific path.
5. Never commit tokens, account identifiers, or raw private API payloads.
6. Preserve terminal state on every exit path.
7. Every resume action must be idempotent for a given reset event.
8. Use mock data for automated testing.
9. Keep macOS and Windows behavior aligned through documented contracts, not copied implementation details.
10. Update this architecture document when a major component or responsibility changes.

## 13. Definition of Done

A feature is complete only when:

- Behavior is documented
- Error cases are defined
- Relevant automated tests pass
- Manual platform validation is complete
- Terminal state is restored after exit
- Security implications have been reviewed
- README instructions are updated
- Changelog entry is added
- Versioning impact is determined

## 14. Current State

As of the current repository state:

- macOS dashboard V2.2 exists and is working
- macOS and Windows folders have been introduced
- Windows implementation is not yet available
- Root README exists but still reflects a primarily macOS-only layout
- Global installer and persistent configuration are not yet implemented
- Auto-resume uses the latest non-interactive session rather than a selected structured session

The next recommended implementation milestone is **V2.3: Installation and Configuration**.
