#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
printf 'Notice: codex-usage-dashboard-v2.2.sh has been renamed to codex-usage-dashboard.sh.\n' >&2
exec "$script_dir/codex-usage-dashboard.sh" "$@"
