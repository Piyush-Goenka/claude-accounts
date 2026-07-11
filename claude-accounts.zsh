# ══════════════════════════════════════════════════════════════════
#  claude-accounts — multi-account manager for Claude Code (macOS)
#
#  Run multiple Claude accounts side by side. Each account gets an
#  isolated profile dir (own login) while sharing history, settings,
#  and skills with your main ~/.claude via symlinks.
#
#  Commands:
#    claude-create <name>      create a profile  → then: claude-<name> → /login
#    claude-delete <name>      remove profile + its Keychain credential
#    claude-accounts           JSON registry of all profiles (live-generated)
#    claude-accounts-update    update this tool to the latest release
#
#  Updates NEVER touch profile dirs (~/.claude-*) or Keychain creds.
#  They only replace this one file (previous version kept as .bak).
# ══════════════════════════════════════════════════════════════════

CLAUDE_ACCOUNTS_VERSION="1.0.0"

# ── configuration ──────────────────────────────────────────────────
_CA_REPO="Piyush-Goenka/claude-accounts"
_CA_FILE="$HOME/.config/zsh/claude-accounts.zsh"
_CA_STAMP="$HOME/.cache/claude-accounts-check"
_CA_CHECK_INTERVAL=86400                     # network version check: once per day

# macOS only (Keychain + BSD stat); load silently as a no-op elsewhere
[[ "$OSTYPE" == darwin* ]] || return 0

# ── dynamic aliases: one per existing profile dir, rebuilt each shell ──
() {
  local d
  for d in "$HOME"/.claude-*(N/); do
    alias "claude-${${d:t}#.claude-}"="CLAUDE_CONFIG_DIR=$d claude"
  done
}

# ── update machinery ───────────────────────────────────────────────

_ca_latest_tag() {
  curl -fsSL --max-time 3 \
    "https://api.github.com/repos/$_CA_REPO/releases/latest" 2>/dev/null \
    | grep -m1 '"tag_name"' | cut -d'"' -f4
}

# Download latest release, verify it, swap it in, re-source.
# Writes ONLY to $_CA_FILE (+ .bak). Never touches profiles or Keychain.
_ca_install_latest() {
  local tmp
  tmp="$(mktemp)" || return 1
  if ! curl -fsSL --max-time 15 \
      "https://github.com/$_CA_REPO/releases/latest/download/claude-accounts.zsh" \
      -o "$tmp"; then
    rm -f "$tmp"; echo "claude-accounts: download failed, keeping current version"; return 1
  fi
  if ! zsh -n "$tmp" 2>/dev/null; then
    rm -f "$tmp"; echo "claude-accounts: downloaded file failed syntax check, keeping current version"; return 1
  fi
  [[ -f "$_CA_FILE" ]] && cp "$_CA_FILE" "$_CA_FILE.bak"
  mv "$tmp" "$_CA_FILE"
  source "$_CA_FILE"
  return 0
}

# Guard called by every public command: at most once a day, check for a
# newer release and install it BEFORE the command runs. Offline or any
# failure → return 1 and the command proceeds on the current version.
_ca_ensure_latest() {
  mkdir -p "${_CA_STAMP:h}"
  if [[ -f "$_CA_STAMP" ]] && \
     (( $(date +%s) - $(stat -f %m "$_CA_STAMP") < _CA_CHECK_INTERVAL )); then
    return 1
  fi
  touch "$_CA_STAMP"
  local latest
  latest="$(_ca_latest_tag)"
  [[ -z "$latest" || "v$CLAUDE_ACCOUNTS_VERSION" == "$latest" ]] && return 1
  echo "claude-accounts: updating $CLAUDE_ACCOUNTS_VERSION → ${latest#v} ..."
  _ca_install_latest
}

