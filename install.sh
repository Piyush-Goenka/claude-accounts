#!/usr/bin/env bash
# claude-accounts installer
#   remote:  curl -fsSL https://raw.githubusercontent.com/Piyush-Goenka/claude-accounts/main/install.sh | bash
#   local:   ./install.sh   (from a repo checkout — installs the local copy)
set -euo pipefail

REPO="Piyush-Goenka/claude-accounts"
DEST_DIR="$HOME/.config/zsh"
DEST="$DEST_DIR/claude-accounts.zsh"
ZSHRC="$HOME/.zshrc"

mkdir -p "$DEST_DIR"

# Prefer a local copy when running from a checkout; otherwise fetch latest release.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd || true)"
if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/claude-accounts.zsh" ]]; then
  cp "$SCRIPT_DIR/claude-accounts.zsh" "$DEST"
  echo "installed local copy → $DEST"
else
  curl -fsSL "https://github.com/$REPO/releases/latest/download/claude-accounts.zsh" -o "$DEST"
  echo "installed latest release → $DEST"
fi

# Sanity-check before wiring it into the shell
zsh -n "$DEST"

# Idempotently add the import line to .zshrc
LINE='[[ -f "$HOME/.config/zsh/claude-accounts.zsh" ]] && source "$HOME/.config/zsh/claude-accounts.zsh"'
if ! grep -qF 'claude-accounts.zsh' "$ZSHRC" 2>/dev/null; then
  printf '\n# Claude multi-account manager\n%s\n' "$LINE" >> "$ZSHRC"
  echo "added import line to $ZSHRC"
else
  echo "import line already present in $ZSHRC"
fi

echo ""
echo "✅ done. restart your terminal (or: source ~/.zshrc), then:"
echo "   claude-create <name>    →    claude-<name>    →    /login"
