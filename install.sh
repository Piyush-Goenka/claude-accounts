#!/usr/bin/env bash
# claude-accounts installer
#   remote:  curl -fsSL https://raw.githubusercontent.com/Piyush-Goenka/claude-accounts/main/install.sh | bash
#   local:   ./install.sh   (from a repo checkout — installs the local copy)
set -euo pipefail

REPO="Piyush-Goenka/claude-accounts"
DEST_DIR="$HOME/.config/zsh"
DEST="$DEST_DIR/claude-accounts.zsh"
ZSHRC="$HOME/.zshrc"

fail() { echo "  ✗ $1" >&2; exit 1; }

echo ""
echo "  claude-accounts"
echo "  ─────────────────────────────"

mkdir -p "$DEST_DIR"

# Prefer a local copy when running from a checkout; otherwise fetch latest release.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd || true)"
if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/claude-accounts.zsh" ]]; then
  cp "$SCRIPT_DIR/claude-accounts.zsh" "$DEST"
else
  curl -fsSL "https://github.com/$REPO/releases/latest/download/claude-accounts.zsh" -o "$DEST" \
    || fail "download failed — check your connection and try again"
fi

# Sanity-check before wiring it into the shell
zsh -n "$DEST" || fail "downloaded file looks corrupted — please try again"

VERSION="$(grep -m1 'CLAUDE_ACCOUNTS_VERSION=' "$DEST" | cut -d'"' -f2)"
echo "  ✓ installed v${VERSION:-?}"

# Idempotently add the import line to .zshrc
LINE='[[ -f "$HOME/.config/zsh/claude-accounts.zsh" ]] && source "$HOME/.config/zsh/claude-accounts.zsh"'
if ! grep -qF 'claude-accounts.zsh' "$ZSHRC" 2>/dev/null; then
  printf '\n# Claude multi-account manager\n%s\n' "$LINE" >> "$ZSHRC"
fi
echo "  ✓ shell configured"

echo ""
echo "  Get started:"
echo "    1. restart your terminal (or: source ~/.zshrc)"
echo "    2. claude-create <name>"
echo "    3. claude-<name>  →  /login"
echo ""