claude-accounts-update() {
  local latest
  latest="$(_ca_latest_tag)"
  if [[ -z "$latest" ]]; then
    echo "could not reach GitHub (offline?), current version: $CLAUDE_ACCOUNTS_VERSION"; return 1
  fi
  if [[ "v$CLAUDE_ACCOUNTS_VERSION" == "$latest" ]]; then
    echo "already on latest ($CLAUDE_ACCOUNTS_VERSION)"; return 0
  fi
  echo "updating $CLAUDE_ACCOUNTS_VERSION → ${latest#v} ..."
  _ca_install_latest && echo "done (previous version saved as $_CA_FILE.bak)"
}

# ── commands ───────────────────────────────────────────────────────

claude-create() {
  if [[ -z "$_CA_REENTRY" ]] && _ca_ensure_latest; then
    _CA_REENTRY=1 claude-create "$@"; return $?
  fi
  local name="${1#claude-}"
  if [[ -z "$name" || "$name" == *[^a-zA-Z0-9_-]* ]]; then
    echo "usage: claude-create <name>   (letters, numbers, - and _ only)"; return 1
  fi
  local dir="$HOME/.claude-$name"
  if [[ -e "$dir" ]]; then echo "profile $dir already exists"; return 1; fi
  mkdir -p "$dir"
  local f
  for f in projects history.jsonl settings.json CLAUDE.md skills plugins; do
    ln -sfn "$HOME/.claude/$f" "$dir/$f"
  done
  alias "claude-$name"="CLAUDE_CONFIG_DIR=$dir claude"
  echo "profile ready: run  claude-$name  then /login"
  echo "(in the browser pick 'use a different account' or use an incognito window)"
}

claude-delete() {
  if [[ -z "$_CA_REENTRY" ]] && _ca_ensure_latest; then
    _CA_REENTRY=1 claude-delete "$@"; return $?
  fi
  local name="${1#claude-}"
  if [[ -z "$name" || "$name" == *[^a-zA-Z0-9_-]* ]]; then
    echo "usage: claude-delete <name>"; return 1
  fi
  local dir="$HOME/.claude-$name"
  if [[ ! -d "$dir" ]]; then echo "no profile at $dir"; return 1; fi
  # this profile's Keychain item: Claude Code-credentials-<sha256(dir)[0:8]>
  local hash
  hash="$(printf '%s' "$dir" | shasum -a 256 | cut -c1-8)"
  if security delete-generic-password -s "Claude Code-credentials-$hash" >/dev/null 2>&1; then
    echo "keychain credential removed"
  else
    echo "no keychain credential found (never logged in, or already clean)"
  fi
  rm -rf "$dir"          # dir holds only symlinks; shared ~/.claude data is safe
  unalias "claude-$name" 2>/dev/null
  echo "removed $dir and alias claude-$name"
}

claude-accounts() {
  if [[ -z "$_CA_REENTRY" ]] && _ca_ensure_latest; then
    _CA_REENTRY=1 claude-accounts "$@"; return $?
  fi
  python3 - << 'EOF'
import json, glob, os, hashlib, subprocess
home = os.path.expanduser('~')
out = []

def entry(profile, d, svc):
    email = None
    try:
        cfg_path = home + '/.claude.json' if profile == 'default' else os.path.join(d, '.claude.json')
        cfg = json.load(open(cfg_path))
        email = (cfg.get('oauthAccount') or {}).get('emailAddress')
    except Exception:
        pass
    logged_in = subprocess.run(['security', 'find-generic-password', '-s', svc],
                               capture_output=True).returncode == 0
    return {'profile': profile, 'dir': d, 'keychainItem': svc,
            'account': email, 'loggedIn': logged_in}

out.append(entry('default', home + '/.claude', 'Claude Code-credentials'))
for d in sorted(glob.glob(home + '/.claude-*')):
    if not os.path.isdir(d):
        continue
    name = os.path.basename(d)[len('.claude-'):]
    h = hashlib.sha256(d.encode()).hexdigest()[:8]
    out.append(entry(name, d, f'Claude Code-credentials-{h}'))
print(json.dumps(out, indent=2))
EOF
}
