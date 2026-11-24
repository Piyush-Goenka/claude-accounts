# ══════════════════════════════════════════════════════════════════
#  claude-accounts — multi-account manager for Claude Code (macOS)
#
#  Run multiple Claude accounts side by side. Each account gets an
#  isolated profile dir (own login) while sharing history, settings,
#  and skills with your main ~/.claude via symlinks.
#
#  Commands:
#    claude-accounts                table of all profiles: account, live
#                                   usage (session + weekly %), login expiry
#    claude-accounts create <name>  create a profile  → then: claude-<name> → /login
#    claude-accounts create <name> --token
#                                   create a profile that signs in with a setup
#                                   token from `claude setup-token` (pasted in)
#    claude-accounts token <name>   replace a token profile's setup token
#    claude-accounts delete <name>  remove profile + its Keychain credential
#    claude-accounts update         update this tool to the latest release
#    claude-accounts help           list all commands and profile aliases
#    claude-<name>                  launch that profile (plain claude is the default)
#
#  The old names claude-create, claude-delete, claude-help and
#  claude-accounts-update still work for one release and print a notice.
#
#  Usage numbers are live for every profile, not just the one you last
#  ran: an access token lives ~8h and the claude binary only renews the
#  one it launches, so claude-accounts renews expired tokens itself and
#  writes the rotated pair back to that profile's Keychain item.
#
#  Updates NEVER touch profile dirs (~/.claude-*) or Keychain creds.
#  They only replace this one file (previous version kept as .bak).
# ══════════════════════════════════════════════════════════════════

CLAUDE_ACCOUNTS_VERSION="2.2.0"

# ── configuration ──────────────────────────────────────────────────
_CA_REPO="Piyush-Goenka/claude-accounts"
_CA_FILE="$HOME/.config/zsh/claude-accounts.zsh"
_CA_STAMP="$HOME/.cache/claude-accounts-check"
_CA_CHECK_INTERVAL=86400                     # network version check: once per day
# dirs matching ~/.claude-<name> that are NOT account profiles (e.g. the
# claude-science research beta keeps its own ~/.claude-science dir)
_CA_EXCLUDE=(science)

# macOS only (Keychain + BSD stat); load silently as a no-op elsewhere
[[ "$OSTYPE" == darwin* ]] || return 0

# ── launchers: claude-<name> for every profile dir, rebuilt each shell ──

# A setup-token profile (one with ~/.claude-<name>/.setup-token) gets a
# function that reads its token at launch; every other profile keeps a plain
# alias. The other kind is removed first: zsh expands an alias before it looks
# up a function, so a leftover alias would quietly launch without the token.
_ca_launcher_define() {
  local dir="$HOME/.claude-$1"
  if [[ -e "$dir/.setup-token" ]]; then
    unalias "claude-$1" 2>/dev/null
    functions[claude-$1]="_ca_launch_token ${(q)1} \"\$@\""
  else
    unfunction "claude-$1" 2>/dev/null
    alias "claude-$1"="CLAUDE_CONFIG_DIR=$dir claude"
  fi
}

# Start claude for a token profile. The token is read at this moment and
# exported only inside a subshell, so it reaches that one claude and never
# this shell. eval resolves claude through your own alias or function, the
# same way the alias launchers of browser-login profiles do.
_ca_launch_token() {
  local dir="$HOME/.claude-$1" tok
  { read -r tok < "$dir/.setup-token" } 2>/dev/null
  if [[ -z "$tok" ]]; then
    _ca_err "no token" "claude-$1 has no setup token; run: claude-accounts token $1"
    return 1
  fi
  shift
  ( export CLAUDE_CONFIG_DIR="$dir" CLAUDE_CODE_OAUTH_TOKEN="$tok"; eval 'claude "$@"' )
}

() {
  local d n
  for d in "$HOME"/.claude-*(N/); do
    n="${${d:t}#.claude-}"
    (( ${_CA_EXCLUDE[(Ie)$n]} )) && continue
    _ca_launcher_define "$n"
  done
}

# ── update machinery ───────────────────────────────────────────────

_ca_latest_tag() {
  curl -fsSL --max-time 3 \
    "https://api.github.com/repos/$_CA_REPO/releases/latest" 2>/dev/null \
    | grep -m1 '"tag_name"' | cut -d'"' -f4
}

# true if version $1 is strictly newer than $2 (dotted numeric versions)
_ca_ver_gt() {
  local -a a=(${(s:.:)1}) b=(${(s:.:)2})
  local i
  for i in 1 2 3; do
    (( ${a[i]:-0} > ${b[i]:-0} )) && return 0
    (( ${a[i]:-0} < ${b[i]:-0} )) && return 1
  done
  return 1
}

