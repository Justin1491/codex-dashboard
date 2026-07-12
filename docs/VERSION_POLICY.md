# Codex Dashboard Version Policy

## Stable release

The current macOS release is **v2.2.0**.

Stable implementation:

```text
macOS/codex-usage-dashboard-v2.2.sh
```

This release is considered feature complete and frozen.

## Maintenance policy for v2.2.0

The stable V2.2 implementation may be changed only for:

- Critical security fixes
- Backend endpoint compatibility fixes
- Crash fixes
- Severe data-display defects that make the dashboard unusable

The stable release must not receive:

- New features
- Architectural refactors
- New installation behavior
- New configuration systems
- New resume modes
- Experimental UI changes

Any permitted maintenance change must preserve existing command-line behavior unless a security or compatibility issue makes that impossible.

## Future development

All new development begins with V3 and must occur separately from the stable V2.2 implementation.

Primary development branch:

```text
v3-development
```

Target V3 location:

```text
macOS/v3/
```

V3 may introduce:

- Modular source files
- Global installation
- Persistent configuration
- Project registration
- Safer resume modes
- Session selection
- Automated tests and CI
- Release packaging
- Windows parity

V3 work must not overwrite, rename, or silently replace the V2.2 script.

## Release naming

Use semantic versions:

```text
MAJOR.MINOR.PATCH
```

Examples:

- `2.2.0`: frozen stable release
- `2.2.1`: critical maintenance fix only
- `3.0.0-alpha.1`: early V3 development release
- `3.0.0-beta.1`: feature-complete V3 test release
- `3.0.0`: stable V3 release

## Compatibility promise

Users who choose V2.2 must be able to continue using that version even after V3 is released.

A future installer may offer V3, but it must not automatically remove the V2.2 file or configuration. Migration must be explicit and documented.

## Branch policy

- `main`: stable public documentation and stable releases
- `v2.2-stable`: permanent reference branch for V2.2
- `v3-development`: active V3 development

Feature work must not be committed directly to the V2.2 stable branch.

## Definition of frozen

A frozen release remains available, documented, and runnable. It is not deleted when a newer version is created. New development happens beside it, not on top of it.
