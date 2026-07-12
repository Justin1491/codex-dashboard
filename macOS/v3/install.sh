#!/usr/bin/env bash
set -euo pipefail

APP_NAME='codex-dashboard'
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
INSTALL_DIR="${CODEX_DASHBOARD_INSTALL_DIR:-$HOME/.local/share/codex-dashboard/v3}"
BIN_DIR="${CODEX_DASHBOARD_BIN_DIR:-$HOME/.local/bin}"
COMMAND_PATH="$BIN_DIR/$APP_NAME"

[[ "$(uname -s)" == 'Darwin' ]] || {
  printf 'This installer currently supports macOS only.\n' >&2
  exit 1
}

command -v curl >/dev/null 2>&1 || {
  printf 'curl is required.\n' >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || {
  printf 'jq is required. Install it with: brew install jq\n' >&2
  exit 1
}

mkdir -p "$INSTALL_DIR" "$BIN_DIR"
rm -rf "$INSTALL_DIR/bin" "$INSTALL_DIR/lib"
cp -R "$SOURCE_DIR/bin" "$SOURCE_DIR/lib" "$INSTALL_DIR/"
chmod 700 "$INSTALL_DIR/bin/codex-dashboard"

cat >"$COMMAND_PATH" <<EOF_WRAPPER
#!/usr/bin/env bash
exec "$INSTALL_DIR/bin/codex-dashboard" "\$@"
EOF_WRAPPER
chmod 700 "$COMMAND_PATH"

if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
  SHELL_FILE="$HOME/.zshrc"
  PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
  if ! grep -Fqx "$PATH_LINE" "$SHELL_FILE" 2>/dev/null; then
    printf '\n%s\n' "$PATH_LINE" >>"$SHELL_FILE"
  fi
  printf 'Added ~/.local/bin to ~/.zshrc. Restart Terminal or run: source ~/.zshrc\n'
fi

printf 'Codex Dashboard V3 installed.\nRun: codex-dashboard\n'