# Download latest release, verify it, swap it in, re-source.
# Writes ONLY to $_CA_FILE (+ .bak). Never touches profiles or Keychain.
# Update the VS Code companion extension from the same release, when both
# VS Code and the extension are installed. Fail-soft: any problem leaves the
# current extension in place and never blocks the CLI update.
_ca_update_vscode_ext() {
  local extdir="$HOME/.vscode/extensions/claude-accounts.claude-switch"
  [[ -d "$extdir" ]] || return 0
  local tmp
  tmp="$(mktemp -d)" || return 0
  if curl -fsSL --max-time 15 \
      "https://github.com/$_CA_REPO/releases/latest/download/vscode-claude-switch.tar.gz" \
      -o "$tmp/ext.tgz" 2>/dev/null \
     && tar -xzf "$tmp/ext.tgz" -C "$tmp" 2>/dev/null \
     && [[ -f "$tmp/vscode-claude-switch/package.json" ]]; then
    rm -rf "$extdir" && mv "$tmp/vscode-claude-switch" "$extdir" \
      && echo "claude-accounts: vs code extension updated (reload VS Code windows to apply)"
  fi
  rm -rf "$tmp"
  return 0
}

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
  _ca_update_vscode_ext
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
  [[ -z "$latest" ]] && return 1
  _ca_ver_gt "${latest#v}" "$CLAUDE_ACCOUNTS_VERSION" || return 1
  echo "claude-accounts: updating $CLAUDE_ACCOUNTS_VERSION → ${latest#v} ..."
  _ca_install_latest
}

_ca_cmd_update() {
  local latest
  latest="$(_ca_latest_tag)"
  if [[ -z "$latest" ]]; then
    echo "could not reach GitHub (offline?), current version: $CLAUDE_ACCOUNTS_VERSION"; return 1
  fi
  if ! _ca_ver_gt "${latest#v}" "$CLAUDE_ACCOUNTS_VERSION"; then
    echo "already on latest ($CLAUDE_ACCOUNTS_VERSION, published: ${latest#v})"; return 0
  fi
  echo "updating $CLAUDE_ACCOUNTS_VERSION → ${latest#v} ..."
  _ca_install_latest && echo "done (previous version saved as $_CA_FILE.bak)"
}

# ── output helpers (Claude palette; plain text when not a terminal) ──
_ca_c() { if [[ -t 1 ]]; then printf '\e[%sm%s\e[0m' "$1" "$2"; else printf '%s' "$2"; fi }
# _ca_row <color> <icon> <label> [value]
_ca_row() { printf '  %s %-22s %s\n' "$(_ca_c "$1" "$2")" "$3" "$(_ca_c '38;5;180' "${4:-}")" }
_ca_ok()   { _ca_row '38;5;173' '✓' "$1" "${2:-}" }
_ca_skip() { _ca_row '2'        '·' "$1" "${2:-}" }
_ca_err()  { _ca_row '38;5;167' '✗' "$1" "${2:-}" >&2 }
_ca_dim()  { printf '  %s\n' "$(_ca_c 2 "$1")" }
_ca_next() { printf '\n  %s  %s\n' "$(_ca_c '1;38;5;173' 'next')" "$(_ca_c '1' "$1")" }

# ── commands ───────────────────────────────────────────────────────

# A profile folder: its own login, everything else shared with ~/.claude.
_ca_profile_dir() {
  local dir="$HOME/.claude-$1" f
  mkdir -p "$dir"
  for f in projects history.jsonl settings.json CLAUDE.md skills plugins; do
    ln -sfn "$HOME/.claude/$f" "$dir/$f"
  done
}

# Read a setup token from the terminal into the caller's tok, showing one *
# per character; Backspace removes the last one. Echo stays off for the whole
# read, not just inside each single-character read, so a fast paste never
# flashes on screen, and the terminal is restored even on Ctrl-C. Anything
# still arriving right after a line break is the rest of a token that wrapped
# when it was copied: taken now, it cannot land in the label or at the shell
# prompt (which would run it and keep it in history). Spaces and control
# characters are never part of a token and are dropped.
_ca_read_masked() {
  local c more saved
  saved=$(stty -g)
  tok=''
  {
    stty -echo -icanon min 1
    while read -rs -k1 -u0 c; do
      if [[ $c == $'\n' || $c == $'\r' ]]; then
        more=''
        while read -rs -t 0.2 -k1 -u0 c; do
          [[ $c == $'\n' || $c == $'\r' ]] || { more=1; break; }
        done
        [[ -n $more ]] || break
      fi
      if [[ $c == $'\x7f' || $c == $'\b' ]]; then
        [[ -n $tok ]] && { tok=${tok[1,-2]}; print -n -u2 -- $'\b \b'; }
      elif [[ $c != [[:space:][:cntrl:]] ]]; then
        tok+=$c; print -n -u2 -- '*'
      fi
    done
  } always {
    stty "$saved"
  }
  print -u2
}

# Ask for a setup token, then health-check it against the name's account. On
# success the caller's locals hold it: tok (the token) and checked ("session S%
# · week W%"). Nothing is written unless the token is accepted.
_ca_ask_token() {
  if [[ -t 0 ]]; then
    print -n -u2 -- '  token: '
    _ca_read_masked
  else
    read -r tok          # piped in: one line, nothing to show
  fi
  if [[ -z "$tok" ]]; then _ca_err "no token" "nothing was pasted"; return 1; fi
  local out rc; local -a f
  out=$(CA_PING_TOKEN="$tok" _ca_py ping "$1"); rc=$?
  f=(${=out})
  case $rc in
    0) checked="session ${f[2]}% · week ${f[3]}%" ;;
    2) _ca_err "token rejected" "HTTP ${f[1]}; check that the whole token was pasted"; return 1 ;;
    *) if [[ "${f[1]}" == 0 ]]; then _ca_err "health check failed" "no answer from api.anthropic.com"
       else _ca_err "health check failed" "HTTP ${f[1]}"; fi
       return 1 ;;
  esac
}

