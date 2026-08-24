#!/usr/bin/env bash
# claude-accounts installer
#   remote:  curl -fsSL https://raw.githubusercontent.com/Piyush-Goenka/claude-accounts/main/install.sh | bash
#   local:   ./install.sh   (from a repo checkout, installs the local copy)
set -euo pipefail

REPO="Piyush-Goenka/claude-accounts"
DEST_DIR="$HOME/.config/zsh"
DEST="$DEST_DIR/claude-accounts.zsh"
ZSHRC="$HOME/.zshrc"

# output helpers (Claude palette; plain text when not a terminal)
c()    { if [[ -t 1 ]]; then printf '\e[%sm%s\e[0m' "$1" "$2"; else printf '%s' "$2"; fi; }
row()  { printf '  %s %-22s %s\n' "$(c "$1" "$2")" "$3" "$(c '38;5;180' "${4:-}")"; }
ok()   { row '38;5;173' '✓' "$1" "${2:-}"; }
skip() { row '2'        '·' "$1" "${2:-}"; }
fail() { row '38;5;167' '✗' "$1" "${2:-}" >&2; exit 1; }
nxt()  { printf '\n  %s  %s\n' "$(c '1;38;5;173' 'next')" "$(c '1' "$1")"; }
dim()  { printf '  %s\n' "$(c '2' "$1")"; }

echo ""
mkdir -p "$DEST_DIR"

# Prefer a local copy when running from a checkout; otherwise fetch latest release.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd || true)"
if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/claude-accounts.zsh" ]]; then
  cp "$SCRIPT_DIR/claude-accounts.zsh" "$DEST"
else
  curl -fsSL "https://github.com/$REPO/releases/latest/download/claude-accounts.zsh" -o "$DEST" \
    || fail "download failed" "check your connection and try again"
fi

# Sanity-check before wiring it into the shell
zsh -n "$DEST" || fail "install failed" "downloaded file looks corrupted, please try again"

VERSION="$(grep -m1 'CLAUDE_ACCOUNTS_VERSION=' "$DEST" | cut -d'"' -f2)"
ok "installed" "claude-accounts v${VERSION:-?}"

# Idempotently add the import line to .zshrc
LINE='[[ -f "$HOME/.config/zsh/claude-accounts.zsh" ]] && source "$HOME/.config/zsh/claude-accounts.zsh"'
if grep -qF 'claude-accounts.zsh' "$ZSHRC" 2>/dev/null; then
  skip "shell" "already configured"
else
  printf '\n# Claude multi-account manager\n%s\n' "$LINE" >> "$ZSHRC"
  ok "shell configured"
fi

nxt "open a new terminal   (or: source ~/.zshrc)"
dim "      claude-create <name>  →  claude-<name>  →  /login"
echo ""
