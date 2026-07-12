# Codex Dashboard V3 Alpha Status

## Release

Current development version:

```text
3.0.0-alpha.1
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

## Locally Verified Before Commit

- [x] Bash syntax validation across all V3 shell files
- [x] `codex-dashboard --version`
- [x] `codex-dashboard --help`
- [x] Configuration creation
- [x] Project registration and listing
- [x] Twenty-five regression assertions with zero failures

## Verification Still Required on macOS

- [ ] Run the live dashboard using real Codex authentication
- [ ] Test narrow, minimum, normal, and wide terminal sizes
- [ ] Move and resize the Terminal window continuously for two minutes
- [ ] Confirm no duplicate dashboards or crashes
- [ ] Confirm `Control + C` restores the previous terminal screen
- [ ] Test a failed API refresh while preserving last known good data
- [ ] Test zero and multiple reset-credit records in the renderer
- [ ] Test `notify` mode
- [ ] Test interactive `confirm` mode
- [ ] Test automatic resume with a clean Git working tree
- [ ] Confirm automatic resume is blocked with a dirty Git working tree
- [ ] Run the installer twice and confirm PATH is not duplicated
- [ ] Run uninstall with and without `--remove-config`
- [ ] Review and resolve all ShellCheck findings from CI

## Deferred to Later V3 Alphas

- [ ] Interactive first-run setup wizard
- [ ] Configuration editing commands beyond show and reset
- [ ] Notification Center integration
- [ ] Resume details viewer
- [ ] Update command and release artifact installation
- [ ] Checksummed release packaging
- [ ] Homebrew tap
- [ ] Windows PowerShell implementation
- [ ] Structured Codex session selection

## Run From the Development Branch

```bash
git switch v3-development
bash macOS/v3/bin/codex-dashboard --version
bash macOS/v3/bin/codex-dashboard setup
bash macOS/v3/bin/codex-dashboard project add ~/Developer/MyProject
bash macOS/v3/bin/codex-dashboard
```

## Run Tests

```bash
bash macOS/v3/tests/run-tests.sh
```

V3 remains an alpha until the macOS live-dashboard and resize verification checklist is complete.