_ca_cmd_create() {
  local arg name="" token_mode=""
  for arg in "$@"; do
    case "$arg" in
      --token) token_mode=1 ;;
      -*) _ca_err "unknown flag" "$arg   (see: claude-accounts help)"; return 1 ;;
      *)  if [[ -n "$name" ]]; then _ca_err "usage" "claude-accounts create <name> [--token]"; return 1; fi
          name="${arg#claude-}" ;;
    esac
  done
  if [[ -z "$name" || "$name" == *[^a-zA-Z0-9_-]* ]]; then
    _ca_err "usage" "claude-accounts create <name> [--token]   (letters, numbers, - and _ only)"; return 1
  fi
  if (( ${_CA_EXCLUDE[(Ie)$name]} )); then
    _ca_err "reserved name" "$name"; return 1
  fi
  local dir="$HOME/.claude-$name"
  if [[ -e "$dir" ]]; then _ca_err "already exists" "$name"; return 1; fi

  if [[ -n "$token_mode" ]]; then
    # nothing is created until the token has passed its health check, so an
    # abort or a rejected token leaves no folder behind
    local tok checked label
    _ca_next "in another terminal run:  claude setup-token"
    _ca_dim "      sign in as the account you want, then paste the token here"
    print
    _ca_ask_token "$name" || return 1
    read -r "label?  name to show for this account (e.g. its email), Enter to skip: "
    _ca_profile_dir "$name"
    if ! CA_PING_TOKEN="$tok" _ca_py save "$name" ${label:+"$label"}; then
      rm -rf "$dir"; _ca_err "could not save the token" "$name"; return 1
    fi
    _ca_launcher_define "$name"
    print
    _ca_ok "token accepted"   "$checked"
    _ca_ok "profile created"  "$name"
    _ca_ok "synced with main" "projects · history · settings · CLAUDE.md · skills · plugins"
    _ca_ok "launcher ready"   "claude-$name   (no /login needed)"
    return 0
  fi

  _ca_profile_dir "$name"
  _ca_launcher_define "$name"
  _ca_ok "profile created"  "$name"
  _ca_ok "synced with main"   "projects · history · settings · CLAUDE.md · skills · plugins"
  _ca_ok "alias ready"       "claude-$name"
  _ca_next "claude-$name  →  /login"
  _ca_dim "      in the browser pick \"use a different account\" or use an incognito window"
}

_ca_cmd_delete() {
  local name="${1#claude-}"
  if [[ -z "$name" || "$name" == *[^a-zA-Z0-9_-]* ]]; then
    _ca_err "usage" "claude-accounts delete <name>"; return 1
  fi
  if (( ${_CA_EXCLUDE[(Ie)$name]} )); then
    _ca_err "reserved name" "$name"; return 1
  fi
  local dir="$HOME/.claude-$name"
  if [[ ! -d "$dir" ]]; then _ca_err "no such profile" "$name"; return 1; fi
  # this profile's Keychain item: Claude Code-credentials-<sha256(dir)[0:8]>
  local hash
  hash="$(printf '%s' "$dir" | shasum -a 256 | cut -c1-8)"
  if security delete-generic-password -s "Claude Code-credentials-$hash" >/dev/null 2>&1; then
    _ca_ok "keychain credential"  "removed"
  fi
  rm -rf "$dir"          # symlinks, plus a token profile's own token; shared ~/.claude data is safe
  rm -f "$HOME/.cache/claude-accounts/ping-$name.json"
  _ca_ok "profile"      "$name removed"
  unalias "claude-$name" 2>/dev/null
  unfunction "claude-$name" 2>/dev/null
  _ca_ok "launcher"     "claude-$name removed"
}

