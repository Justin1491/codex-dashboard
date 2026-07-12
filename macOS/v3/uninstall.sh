#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${CODEX_DASHBOARD_INSTALL_DIR:-$HOME/.local/share/codex-dashboard/v3}"
BIN_DIR="${CODEX_DASHBOARD_BIN_DIR:-$HOME/.local/bin}"
CONFIG_DIR="${CODEX_DASHBOARD_CONFIG_DIR:-$HOME/.config/codex-dashboard}"
REMOVE_CONFIG=false

if [[ "${1:-}" == '--remove-config' ]]; then
  REMOVE_CONFIG=true
fi

rm -rf "$INSTALL_DIR"
rm -f "$BIN_DIR/codex-dashboard"

if [[ "$REMOVE_CONFIG" == 'true' ]]; then
  rm -rf "$CONFIG_DIR"
fi

printf 'Codex Dashboard V3 uninstalled.\n'
if [[ "$REMOVE_CONFIG" != 'true' ]]; then
  printf 'Configuration preserved at: %s\n' "$CONFIG_DIR"
fi
