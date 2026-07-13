# Interactive Auto-Resume Design

## Goal

Allow users to configure automatic Codex resume from the running macOS or Windows dashboard by pressing **A**, without restarting the dashboard or remembering command-line flags.

## Interaction

- The dashboard footer displays `Press A to configure auto-resume` alongside the existing exit instruction.
- When auto-resume is off, pressing **A** prompts for a project folder, validates it, confirms the selection, and arms auto-resume.
- When auto-resume is already armed, pressing **A** offers **Change project**, **Disable**, or **Cancel**.
- `~` paths on macOS and Windows environment-variable paths are resolved before validation.
- Existing `--auto-resume` / `--project` and `-AutoResume` / `-Project` options remain supported.

## Architecture

The known-good dashboard cores remain unchanged. Each compatibility launcher transforms the core text at runtime to inject the interactive functions, key polling, status display, and version `2.5.0`. The launcher validates that all required overlay markers were applied before executing the transformed core.

## Safety and Errors

- The selected project must exist and be a directory.
- The `codex` command must be available before arming.
- Invalid paths or missing Codex display an error and return to the dashboard without changing the existing configuration.
- Disabling auto-resume does not terminate a resume process that has already started.

## Verification

- Bash syntax validation for the macOS launcher.
- Automated source checks for both launchers.
- A macOS fixture test executes the transformed core and verifies the version, injected functions, footer text, loop polling, and `~/` path resolution.
- Windows overlay marker validation fails at runtime if the stable core no longer matches expected insertion points.
