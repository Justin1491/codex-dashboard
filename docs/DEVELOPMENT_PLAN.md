# Codex Dashboard Development Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` or `superpowers:executing-plans` when implementing a milestone. Track progress by checking boxes in this document as work is completed and verified.

**Goal:** Evolve Codex Dashboard from a working macOS terminal script into a stable, installable, testable, cross-platform utility with safe Codex resume support.

**Architecture:** Maintain native macOS Bash and Windows PowerShell implementations with equivalent user-facing behavior. Separate command routing, authentication, API access, normalized state, countdown logic, rendering, configuration, project management, installation, and resume control into focused modules.

**Tech Stack:** Bash, PowerShell, `curl`, `jq`, Pester, ShellCheck, GitHub Actions, GitHub Releases, optional Homebrew packaging.

## Global Constraints

- Authentication must come from the user's existing Codex `auth.json` file.
- Access tokens and account IDs must never be printed, logged, copied, or committed.
- The dashboard must preserve the last known good data when API refreshes fail.
- Terminal rendering must not blink, duplicate, corrupt, or crash during resize events.
- Countdown logic must be independent from rendering and testable with fixed timestamps.
- Auto-resume must be disabled by default.
- Automatic resume must never fire more than once for the same reset event.
- The project must support macOS first and add Windows parity after the macOS architecture is stable.
- Undocumented API fields must have safe defaults and graceful failure behavior.
- Every milestone requires tests, documentation updates, and a focused commit.

---

## Current Baseline

### Completed

- [x] Create the `Justin1491/codex-dashboard` repository.
- [x] Build a working macOS usage dashboard.
- [x] Display five-hour usage and reset time.
- [x] Display weekly usage and reset time.
- [x] Display available reset-credit count.
- [x] Display individual reset-credit records and expiration countdowns.
- [x] Convert API timestamps to local system time.
- [x] Add live countdown timers.
- [x] Reduce full-screen blinking during normal countdown updates.
- [x] Add terminal resize handling.
- [x] Add optional prototype auto-resume using `codex exec resume --last`.
- [x] Create a general README.
- [x] Split the repository into `macOS/` and `Windows/` folders.
- [x] Add a Windows placeholder.
- [x] Create `docs/PROJECT_ARCHITECTURE.md`.

### Baseline verification still required

- [ ] Confirm the current macOS script path and filename in the repository.
- [ ] Run `bash -n` against the current macOS script.
- [ ] Test the current dashboard at narrow, minimum, normal, and very wide terminal sizes.
- [ ] Test repeated window movement and resizing for at least two minutes.
- [ ] Test API refresh failure while preserving the last successful data.
- [ ] Test zero reset credits.
- [ ] Test multiple reset-credit records.
- [ ] Test clean exit with `Control + C` and verify terminal restoration.
- [ ] Tag the verified baseline as `v2.2.0` or the next accurate version.

---

# Milestone 1: Repository Cleanup and Stable Command

**Outcome:** The repository has predictable names, a stable executable entry point, and accurate documentation.

## File structure

- [ ] Confirm this minimum structure:

```text
codex-dashboard/
├── README.md
├── .gitignore
├── docs/
│   ├── PROJECT_ARCHITECTURE.md
│   └── DEVELOPMENT_PLAN.md
├── macOS/
│   ├── README.md
│   └── codex-dashboard.sh
└── Windows/
    └── README.md
```

## Tasks

- [ ] Rename the current versioned macOS script to `macOS/codex-dashboard.sh`.
- [ ] Keep version information inside the script instead of the filename.
- [ ] Add `--version` output.
- [ ] Add consistent `--help` output.
- [ ] Update the root README to use `macOS/codex-dashboard.sh`.
- [ ] Add a macOS-specific README with direct run instructions.
- [ ] Confirm `.gitignore` excludes credentials and local configuration.
- [ ] Add `CHANGELOG.md` with the current baseline release.
- [ ] Select and add a project license.

## Verification

- [ ] Run:

```bash
bash -n macOS/codex-dashboard.sh
```

- [ ] Verify:

```bash
macOS/codex-dashboard.sh --version
macOS/codex-dashboard.sh --help
```

- [ ] Confirm no secret-like values are tracked:

```bash
git grep -nE 'access_token|account_id|Bearer [A-Za-z0-9_-]{20,}|eyJ'
```

- [ ] Commit:

```bash
git add README.md CHANGELOG.md LICENSE .gitignore macOS Windows docs
git commit -m "chore: establish stable project structure"
```