_ca_cmd_token() {
  local name="${1#claude-}"
  if (( $# != 1 )) || [[ -z "$name" || "$name" == -* || "$name" == *[^a-zA-Z0-9_-]* ]]; then
    _ca_err "usage" "claude-accounts token <name>"; return 1
  fi
  local dir="$HOME/.claude-$name"
  if [[ "$name" == default ]]; then
    _ca_err "not a token profile" "the default account signs in with the browser"; return 1
  fi
  if [[ ! -d "$dir" ]] || (( ${_CA_EXCLUDE[(Ie)$name]} )); then
    _ca_err "no such profile" "$name"; return 1
  fi
  if [[ ! -e "$dir/.setup-token" ]]; then
    _ca_err "not a token profile" "$name signs in with the browser"
    _ca_dim "      for a token instead: claude-accounts delete $name, then claude-accounts create $name --token"
    return 1
  fi
  local tok checked
  _ca_next "in another terminal run:  claude setup-token"
  _ca_dim "      sign in as the account $name uses, then paste the new token here"
  print
  if ! _ca_ask_token "$name"; then _ca_dim "      the old token is unchanged"; return 1; fi
  if ! CA_PING_TOKEN="$tok" _ca_py save "$name"; then
    _ca_err "could not save the token" "the old token is unchanged"; return 1
  fi
  _ca_ok "token replaced" "$checked"
}

_ca_cmd_help() {
  printf '\n  %s %s\n\n' "$(_ca_c '1;38;5;173' 'claude-accounts')" "$(_ca_c 2 "v$CLAUDE_ACCOUNTS_VERSION")"
  printf '  %-38s %s\n' \
    'claude-accounts'                       "$(_ca_c 2 'all profiles: account, live usage, login expiry')" \
    'claude-accounts create <name>'         "$(_ca_c 2 'create a profile, then: claude-<name> → /login')" \
    'claude-accounts create <name> --token' "$(_ca_c 2 'create a profile that signs in with a setup token')" \
    'claude-accounts token <name>'          "$(_ca_c 2 "replace a token profile's setup token")" \
    'claude-accounts delete <name>'         "$(_ca_c 2 'remove a profile + its login')" \
    'claude-accounts update'                "$(_ca_c 2 'update this tool to the latest release')" \
    'claude-accounts help'                  "$(_ca_c 2 'this list (also --help, -h)')"
  printf '\n  %-38s %s\n' 'claude' "$(_ca_c 2 'the default account (~/.claude)')"
  local d n
  for d in "$HOME"/.claude-*(N/); do
    n="${${d:t}#.claude-}"
    (( ${_CA_EXCLUDE[(Ie)$n]} )) && continue
    printf '  %-38s %s\n' "claude-$n" "$(_ca_c 2 "the $n account")"
  done
  printf '\n'
}

# ── old names, kept for one release ───────────────────────────────

_ca_deprecated() {
  printf '  %s\n' "$(_ca_c 2 "$1 is now: $2   (the old name goes away in the next release)")" >&2
}
claude-create()          { _ca_deprecated claude-create 'claude-accounts create'; claude-accounts create "$@" }
claude-delete()          { _ca_deprecated claude-delete 'claude-accounts delete'; claude-accounts delete "$@" }
claude-help()            { _ca_deprecated claude-help 'claude-accounts help'; claude-accounts help }
claude-accounts-update() { _ca_deprecated claude-accounts-update 'claude-accounts update'; claude-accounts update "$@" }

# One entry point for every command. help and update return before the daily
# update check (update is that check), and unknown input is refused before it,
# so a typo never triggers a network call. Everything else passes the check
# exactly once.
claude-accounts() {
  local sub="$1"
  case "$sub" in
    help|--help|-h) _ca_cmd_help; return ;;
    update) shift; _ca_cmd_update "$@"; return ;;
    ''|create|delete|token) ;;
    -*) _ca_err "unknown flag" "$sub   (see: claude-accounts help)"; return 1 ;;
    *)  _ca_err "unknown command" "$sub   (see: claude-accounts help)"; return 1 ;;
  esac
  if [[ -z "$_CA_REENTRY" ]] && _ca_ensure_latest; then
    _CA_REENTRY=1 claude-accounts "$@"; return $?
  fi
  [[ -n "$sub" ]] && shift
  case "$sub" in
    '')     _ca_cmd_table ;;
    create) _ca_cmd_create "$@" ;;
    delete) _ca_cmd_delete "$@" ;;
    token)  _ca_cmd_token "$@" ;;
  esac
}

_ca_cmd_table() { _ca_py table }

