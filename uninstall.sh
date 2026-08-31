#!/usr/bin/env bash
# claude-accounts uninstaller
# Removes every profile (~/.claude-* dirs + their Keychain logins) EXCEPT the
# default account (~/.claude), then removes the tool itself.
set -euo pipefail

DEST="$HOME/.config/zsh/claude-accounts.zsh"
ZSHRC="$HOME/.zshrc"

# output helpers (Claude palette; plain text when not a terminal)
c()    { if [[ -t 1 ]]; then printf '\e[%sm%s\e[0m' "$1" "$2"; else printf '%s' "$2"; fi; }
row()  { printf '  %s %-22s %s\n' "$(c "$1" "$2")" "$3" "$(c '38;5;180' "${4:-}")"; }
ok()   { row '38;5;173' '✓' "$1" "${2:-}"; }
skip() { row '2'        '·' "$1" "${2:-}"; }
nxt()  { printf '\n  %s  %s\n' "$(c '1;38;5;173' 'next')" "$(c '1' "$1")"; }

echo ""
# remove every profile except the default account (same steps as claude-delete)
for d in "$HOME"/.claude-*/; do
  [[ -d "$d" ]] || continue
  d="${d%/}"
  name="${d##*/.claude-}"
  [[ "$name" == "science" ]] && continue    # not an account profile
  hash="$(printf '%s' "$d" | shasum -a 256 | cut -c1-8)"
  security delete-generic-password -s "Claude Code-credentials-$hash" >/dev/null 2>&1 || true
  rm -rf "$d"
  ok "profile removed" "$name"
done

if [[ -f "$DEST" ]]; then
  rm -f "$DEST" "$DEST.bak" "$HOME/.cache/claude-accounts-check"
  ok "tool removed"
else
  skip "tool" "not installed"
fi

if grep -qF 'claude-accounts.zsh' "$ZSHRC" 2>/dev/null; then
  sed -i '' '/# Claude multi-account manager/d;/claude-accounts\.zsh/d' "$ZSHRC"
  ok "shell cleaned"
else
  skip "shell" "already clean"
fi

# VS Code companion extension: clear the wrapper setting FIRST (so the Claude
# panel never points at a deleted file), then remove extension + generated files
VSSET="$HOME/Library/Application Support/Code/User/settings.json"
GSDIR="$HOME/Library/Application Support/Code/User/globalStorage/claude-accounts.claude-switch"
if compgen -G "$HOME/.vscode/extensions/claude-accounts.claude-switch*" > /dev/null 2>&1; then
  if [[ -f "$VSSET" ]] && python3 - "$VSSET" << 'PY' 2>/dev/null
import json, shutil, sys
p = sys.argv[1]
d = json.load(open(p))
v = str(d.get('claudeCode.claudeProcessWrapper') or '')
if 'claude-accounts.claude-switch' in v:
    shutil.copy(p, p + '.bak')
    del d['claudeCode.claudeProcessWrapper']
    open(p, 'w').write(json.dumps(d, indent=2) + '\n')
PY
  then
    :
  else
    skip "vs code setting" "remove claudeCode.claudeProcessWrapper from settings manually"
  fi
  rm -rf "$HOME/.vscode/extensions/"claude-accounts.claude-switch* "$GSDIR"
  ok "vs code extension removed"
else
  skip "vs code extension" "not installed"
fi

nxt "open a new terminal"
echo ""