---

# Milestone 2: macOS Modularization

**Outcome:** The macOS implementation is split into small, testable components rather than one large script.

## Target files

```text
macOS/
├── README.md
├── bin/
│   └── codex-dashboard
├── lib/
│   ├── auth.sh
│   ├── api.sh
│   ├── model.sh
│   ├── countdown.sh
│   ├── display.sh
│   ├── config.sh
│   ├── projects.sh
│   └── resume.sh
└── tests/
    ├── fixtures/
    │   ├── usage-normal.json
    │   ├── usage-rate-limited.json
    │   ├── usage-missing-fields.json
    │   ├── credits-empty.json
    │   └── credits-multiple.json
    ├── test_auth.sh
    ├── test_api.sh
    ├── test_model.sh
    ├── test_countdown.sh
    ├── test_display.sh
    └── test_resume.sh
```

## Task 2.1: Authentication module

- [ ] Create `macOS/lib/auth.sh`.
- [ ] Add `resolve_auth_path`.
- [ ] Add `load_codex_credentials`.
- [ ] Validate missing file, malformed JSON, missing token, and missing account ID.
- [ ] Ensure credentials remain in memory only.
- [ ] Add fixture-based tests.
- [ ] Commit:

```bash
git add macOS/lib/auth.sh macOS/tests/test_auth.sh
git commit -m "refactor: isolate macOS authentication"
```

## Task 2.2: API client

- [ ] Create `macOS/lib/api.sh`.
- [ ] Add usage and reset-credit request functions.
- [ ] Support endpoint overrides with environment variables.
- [ ] Validate HTTP errors and invalid JSON.
- [ ] Preserve last known good state after refresh failure.
- [ ] Add mocked response tests.
- [ ] Commit:

```bash
git add macOS/lib/api.sh macOS/tests/test_api.sh macOS/tests/fixtures
git commit -m "refactor: isolate Codex API client"
```

## Task 2.3: Normalized model

- [ ] Create `macOS/lib/model.sh`.
- [ ] Convert raw usage JSON into stable fields.
- [ ] Convert reset-credit JSON into stable records.
- [ ] Calculate remaining percentage from used percentage.
- [ ] Clamp percentages to `0...100`.
- [ ] Handle missing windows and null credit arrays.
- [ ] Add model tests for normal, limited, missing, and malformed data.
- [ ] Commit:

```bash
git add macOS/lib/model.sh macOS/tests/test_model.sh
git commit -m "refactor: normalize Codex usage state"
```

## Task 2.4: Countdown engine

- [ ] Create `macOS/lib/countdown.sh`.
- [ ] Add epoch-to-local-time conversion.
- [ ] Add fixed-time countdown calculation.
- [ ] Return `active`, `ready`, and `unknown` states.
- [ ] Add tests at second, minute, hour, day, and expiration boundaries.
- [ ] Verify daylight-saving changes use the local system time correctly.
- [ ] Commit:

```bash
git add macOS/lib/countdown.sh macOS/tests/test_countdown.sh
git commit -m "refactor: isolate countdown engine"
```

## Task 2.5: Renderer

- [ ] Create `macOS/lib/display.sh`.
- [ ] Draw the full dashboard from normalized state.
- [ ] Update only changed fields during one-second ticks.
- [ ] Detect valid width and height without exiting on transient errors.
- [ ] Use the alternate screen and restore terminal state on exit.
- [ ] Center the dashboard on wide terminals.
- [ ] Add a narrow-window fallback.
- [ ] Avoid ambiguous-width glyphs unless verified.
- [ ] Add rendering snapshot tests using ANSI-stripped output.
- [ ] Commit:

```bash
git add macOS/lib/display.sh macOS/tests/test_display.sh
git commit -m "refactor: isolate terminal renderer"
```

## Task 2.6: Command router

- [ ] Create `macOS/bin/codex-dashboard`.
- [ ] Route dashboard, setup, config, project, update, and uninstall commands.
- [ ] Keep API and rendering logic out of the router.
- [ ] Preserve current dashboard behavior.
- [ ] Update `macOS/README.md`.
- [ ] Commit:

```bash
git add macOS/bin/codex-dashboard macOS/README.md
git commit -m "refactor: add macOS command router"
```

## Milestone verification

- [ ] Run all macOS tests.
- [ ] Run ShellCheck with no unresolved errors.
- [ ] Run the dashboard manually against live Codex data.
- [ ] Resize continuously without duplicate dashboards or crashes.
- [ ] Confirm `Control + C` restores cursor, colors, and prior terminal contents.

