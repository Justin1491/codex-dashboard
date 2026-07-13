# Interactive Auto-Resume Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add in-dashboard auto-resume configuration on macOS and Windows using the A key.

**Architecture:** Preserve the stable platform cores and inject the interactive feature from the compatibility launchers. Validate overlay application before executing the transformed core.

**Tech Stack:** Bash 3.2-compatible shell, Perl runtime text transformation, Windows PowerShell 5.1-compatible script transformation, pytest.

## Global Constraints

- Existing command-line options must continue to work.
- The stable core files must not be modified.
- Plain `A` is used because macOS Terminal reserves Command+A.
- Version displayed by both dashboards becomes `2.5.0`.

---

### Task 1: Regression tests

**Files:**
- Create: `tests/test_interactive_auto_resume.py`

- [x] Write tests that require the A-key instructions, interactive configuration functions, project validation, enabled-state variables, and existing CLI forwarding.
- [x] Run the tests and confirm they fail before implementation.

### Task 2: macOS overlay

**Files:**
- Modify: `macOS/codex-usage-dashboard.sh`

- [x] Inject configuration, path resolution, change/disable choices, key polling, armed status, and footer instructions.
- [x] Validate transformed markers before running the core.
- [x] Run `bash -n macOS/codex-usage-dashboard.sh`.
- [x] Execute the transformed-core fixture test.

### Task 3: Windows overlay

**Files:**
- Modify: `Windows/CodexDashboard.ps1`

- [x] Inject configuration, path resolution, change/disable choices, key polling, project display, and footer instructions.
- [x] Route resume execution through mutable script-scoped settings.
- [x] Normalize line endings and validate required transformed markers before compiling the script block.

### Task 4: Final verification and publish

**Files:**
- Create: `docs/superpowers/specs/2026-07-13-interactive-auto-resume-design.md`
- Create: `docs/superpowers/plans/2026-07-13-interactive-auto-resume.md`

- [x] Run the complete local test suite and Bash syntax check.
- [x] Publish the files to `feature/interactive-auto-resume`.
- [ ] Review the branch diff and merge to `main`.
