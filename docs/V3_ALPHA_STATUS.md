# Codex Dashboard V3 Alpha Status

## Release

Current development version:

```text
3.0.0-alpha.2
```

Development branch:

```text
v3-development
```

The frozen V2.2 implementation remains unchanged at:

```text
macOS/codex-usage-dashboard-v2.2.sh
```

## Implemented in Alpha 1

- [x] Separate V3 source tree under `macOS/v3/`
- [x] Stable command router
- [x] `--version` and `--help`
- [x] Authentication module
- [x] API client module
- [x] Normalized usage and credit model
- [x] Independent countdown engine
- [x] Terminal renderer using the alternate screen
- [x] Partial one-second countdown updates
- [x] Terminal width and height checks
- [x] Persistent JSON configuration
- [x] Safe default resume mode of `confirm`
- [x] Project add, list, remove, and default commands
- [x] Rate-limit transition detection
- [x] Duplicate reset-event protection
- [x] Git working-tree inspection before resume
- [x] Automatic-resume block when the working tree is dirty
- [x] Resume logging outside the project repository
- [x] Global macOS installer
- [x] macOS uninstaller that preserves configuration by default
- [x] Fixture-based regression suite
- [x] GitHub Actions workflow for syntax, ShellCheck, and tests
- [x] Signal handlers that terminate the dashboard cleanly

## Implemented in Alpha 2

- [x] Interactive first-run setup wizard
- [x] First launch automatically offers setup when no configuration exists
- [x] Resume-mode selection with descriptions
- [x] Safe default selection of `confirm`
- [x] Explicit opt-in for `automatic`
- [x] Configurable API refresh interval
- [x] `config resume-mode MODE`
- [x] `config refresh SECONDS`
- [x] macOS folder picker for project registration
- [x] `project add` works without a typed path
- [x] Setup summary and final confirmation before saving
- [x] Setup cancellation leaves configuration unchanged
- [x] Atomic setup rollback when project registration fails
- [x] Notification Center helper
- [x] Notifications for notify, confirm, automatic, blocked, skipped, failed, and started resume states
- [x] Backward-compatible migration for Alpha 1 configuration files
- [x] Additional setup, configuration, folder-picker, and notification regression checks

## Verified by the User

- [x] Live dashboard works with real Codex authentication
- [x] Global installer works
- [x] Global `codex-dashboard` command works outside the repository
- [x] `Control + C` restores the Terminal and terminates the process
- [x] Alpha 1 regression suite passed with 25 tests and zero failures

## Alpha 2 Verification Required on macOS

- [ ] Pull `v3-development`
- [ ] Run `bash macOS/v3/tests/run-tests.sh`
- [ ] Confirm all expanded regression tests pass
- [ ] Run `bash macOS/v3/bin/codex-dashboard --version`
- [ ] Run setup against a temporary configuration directory
- [ ] Cancel setup and confirm no configuration file is created
- [ ] Complete setup using the folder picker
- [ ] Verify `config resume-mode off`
- [ ] Verify `config resume-mode notify`
- [ ] Verify `config resume-mode confirm`
- [ ] Verify `config resume-mode automatic`
- [ ] Verify `config refresh 30`
- [ ] Verify `project add` opens the macOS folder picker
- [ ] Verify Notification Center displays a test transition notification
- [ ] Test `notify` mode during a real limited-to-available transition
- [ ] Test interactive `confirm` mode
- [ ] Test automatic resume with a clean Git working tree
- [ ] Confirm automatic resume is blocked with a dirty Git working tree
- [ ] Re-run the installer and confirm Alpha 2 replaces Alpha 1 application files while preserving configuration

## Other Verification Still Required

- [ ] Test narrow, minimum, normal, and wide terminal sizes
- [ ] Move and resize the Terminal window continuously for two minutes
- [ ] Confirm no duplicate dashboards or crashes
- [ ] Test a failed API refresh while preserving last known good data
- [ ] Test zero and multiple reset-credit records in the renderer
- [ ] Run uninstall with and without `--remove-config`
- [ ] Review and resolve all ShellCheck findings from CI

## Deferred to Later V3 Alphas

- [ ] Resume details viewer
- [ ] Update command and release artifact installation
- [ ] Checksummed release packaging
- [ ] Homebrew tap
- [ ] Windows PowerShell implementation
- [ ] Structured Codex session selection

## Run From the Development Branch

```bash
git switch v3-development
git pull origin v3-development
bash macOS/v3/bin/codex-dashboard --version
bash macOS/v3/bin/codex-dashboard setup
bash macOS/v3/bin/codex-dashboard project add
bash macOS/v3/bin/codex-dashboard
```

## Run Tests

```bash
bash macOS/v3/tests/run-tests.sh
```

V3 remains an alpha until the live setup, notification, resume-mode, and resize verification checklists are complete.