---

# Milestone 3: Global macOS Installation

**Outcome:** A user can install once and run `codex-dashboard` from any directory.

## Target files

```text
macOS/
├── install.sh
├── uninstall.sh
└── bin/codex-dashboard
```

## Installer checklist

- [ ] Detect macOS using `uname -s`.
- [ ] Check for `curl` and `jq`.
- [ ] Explain how to install missing dependencies.
- [ ] Install application files under `~/.local/share/codex-dashboard/`.
- [ ] Create `~/.local/bin/codex-dashboard`.
- [ ] Add `~/.local/bin` to PATH only when needed.
- [ ] Preserve existing configuration during reinstall or upgrade.
- [ ] Never copy or modify `auth.json`.
- [ ] Print a clear success message and run command.
- [ ] Add an idempotency test by running the installer twice.

## Uninstaller checklist

- [ ] Remove installed application files.
- [ ] Remove the command wrapper.
- [ ] Preserve configuration by default.
- [ ] Support an explicit option to remove configuration.
- [ ] Never remove Codex authentication files.

## Verification

- [ ] Test installation on a clean macOS user account or temporary home directory.
- [ ] Verify `codex-dashboard --version` works from an unrelated directory.
- [ ] Verify reinstall does not duplicate PATH entries.
- [ ] Verify uninstall removes only project-owned files.
- [ ] Commit:

```bash
git add macOS/install.sh macOS/uninstall.sh README.md macOS/README.md
git commit -m "feat: add global macOS installation"
```

---

# Milestone 4: Persistent Configuration and Project Registry

**Outcome:** Users no longer need to launch from a project directory or repeatedly supply project paths.

## Configuration schema

```json
{
  "version": 1,
  "refreshSeconds": 60,
  "resumeMode": "confirm",
  "defaultProjectId": null,
  "projects": [],
  "display": {
    "compact": false,
    "showSeconds": true
  }
}
```

## Configuration checklist

- [ ] Create `macOS/lib/config.sh`.
- [ ] Store configuration at `~/.config/codex-dashboard/config.json`.
- [ ] Create default configuration on first run.
- [ ] Validate schema version and supported values.
- [ ] Reject malformed JSON with repair instructions.
- [ ] Add `codex-dashboard setup`.
- [ ] Add `codex-dashboard config show`.
- [ ] Add `codex-dashboard config reset`.
- [ ] Add tests using a temporary config directory.

## Project registry checklist

- [ ] Create `macOS/lib/projects.sh`.
- [ ] Add `codex-dashboard project add PATH`.
- [ ] Infer a default display name from the folder name.
- [ ] Allow an explicit project name.
- [ ] Prevent duplicate paths and duplicate IDs.
- [ ] Add `project list`.
- [ ] Add `project remove NAME_OR_ID`.
- [ ] Add `project default NAME_OR_ID`.
- [ ] Validate project paths before use.
- [ ] Allow the dashboard to run from any current directory.
- [ ] Add tests for add, list, remove, duplicate, and missing-path cases.

## First-run flow

- [ ] Detect missing configuration.
- [ ] Explain the four resume modes: `off`, `notify`, `confirm`, `automatic`.
- [ ] Default to `confirm` or `off`, never `automatic`.
- [ ] Offer project registration.
- [ ] Save the choices only after confirmation.

## Verification

- [ ] Install globally.
- [ ] Change to `/tmp`.
- [ ] Run `codex-dashboard` successfully.
- [ ] Select a saved project without supplying `--project`.
- [ ] Commit:

```bash
git add macOS/lib/config.sh macOS/lib/projects.sh macOS/bin/codex-dashboard macOS/tests README.md
git commit -m "feat: add configuration and project registry"
```

---

# Milestone 5: Safe Resume Controller

**Outcome:** Resume behavior is understandable, project-aware, and protected against duplicate or unsafe execution.

## Resume modes

- [ ] `off`: no resume or notification behavior.
- [ ] `notify`: alert when Codex becomes available.
- [ ] `confirm`: ask the user before resuming.
- [ ] `automatic`: resume only after all safety checks pass.

## State-transition checklist

- [ ] Detect a transition from rate-limited to available.
- [ ] Create a stable reset-event identifier.
- [ ] Prevent more than one resume attempt for the same event.
- [ ] Persist the last handled event when appropriate.
- [ ] Do not trigger merely because the dashboard starts while Codex is already available.

