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
#    claude-accounts           table of all profiles: account, live usage
#                              (session + weekly %), login expiry; --json for JSON
#    claude-accounts-update    update this tool to the latest release
#
#  Usage numbers are live for every profile, not just the one you last
#  ran: an access token lives ~8h and the claude binary only renews the
#  one it launches, so claude-accounts renews expired tokens itself and
#  writes the rotated pair back to that profile's Keychain item.
#
#  Updates NEVER touch profile dirs (~/.claude-*) or Keychain creds.
#  They only replace this one file (previous version kept as .bak).
# ══════════════════════════════════════════════════════════════════

CLAUDE_ACCOUNTS_VERSION="2.0.2"

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

# ── dynamic aliases: one per existing profile dir, rebuilt each shell ──
() {
  local d n
  for d in "$HOME"/.claude-*(N/); do
    n="${${d:t}#.claude-}"
    (( ${_CA_EXCLUDE[(Ie)$n]} )) && continue
    alias "claude-$n"="CLAUDE_CONFIG_DIR=$d claude"
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
  [[ -z "$latest" ]] && return 1
  _ca_ver_gt "${latest#v}" "$CLAUDE_ACCOUNTS_VERSION" || return 1
  echo "claude-accounts: updating $CLAUDE_ACCOUNTS_VERSION → ${latest#v} ..."
  _ca_install_latest
}

claude-accounts-update() {
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

claude-create() {
  if [[ -z "$_CA_REENTRY" ]] && _ca_ensure_latest; then
    _CA_REENTRY=1 claude-create "$@"; return $?
  fi
  local name="${1#claude-}"
  if [[ -z "$name" || "$name" == *[^a-zA-Z0-9_-]* ]]; then
    _ca_err "usage" "claude-create <name>   (letters, numbers, - and _ only)"; return 1
  fi
  if (( ${_CA_EXCLUDE[(Ie)$name]} )); then
    _ca_err "reserved name" "$name"; return 1
  fi
  local dir="$HOME/.claude-$name"
  if [[ -e "$dir" ]]; then _ca_err "already exists" "$name"; return 1; fi
  mkdir -p "$dir"
  local f
  for f in projects history.jsonl settings.json CLAUDE.md skills plugins; do
    ln -sfn "$HOME/.claude/$f" "$dir/$f"
  done
  alias "claude-$name"="CLAUDE_CONFIG_DIR=$dir claude"
  _ca_ok "profile created"  "$name"
  _ca_ok "synced with main"   "projects · history · settings · CLAUDE.md · skills · plugins"
  _ca_ok "alias ready"       "claude-$name"
  _ca_next "claude-$name  →  /login"
  _ca_dim "      in the browser pick \"use a different account\" or use an incognito window"
}

claude-delete() {
  if [[ -z "$_CA_REENTRY" ]] && _ca_ensure_latest; then
    _CA_REENTRY=1 claude-delete "$@"; return $?
  fi
  local name="${1#claude-}"
  if [[ -z "$name" || "$name" == *[^a-zA-Z0-9_-]* ]]; then
    _ca_err "usage" "claude-delete <name>"; return 1
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
  rm -rf "$dir"          # dir holds only symlinks; shared ~/.claude data is safe
  _ca_ok "profile"      "$name removed"
  unalias "claude-$name" 2>/dev/null
  _ca_ok "alias"        "claude-$name removed"
}

claude-accounts() {
  if [[ -z "$_CA_REENTRY" ]] && _ca_ensure_latest; then
    _CA_REENTRY=1 claude-accounts "$@"; return $?
  fi
  _CA_EXCLUDE_CSV="${(j:,:)_CA_EXCLUDE}" python3 - "$@" << 'EOF'
import json, glob, os, sys, re, time, hashlib, subprocess, datetime
from concurrent.futures import ThreadPoolExecutor

home = os.path.expanduser('~')
exclude = set(filter(None, os.environ.get('_CA_EXCLUDE_CSV', '').split(',')))
as_json = '--json' in sys.argv
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
    return {'profile': profile, 'dir': d, 'keychainItem': svc, 'account': email,
            'loggedIn': logged_in,
            'loginExpiresInDays': None if login_days is None else round(login_days, 1),
            '_blob': blob, '_acct': acct, '_svc': svc}

rows = [entry('default', home + '/.claude', 'Claude Code-credentials')]
for d in sorted(glob.glob(home + '/.claude-*')):
    if not os.path.isdir(d):
        continue
    name = os.path.basename(d)[len('.claude-'):]
    if name in exclude:
        continue
    h = hashlib.sha256(d.encode()).hexdigest()[:8]
    rows.append(entry(name, d, f'Claude Code-credentials-{h}'))

with ThreadPoolExecutor(max_workers=8) as ex:
    usages = list(ex.map(lambda r: fetch_usage(r) if r['loggedIn'] else None, rows))

for r, res in zip(rows, usages):
    for k in [k for k in r if k.startswith('_')]:
        del r[k]
    u = (res or {}).get('u')
    r['stale'] = bool(res and res['stale'])
    r['usageFetchedAtMs'] = (res or {}).get('fetchedAtMs')
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

if as_json:
    print(json.dumps(rows, indent=2))
    for msg in warnings:
        print('  ✗ ' + msg, file=sys.stderr)
    sys.exit(0)

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
