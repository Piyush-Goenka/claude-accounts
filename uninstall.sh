#!/usr/bin/env bash
# claude-accounts uninstaller
# Removes the tool ONLY. Profile dirs (~/.claude-*) and Keychain credentials
# are left untouched — remove those per-profile with `claude-delete <name>`
# BEFORE uninstalling if you want them gone too.
set -euo pipefail

DEST="$HOME/.config/zsh/claude-accounts.zsh"
ZSHRC="$HOME/.zshrc"

rm -f "$DEST" "$DEST.bak" "$HOME/.cache/claude-accounts-check"
echo "removed $DEST"

if grep -qF 'claude-accounts.zsh' "$ZSHRC" 2>/dev/null; then
  sed -i '' '/# Claude multi-account manager/d;/claude-accounts\.zsh/d' "$ZSHRC"
  echo "removed import line from $ZSHRC"
fi

REMAINING=$(ls -d "$HOME"/.claude-*/ 2>/dev/null | wc -l | tr -d ' ')
if [[ "$REMAINING" != "0" ]]; then
  echo ""
  echo "note: $REMAINING profile dir(s) still exist (~/.claude-*) with their"
  echo "Keychain credentials. Reinstall and use 'claude-delete <name>' to remove"
  echo "them cleanly, or delete dirs manually + credentials via Keychain Access."
fi

echo "✅ uninstalled. restart your terminal to clear loaded functions/aliases."