## Safety checks

- [ ] Verify the configured project exists.
- [ ] Detect whether the project is a Git repository.
- [ ] Capture `git status --porcelain` before resume.
- [ ] Detect an existing Codex resume process.
- [ ] Require confirmation when the repository has uncommitted changes in `confirm` mode.
- [ ] Block automatic resume when required information is missing.
- [ ] Write resume output to a project-safe or user-state log directory.
- [ ] Never include credentials in logs.

## User interaction

- [ ] Show project name and path.
- [ ] Show Git working-tree status.
- [ ] Show the applicable reset event.
- [ ] Provide resume, skip, and view-details actions.
- [ ] Provide a clear completion or failure status.

## Tests

- [ ] Transition from limited to available triggers once.
- [ ] Starting while already available does not trigger.
- [ ] Duplicate refreshes do not trigger duplicate resumes.
- [ ] Missing project blocks resume.
- [ ] Existing resume process blocks another resume.
- [ ] `off`, `notify`, `confirm`, and `automatic` behave distinctly.
- [ ] Failed Codex execution records a nonzero exit status.

## Commit

```bash
git add macOS/lib/resume.sh macOS/bin/codex-dashboard macOS/tests/test_resume.sh README.md
git commit -m "feat: add safe project-aware resume controller"
```

---

# Milestone 6: macOS Automated Tests and CI

**Outcome:** Every commit receives repeatable static and behavioral validation.

## Local tooling

- [ ] Add a single test runner such as `macOS/tests/run-tests.sh`.
- [ ] Add ShellCheck configuration when justified.
- [ ] Add fixtures for all known API states.
- [ ] Ensure tests never call live APIs by default.
- [ ] Add an explicit opt-in live integration test.

## Required test groups

- [ ] Authentication path resolution.
- [ ] Authentication validation.
- [ ] API response parsing.
- [ ] Missing and null fields.
- [ ] Percentage clamping.
- [ ] Countdown boundary calculations.
- [ ] Local time conversion.
- [ ] Terminal dimension fallback.
- [ ] Structural redraw decisions.
- [ ] Configuration validation.
- [ ] Project registry operations.
- [ ] Resume transition and duplicate prevention.
- [ ] Installer idempotency.

## GitHub Actions

- [ ] Create `.github/workflows/macos-tests.yml`.
- [ ] Run `bash -n` on all shell files.
- [ ] Run ShellCheck.
- [ ] Run the macOS test suite.
- [ ] Fail CI on any test failure.
- [ ] Add a status badge to the README after the workflow is stable.

## Commit

```bash
git add macOS/tests .github/workflows/macos-tests.yml README.md
git commit -m "ci: add macOS validation workflow"
```

---

# Milestone 7: macOS Release Packaging

**Outcome:** Users install versioned, checksummed releases rather than raw development files.

## Release assets

- [ ] Package macOS files into a versioned archive.
- [ ] Generate SHA-256 checksums.
- [ ] Add release notes from `CHANGELOG.md`.
- [ ] Add a release workflow.
- [ ] Verify installation from a release artifact.

## Updater

- [ ] Add `codex-dashboard update`.
- [ ] Query the latest GitHub release.
- [ ] Compare installed and available versions.
- [ ] Download the macOS archive.
- [ ] Verify its checksum.
- [ ] Replace application files atomically.
- [ ] Preserve configuration.
- [ ] Roll back when installation fails.

## Release verification

- [ ] Fresh install from release.
- [ ] Upgrade from the prior release.
- [ ] Failed checksum blocks installation.
- [ ] Failed replacement restores the previous version.
- [ ] Tag the release.

---

# Milestone 8: Windows PowerShell Implementation

**Outcome:** Windows users receive feature parity using native PowerShell.

## Target structure

```text
Windows/
├── README.md
├── CodexDashboard.ps1
├── modules/
│   ├── Auth.psm1
│   ├── Api.psm1
│   ├── Model.psm1
│   ├── Countdown.psm1
│   ├── Display.psm1
│   ├── Config.psm1
│   ├── Projects.psm1
│   └── Resume.psm1
├── install.ps1
├── uninstall.ps1
└── tests/
    ├── fixtures/
    └── CodexDashboard.Tests.ps1
```

## Compatibility

- [ ] Support Windows PowerShell 5.1.
- [ ] Support PowerShell 7+.
- [ ] Support Windows Terminal.
- [ ] Use `%LOCALAPPDATA%\CodexDashboard` for application files.
- [ ] Use `%APPDATA%\CodexDashboard\config.json` for configuration.

