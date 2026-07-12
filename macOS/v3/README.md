# Codex Dashboard V3 Alpha

V3 is developed separately from the frozen V2.2 release.

## Current alpha

```text
3.0.0-alpha.1
```

## Run from the repository

```bash
macOS/v3/bin/codex-dashboard --version
macOS/v3/bin/codex-dashboard setup
macOS/v3/bin/codex-dashboard project add ~/Developer/MyProject
macOS/v3/bin/codex-dashboard
```

## Install globally

```bash
macOS/v3/install.sh
codex-dashboard
```

## Commands

```text
codex-dashboard
codex-dashboard setup
codex-dashboard config show
codex-dashboard config reset
codex-dashboard project add PATH [NAME]
codex-dashboard project list
codex-dashboard project remove NAME_OR_ID
codex-dashboard project default NAME_OR_ID
codex-dashboard --version
codex-dashboard --help
```

Configuration is stored at `~/.config/codex-dashboard/config.json`. Authentication remains in the user's existing Codex `auth.json` and is never copied.

Resume mode defaults to `confirm`. The supported modes in configuration are `off`, `notify`, `confirm`, and `automatic`.

## Tests

```bash
macOS/v3/tests/run-tests.sh
```

V3 is an alpha release. Continue using `macOS/codex-usage-dashboard-v2.2.sh` for the frozen stable version until V3 completes verification.