# The embedded Python program, one mode per job: table (the accounts table),
# ping and save (setup-token profiles; the token arrives in CA_PING_TOKEN,
# never as an argument).
_ca_py() {
  _CA_EXCLUDE_CSV="${(j:,:)_CA_EXCLUDE}" python3 - "$@" << 'EOF'
import json, glob, os, sys, re, time, hashlib, subprocess, datetime
from concurrent.futures import ThreadPoolExecutor

home = os.path.expanduser('~')
exclude = set(filter(None, os.environ.get('_CA_EXCLUDE_CSV', '').split(',')))
now = datetime.datetime.now().astimezone()
warnings = []

# the OAuth client id and token endpoint the claude binary itself uses
CLIENT_ID = '9d1c250a-e61b-44d9-88ed-5944d1962f5e'
# the token endpoint answers a request carrying curl's default User-Agent with a
# blanket 429 rate_limit_error, before it ever looks at the grant. a CLI-shaped
# User-Agent gets the request evaluated normally.
USER_AGENT = 'claude-cli/2.1.241 (external, cli)'
TOKEN_URL = 'https://platform.claude.com/v1/oauth/token'
USAGE_URL = 'https://api.anthropic.com/api/oauth/usage'

def keychain_read(svc):
    # returns (full credential blob, the item's acct attribute), or (None, None)
    r = subprocess.run(['security', 'find-generic-password', '-s', svc, '-w'],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return None, None
    a = subprocess.run(['security', 'find-generic-password', '-s', svc],
                       capture_output=True, text=True)
    m = re.search(r'"acct"<blob>="([^"]*)"', a.stdout + a.stderr)
    acct = m.group(1) if m else None
    try:
        return json.loads(r.stdout.strip()), acct
    except Exception:
        return {}, acct

def keychain_write(svc, acct, blob):
    # -X takes the secret hex-encoded: it keeps the plaintext out of the process
    # argument list, and unlike prompting for it on stdin it is not capped at
    # 128 bytes (which would silently truncate and destroy the credential)
    hexed = json.dumps(blob).encode().hex()
    r = subprocess.run(['security', 'add-generic-password', '-U', '-s', svc,
                        '-a', acct or os.environ.get('USER', ''), '-X', hexed],
                       capture_output=True, text=True)
    return r.returncode == 0

def refresh_access_token(profile, svc, acct, blob):
    # trade the refresh token for a fresh access token. the server rotates the
    # refresh token, so the new pair MUST be written back or the profile is
    # logged out; the old credential is left untouched on any failure.
    oauth = (blob or {}).get('claudeAiOauth') or {}
    rt = oauth.get('refreshToken')
    if not rt:
        return None
    body = json.dumps({'grant_type': 'refresh_token',
                       'refresh_token': rt, 'client_id': CLIENT_ID})
    r = subprocess.run(['curl', '-sS', '--max-time', '10', '-w', '\n%{http_code}',
                        '-X', 'POST', TOKEN_URL,
                        '-H', 'Content-Type: application/json',
                        '-A', USER_AGENT, '-d', '@-'],
                       input=body, capture_output=True, text=True)
    if r.returncode != 0:
        warnings.append(f'{profile}: could not reach the token endpoint, showing cached usage')
        return None
    payload, _, status = r.stdout.rpartition('\n')
    try:
        d = json.loads(payload)
    except Exception:
        warnings.append(f'{profile}: token endpoint returned HTTP {status.strip()}, showing cached usage')
        return None
    at = d.get('access_token')
    if not at:
        err = d.get('error')
        err = err.get('type') if isinstance(err, dict) else err
        warnings.append(f'{profile}: token refresh failed (HTTP {status.strip()}'
                        + (f', {err}' if err else '') + '), showing cached usage')
        return None
    oauth['accessToken'] = at
    if d.get('refresh_token'):
        oauth['refreshToken'] = d['refresh_token']
    if isinstance(d.get('expires_in'), (int, float)):
        oauth['expiresAt'] = int((time.time() + d['expires_in']) * 1000)
    blob['claudeAiOauth'] = oauth
    # the rotation already happened server side, so a failed write-back means the
    # stored refresh token is now dead: say so loudly rather than fail silently
    if not keychain_write(svc, acct, blob) or \
       ((keychain_read(svc)[0] or {}).get('claudeAiOauth') or {}).get('accessToken') != at:
        warnings.append(f'{profile}: token refreshed but could not be written back to '
                        'the Keychain, this profile needs /login')
    return at

def cfg_path(profile, d):
    return home + '/.claude.json' if profile == 'default' else os.path.join(d, '.claude.json')

def usage_call(token):
    # returns (parsed body or None, http status or 0 for a transport failure)
    r = subprocess.run(['curl', '-sS', '--max-time', '6', '-w', '\n%{http_code}', USAGE_URL,
                        '-H', 'Authorization: Bearer ' + token,
                        '-H', 'anthropic-beta: oauth-2025-04-20',
                        '-H', 'Content-Type: application/json'],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return None, 0
    body, _, code = r.stdout.rpartition('\n')
    try:
        code = int(code.strip())
    except Exception:
        return None, 0
    if code != 200:
        return None, code
    try:
        return json.loads(body), 200
    except Exception:
        return None, code

def fetch_usage(row):
    # live first. an access token lives ~8h and only the claude binary renews it,
    # and only for the profile you actually launch, so profiles you have not run
    # today arrive here expired: refresh them ourselves. the cached snapshot in
    # .claude.json is a last resort and is flagged stale when used.
    oauth = (row['_blob'] or {}).get('claudeAiOauth') or {}
    token = oauth.get('accessToken')
    u = None
    if token:
        exp = oauth.get('expiresAt')
        expired = not isinstance(exp, (int, float)) or exp / 1000 <= time.time() + 60
        if expired:
            token = refresh_access_token(row['profile'], row['_svc'], row['_acct'], row['_blob']) or token
        u, code = usage_call(token)
        # token revoked or rotated behind our back: one refresh, one retry
        if u is None and code in (401, 403) and not expired:
            t2 = refresh_access_token(row['profile'], row['_svc'], row['_acct'], row['_blob'])
            if t2:
                u, code = usage_call(t2)
    if u is not None:
        return {'u': u, 'stale': False, 'fetchedAtMs': int(time.time() * 1000)}
    try:
        cached = json.load(open(cfg_path(row['profile'], row['dir']))).get('cachedUsageUtilization') or {}
    except Exception:
        cached = {}
    if cached.get('utilization'):
        return {'u': cached['utilization'], 'stale': True, 'fetchedAtMs': cached.get('fetchedAtMs')}
    return None

def limit(u, key):
    if not u or not u.get(key):
        return None
    p, r = u[key].get('utilization'), u[key].get('resets_at')
    return {'percent': None if p is None else round(p), 'resetsAt': r}

def entry(profile, d, svc):
    if profile != 'default' and os.path.exists(os.path.join(d, '.setup-token')):
        # a setup-token profile: no Keychain read, no refresh, no usage
        # endpoint; its numbers come from the health check (token_usage)
        token = read_token(profile)
        return {'profile': profile, 'dir': d, 'account': read_label(profile) or None,
                'auth': 'token', 'tokenState': 'ok' if token else 'missing',
                'loggedIn': bool(token), 'loginExpiresInDays': None, '_token': token}
    email = None
    try:
        cfg = json.load(open(cfg_path(profile, d)))
        email = (cfg.get('oauthAccount') or {}).get('emailAddress')
    except Exception:
        pass
    blob, acct = keychain_read(svc)
    cred = (blob or {}).get('claudeAiOauth') or {}
    logged_in = bool(cred.get('accessToken'))
    login_days = None
    rexp = cred.get('refreshTokenExpiresAt')
    if isinstance(rexp, (int, float)):
        login_days = (rexp / 1000 - now.timestamp()) / 86400
    return {'profile': profile, 'dir': d, 'account': email, 'auth': 'login',
            'loggedIn': logged_in,
            'loginExpiresInDays': None if login_days is None else round(login_days, 1),
            '_blob': blob, '_acct': acct, '_svc': svc}

# ── setup-token profiles ───────────────────────────────────────
# A setup token cannot read the usage endpoint (it lacks the user:profile
# scope), but every reply to a message carries the account's limits in its
# headers. The health check is the smallest message there is.
PING_URL = 'https://api.anthropic.com/v1/messages'
PING_MODEL = 'claude-haiku-4-5-20251001'
PING_BODY = json.dumps({'model': PING_MODEL, 'max_tokens': 1,
                        'messages': [{'role': 'user', 'content': '.'}]}, separators=(',', ':'))
PING_TTL = 300          # at most one health check per profile per 5 minutes
CACHE_DIR = os.path.join(home, '.cache', 'claude-accounts')
WINDOWS = {'five_hour': '5h', 'seven_day': '7d'}

def token_file(name):
    return os.path.join(home, f'.claude-{name}', '.setup-token')

def read_token(name):
    try:
        with open(token_file(name)) as f:
            return f.read().strip()
    except Exception:
        return ''

def read_label(name):
    try:
        path = os.path.join(home, f'.claude-{name}', '.claude-accounts.json')
        return str(json.load(open(path)).get('label') or '')
    except Exception:
        return ''

def ping(token):
    # one 1-token message. The bearer header reaches curl on stdin, so the
    # token never appears in a process argument list. Returns (status, windows);
    # status is 0 when nothing answered.
    r = subprocess.run(['curl', '-sS', '--max-time', '10', '-o', '/dev/null', '-D', '-',
                        '-H', '@-',
                        '-H', 'anthropic-version: 2023-06-01',
                        '-H', 'anthropic-beta: oauth-2025-04-20',
                        '-H', 'Content-Type: application/json',
                        '-d', PING_BODY, PING_URL],
                       input=f'Authorization: Bearer {token}\n', capture_output=True, text=True)
    status, hdrs = 0, {}
    for line in r.stdout.replace('\r', '').split('\n'):
        m = re.match(r'HTTP/\S+\s+(\d{3})', line)
        if m:                      # a later header block (after a redirect) wins
            status, hdrs = int(m.group(1)), {}
        elif ':' in line:
            k, _, v = line.partition(':')
            hdrs[k.strip().lower()] = v.strip()
    windows = {}
    for key, short in WINDOWS.items():
        try:
            util = float(hdrs[f'anthropic-ratelimit-unified-{short}-utilization'])
            reset = int(float(hdrs[f'anthropic-ratelimit-unified-{short}-reset']))
        except (KeyError, ValueError):
            continue
        windows[key] = {'utilization': round(util * 100, 2),
                        'resets_at': datetime.datetime.fromtimestamp(reset, datetime.timezone.utc).isoformat()}
    return status, windows

def cache_path(name):
    return os.path.join(CACHE_DIR, f'ping-{name}.json')

def write_ping_cache(name, http, windows):
    # the cache only saves a message: a write that fails must never cost the
    # table or the health check its answer
    tmp = f'{cache_path(name)}.{os.getpid()}.tmp'
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        with open(tmp, 'w') as f:
            json.dump({'ts': int(time.time()), 'http': http, **windows}, f)
        os.replace(tmp, cache_path(name))
    except OSError:
        try:
            os.remove(tmp)
        except OSError:
            pass

def read_ping_cache(name):
    try:
        c = json.load(open(cache_path(name)))
    except Exception:
        return None
    return c if isinstance(c, dict) and isinstance(c.get('ts'), (int, float)) else None

def cache_is_fresh(c):
    return c is not None and time.time() - c['ts'] < PING_TTL

def write_private(path, text):
    # a sibling created with mode 600, renamed over the target: the file is
    # never readable by others and never half written
    tmp = f'{path}.{os.getpid()}.tmp'
    try:
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w') as f:
            f.write(text)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)

mode = sys.argv[1] if len(sys.argv) > 1 else 'table'

if mode == 'ping':
    # prints "<http> <session %> <week %>", '-' for a missing window.
    # exit 0 accepted (200, or 429 at the limit), 2 rejected, 3 anything else;
    # only an accepted token's numbers are cached
    status, windows = ping(os.environ.get('CA_PING_TOKEN', ''))
    pct = lambda k: str(round(windows[k]['utilization'])) if k in windows else '-'
    print(status, pct('five_hour'), pct('seven_day'))
    if status in (200, 429):
        write_ping_cache(sys.argv[2], status, windows)
        sys.exit(0)
    sys.exit(2 if status in (401, 403) else 3)

if mode == 'save':
    name = sys.argv[2]
    pdir = os.path.join(home, f'.claude-{name}')
    token = os.environ.get('CA_PING_TOKEN', '').strip()
    if not token or not os.path.isdir(pdir):
        sys.exit(1)
    try:
        write_private(token_file(name), token + '\n')
        if len(sys.argv) > 3:
            write_private(os.path.join(pdir, '.claude-accounts.json'), json.dumps({'label': sys.argv[3]}))
    except Exception:
        sys.exit(1)
    sys.exit(0)

rows = [entry('default', home + '/.claude', 'Claude Code-credentials')]
for d in sorted(glob.glob(home + '/.claude-*')):
    if not os.path.isdir(d):
        continue
    name = os.path.basename(d)[len('.claude-'):]
    if name in exclude:
        continue
    h = hashlib.sha256(d.encode()).hexdigest()[:8]
    rows.append(entry(name, d, f'Claude Code-credentials-{h}'))

def token_usage(row):
    # the cached health check while it is fresh, otherwise a new one. Every
    # answer is cached, so a rejected or failing token is not pinged again
    # within PING_TTL either; no answer at all is not cached.
    c = read_ping_cache(row['profile'])
    if not cache_is_fresh(c):
        status, windows = ping(row['_token'])
        c = {'http': status, **windows}
        if status:
            write_ping_cache(row['profile'], status, windows)
    return c

def usage_for(r):
    if not r['loggedIn']:
        return None
    return token_usage(r) if r['auth'] == 'token' else fetch_usage(r)

with ThreadPoolExecutor(max_workers=8) as ex:
    usages = list(ex.map(usage_for, rows))

for r, res in zip(rows, usages):
    for k in [k for k in r if k.startswith('_')]:
        del r[k]
    if r['auth'] == 'token' and res is not None:
        http = res.get('http')
        if http in (401, 403):
            r['tokenState'], r['loggedIn'], res = 'rejected', False, None
        elif http in (200, 429):          # 429: the account is at its limit
            res = {'u': {k: res[k] for k in WINDOWS if k in res}}
        else:
            warnings.append(f"{r['profile']}: health check got no answer, usage not shown" if not http else
                            f"{r['profile']}: health check returned HTTP {http}, usage not shown")
            res = None
    u = (res or {}).get('u')
    scoped = []
    for l in (u or {}).get('limits') or []:
        name = (((l.get('scope') or {}).get('model') or {}).get('display_name'))
        if l.get('kind') == 'weekly_scoped' and name:
            scoped.append({'name': name,
                           'percent': None if l.get('percent') is None else round(l['percent']),
                           'resetsAt': l.get('resets_at')})
    r['usage'] = None if u is None else {
        'session': limit(u, 'five_hour'),
        'week': limit(u, 'seven_day'),
        'weekOpus': limit(u, 'seven_day_opus'),
        'weekSonnet': limit(u, 'seven_day_sonnet'),
        'scopedWeekly': scoped}

# ── design 1: gradient bar table ───────────────────────────────
use_color = sys.stdout.isatty() and 'NO_COLOR' not in os.environ
# Claude brand palette (256-color approximations of the terracotta family):
# 173 = Claude orange, 179 = warm gold, 167 = warm red, 180 = warm tan
GREEN, YELLOW, RED = '38;5;173', '38;5;179', '38;5;167'
CYAN, GRAY, DGRAY, DIM, HDR = '1;38;5;173', '38;5;180', '38;5;238', '2', '1;38;5;137'

def c(code, s):
    return f'\033[{code}m{s}\033[0m' if use_color else s

def pcolor(p):
    return GREEN if p < 50 else YELLOW if p < 80 else RED

def bar(p, w=10):
    n = min(w, round(p * w / 100))
    return c(pcolor(p), '█' * n) + c(DGRAY, '░' * (w - n))

def fmt_reset(iso):
    try:
        t = datetime.datetime.fromisoformat(iso).astimezone()
    except Exception:
        return ''
    return t.strftime('%H:%M') if t.date() == now.date() else t.strftime('%a %H:%M')

class Cell:
    def __init__(self, plain, colored=None):
        self.plain, self.colored = plain, colored if colored is not None else plain

def limit_cell(r, l, out_text='-', bar_w=10, show_reset=True):
    if not r['loggedIn']:
        return Cell('-') if out_text == '-' else Cell(out_text, c(DIM, out_text))
    if r['usage'] is None:
        return Cell('?', c(YELLOW, '?'))
    if not l or l['percent'] is None:
        return Cell('-')
    p = l['percent']
    reset = fmt_reset(l['resetsAt']) if l['resetsAt'] and show_reset else ''
    pre_p, pre_c = ('█' * bar_w + ' ', bar(p, bar_w) + ' ') if bar_w else ('', '')
    suf_p, suf_c = (f' {reset}', f' {c(DIM, reset)}') if reset else ('', '')
    return Cell(f"{pre_p}{p:3d}%{suf_p}",
                f"{pre_c}{c(pcolor(p), f'{p:3d}%')}{suf_c}")

def login_cell(r, tight=False):
    if r['auth'] == 'token':
        if r['tokenState'] == 'ok':
            return Cell('✓ token', c(GREEN, '✓ token'))
        fix = f"claude-accounts token {r['profile']}"
        if r['tokenState'] == 'rejected':
            t = '✗ rejected' if tight else f'✗ token rejected · {fix}'
        else:
            t = '✗ no token' if tight else f'✗ no token · {fix}'
        return Cell(t, c(RED, t))
    if not r['loggedIn']:
        t = '✗ out' if tight else '✗ /login'
        return Cell(t, c(RED, t))
    d = r['loginExpiresInDays']
    if d is None:
        return Cell('✓ ok', c(GREEN, '✓ ok'))
    if d <= 0:
        t = '✗ exp' if tight else '✗ expired · /login'
        return Cell(t, c(RED, t))
    if d <= 3:
        t = f'⚠ {d:.0f}d' if tight else f'⚠ {d:.0f}d · /login'
        return Cell(t, c(YELLOW, t))
    return Cell(f'✓ {d:.0f}d', c(GREEN, f'✓ {d:.0f}d'))

# per-model weekly columns: scoped limits (Fable, Opus, ...) from the limits
# array, plus the legacy seven_day_opus/sonnet fields when not already covered
scoped_names = []
for r in rows:
    for s in (r['usage'] or {}).get('scopedWeekly') or []:
        if s['name'] not in scoped_names:
            scoped_names.append(s['name'])
legacy = [(k, t) for k, t in [('weekOpus', 'Opus'), ('weekSonnet', 'Sonnet')]
          if t not in scoped_names and any((r['usage'] or {}).get(k) for r in rows)]

cols = ['PROFILE', 'ACCOUNT', 'SESSION', 'WEEK']
cols += [f'WEEK {n.upper()}' for n in scoped_names]
cols += [f'WEEK {t.upper()}' for k, t in legacy]
cols.append('LOGIN')

def trunc(s, n):
    return s if len(s) <= n else s[:max(1, n - 1)] + '…'

def build(bar_w, show_reset, acc_max=None, tight=False):
    table = []
    for r in rows:
        u = r['usage'] or {}
        acc = r['account'] or '-'
        if acc_max:
            acc = trunc(acc, acc_max)
        out_text = 'out' if tight else 'logged out'
        row = [Cell(r['profile'], c(CYAN, r['profile'])),
               Cell(acc, c(GRAY, acc)),
               limit_cell(r, u.get('session'), out_text, bar_w, show_reset),
               limit_cell(r, u.get('week'), '-', bar_w, show_reset)]
        row += [limit_cell(r, next((s for s in u.get('scopedWeekly') or [] if s['name'] == n), None),
                           '-', bar_w, show_reset) for n in scoped_names]
        row += [limit_cell(r, u.get(k), '-', bar_w, show_reset) for k, t in legacy]
        row.append(login_cell(r, tight))
        table.append(row)
    header = [Cell(t, c(HDR, t)) for t in cols]
    w = [max(len(row[i].plain) for row in [header] + table) for i in range(len(cols))]
    return header, table, w

# same table, smaller: shrink bars, then drop reset times, then truncate the
# account column, until the grid fits the terminal width
import shutil
term_w = shutil.get_terminal_size().columns if sys.stdout.isatty() else 10**9
pad = 1
total_w = lambda w: 2 + sum(w) + (2 * pad + 1) * len(w) + 1

configs = [(10, True), (8, True), (6, True), (6, False), (4, False), (0, False)]
for bar_w, show_reset in configs:
    header, table, w = build(bar_w, show_reset)
    if total_w(w) <= term_w:
        break
else:
    # nothing fits with full emails: truncate the account column, keeping it
    # as wide as possible (>= 16 chars if we can, >= 8 as a last resort)
    done = False
    for min_acc in (16, 8):
        for bar_w, show_reset in configs:
            header, table, w = build(bar_w, show_reset)
            slack = w[1] - (total_w(w) - term_w)
            if slack >= min_acc:
                header, table, w = build(bar_w, show_reset, acc_max=slack)
                done = True
                break
        if done:
            break
    if not done:
        # ultra-narrow: shorten login labels, then drop cell padding
        for pad in (1, 0):
            header, table, w = build(0, False, acc_max=8, tight=True)
            if total_w(w) <= term_w:
                break

def rule(l, m, r):
    return '  ' + c(DGRAY, l + m.join('─' * (wi + 2 * pad) for wi in w) + r)

def render(row):
    sep = c(DGRAY, '│')
    inner = sep.join(' ' * pad + cell.colored + ' ' * (w[i] - len(cell.plain)) + ' ' * pad
                     for i, cell in enumerate(row))
    return '  ' + sep + inner + sep

print(rule('┌', '┬', '┐'))
print(render(header))
for row in table:
    print(rule('├', '┼', '┤'))
    print(render(row))
print(rule('└', '┴', '┘'))

for msg in warnings:
    print('  ' + c(RED, '✗ ' + msg), file=sys.stderr)
EOF
}