## Feature parity checklist

- [ ] Usage windows.
- [ ] Reset credits.
- [ ] Local reset times.
- [ ] Live countdowns.
- [ ] Stable resizing.
- [ ] Global command.
- [ ] Configuration.
- [ ] Project registry.
- [ ] Four resume modes.
- [ ] Safe resume checks.
- [ ] Installer and uninstaller.
- [ ] Update behavior.

## Windows tests and CI

- [ ] Add Pester tests.
- [ ] Add `.github/workflows/windows-tests.yml`.
- [ ] Run tests on Windows PowerShell 5.1 where available.
- [ ] Run tests on PowerShell 7.
- [ ] Verify installer behavior in a temporary user profile.

---

# Milestone 9: Distribution and Homebrew

**Outcome:** Installation becomes familiar and low-friction for public users.

## One-command installer

- [ ] Publish a reviewed `install.sh`.
- [ ] Document the curl-pipe installer and its security implications.
- [ ] Offer a manual download alternative.
- [ ] Pin installs to released artifacts rather than the development branch.

## Homebrew tap

- [ ] Create a Homebrew tap repository.
- [ ] Add a formula using a versioned GitHub release.
- [ ] Verify SHA-256 integrity.
- [ ] Test install, upgrade, and uninstall.
- [ ] Document:

```bash
brew tap Justin1491/codex-dashboard
brew install codex-dashboard
```

---

# Milestone 10: Structured Codex Session Management

**Outcome:** Users can select and resume a specific suspended Codex session rather than relying only on `--last`.

This milestone begins only after the installer, configuration, tests, and safe resume controller are stable.

- [ ] Research supported structured Codex session interfaces.
- [ ] Document the selected integration and its stability guarantees.
- [ ] List recent sessions by project.
- [ ] Show session title, project, last activity, and status.
- [ ] Select a specific session to resume.
- [ ] Distinguish rate-limited, waiting-for-approval, completed, and failed sessions.
- [ ] Preserve the existing `--last` fallback when structured data is unavailable.
- [ ] Add integration tests using recorded or mocked session data.

---

# Documentation Checklist

- [ ] Root README reflects the current stable release.
- [ ] `macOS/README.md` contains macOS-specific install and troubleshooting steps.
- [ ] `Windows/README.md` clearly states current Windows support status.
- [ ] `docs/PROJECT_ARCHITECTURE.md` matches implemented file paths.
- [ ] `docs/DEVELOPMENT_PLAN.md` checkboxes reflect actual project status.
- [ ] `docs/SECURITY.md` explains credential handling and reporting vulnerabilities.
- [ ] `docs/RELEASE_PROCESS.md` defines versioning, testing, tagging, and rollback.
- [ ] `CHANGELOG.md` is updated for every release.
- [ ] Screenshots match the current UI.
- [ ] Undocumented endpoint limitations are clearly disclosed.

---

# Release Definition of Done

A release is complete only when every applicable item below is checked:

- [ ] All planned functionality is implemented.
- [ ] All automated tests pass locally.
- [ ] GitHub Actions passes.
- [ ] ShellCheck or PSScriptAnalyzer has no unresolved critical findings.
- [ ] Manual terminal resize testing passes.
- [ ] API failure behavior preserves the last known good state.
- [ ] Authentication data is not printed or persisted.
- [ ] Installer and uninstaller behavior is verified.
- [ ] Upgrade behavior is verified when applicable.
- [ ] README and platform documentation are current.
- [ ] `CHANGELOG.md` is updated.
- [ ] Version output matches the release tag.
- [ ] Release artifacts and checksums are published.
- [ ] Rollback instructions are documented.

---

# Recommended Execution Order

1. [ ] Verify and tag the current baseline.
2. [ ] Complete repository cleanup and stable naming.
3. [ ] Modularize the macOS implementation.
4. [ ] Add macOS tests and CI.
5. [ ] Add global installation.
6. [ ] Add persistent configuration and project registry.
7. [ ] Replace prototype auto-resume with the safe resume controller.
8. [ ] Package a stable macOS release.
9. [ ] Build Windows parity.
10. [ ] Add Homebrew distribution.
11. [ ] Add structured Codex session selection.

The immediate next milestone is **Milestone 1: Repository Cleanup and Stable Command**. Do not begin structured session management or Windows feature parity until the macOS module boundaries and tests are stable.