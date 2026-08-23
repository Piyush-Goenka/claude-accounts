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
#  Updates NEVER touch profile dirs (~/.claude-*) or Keychain creds.
#  They only replace this one file (previous version kept as .bak).
# ══════════════════════════════════════════════════════════════════

CLAUDE_ACCOUNTS_VERSION="1.1.0"

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

# ── commands ───────────────────────────────────────────────────────

claude-create() {
  if [[ -z "$_CA_REENTRY" ]] && _ca_ensure_latest; then
    _CA_REENTRY=1 claude-create "$@"; return $?
  fi
  local name="${1#claude-}"
  if [[ -z "$name" || "$name" == *[^a-zA-Z0-9_-]* ]]; then
    echo "usage: claude-create <name>   (letters, numbers, - and _ only)"; return 1
  fi
  if (( ${_CA_EXCLUDE[(Ie)$name]} )); then
    echo "'$name' is reserved (~/.claude-$name is not an account profile)"; return 1
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
  if (( ${_CA_EXCLUDE[(Ie)$name]} )); then
    echo "'$name' is reserved (~/.claude-$name is not an account profile); not touching it"; return 1
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
  _CA_EXCLUDE_CSV="${(j:,:)_CA_EXCLUDE}" python3 - "$@" << 'EOF'
import json, glob, os, sys, hashlib, subprocess, datetime
from concurrent.futures import ThreadPoolExecutor

home = os.path.expanduser('~')
exclude = set(filter(None, os.environ.get('_CA_EXCLUDE_CSV', '').split(',')))
as_json = '--json' in sys.argv
now = datetime.datetime.now().astimezone()

def keychain_cred(svc):
    r = subprocess.run(['security', 'find-generic-password', '-s', svc, '-w'],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return None
    try:
        return json.loads(r.stdout.strip()).get('claudeAiOauth')
    except Exception:
        return {}

def fetch_usage(token):
    # same endpoint + headers the claude binary uses for /usage
    r = subprocess.run(['curl', '-fsSL', '--max-time', '6',
                        'https://api.anthropic.com/api/oauth/usage',
                        '-H', 'Authorization: Bearer ' + token,
                        '-H', 'anthropic-beta: oauth-2025-04-20',
                        '-H', 'Content-Type: application/json'],
                       capture_output=True, text=True)
    try:
        return json.loads(r.stdout) if r.returncode == 0 else None
    except Exception:
        return None

def limit(u, key):
    if not u or not u.get(key):
        return None
    p, r = u[key].get('utilization'), u[key].get('resets_at')
    return {'percent': None if p is None else round(p), 'resetsAt': r}

def entry(profile, d, svc):
    email = None
    try:
        cfg_path = home + '/.claude.json' if profile == 'default' else os.path.join(d, '.claude.json')
        cfg = json.load(open(cfg_path))
        email = (cfg.get('oauthAccount') or {}).get('emailAddress')
    except Exception:
        pass
    cred = keychain_cred(svc)
    logged_in = bool(cred and cred.get('accessToken'))
    login_days = None
    rexp = (cred or {}).get('refreshTokenExpiresAt')
    if isinstance(rexp, (int, float)):
        login_days = (rexp / 1000 - now.timestamp()) / 86400
    return {'profile': profile, 'dir': d, 'keychainItem': svc, 'account': email,
            'loggedIn': logged_in,
            'loginExpiresInDays': None if login_days is None else round(login_days, 1),
            '_token': cred.get('accessToken') if logged_in else None}

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
    usages = list(ex.map(lambda r: fetch_usage(r['_token']) if r['_token'] else None, rows))

for r, u in zip(rows, usages):
    del r['_token']
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

def limit_cell(r, l, out_text='-'):
    if not r['loggedIn']:
        return Cell('-') if out_text == '-' else Cell(out_text, c(DIM, out_text))
    if r['usage'] is None:
        return Cell('?', c(YELLOW, '?'))
    if not l or l['percent'] is None:
        return Cell('-')
    p, reset = l['percent'], fmt_reset(l['resetsAt']) if l['resetsAt'] else ''
    plain = f"{'█' * 10} {p:3d}% {reset}".rstrip()
    colored = f"{bar(p)} {c(pcolor(p), f'{p:3d}%')} {c(DIM, reset)}".rstrip()
    return Cell(plain, colored)

def login_cell(r):
    if not r['loggedIn']:
        return Cell('✗ /login', c(RED, '✗ /login'))
    d = r['loginExpiresInDays']
    if d is None:
        return Cell('✓ ok', c(GREEN, '✓ ok'))
    if d <= 0:
        return Cell('✗ expired · /login', c(RED, '✗ expired · /login'))
    if d <= 3:
        return Cell(f'⚠ {d:.0f}d · /login', c(YELLOW, f'⚠ {d:.0f}d · /login'))
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

table = []
for r in rows:
    u = r['usage'] or {}
    row = [Cell(r['profile'], c(CYAN, r['profile'])),
           Cell(r['account'] or '-', c(GRAY, r['account'] or '-')),
           limit_cell(r, u.get('session'), out_text='logged out'),
           limit_cell(r, u.get('week'))]
    row += [limit_cell(r, next((s for s in u.get('scopedWeekly') or [] if s['name'] == n), None))
            for n in scoped_names]
    row += [limit_cell(r, u.get(k)) for k, t in legacy]
    row.append(login_cell(r))
    table.append(row)

header = [Cell(t, c(HDR, t)) for t in cols]
w = [max(len(row[i].plain) for row in [header] + table) for i in range(len(cols))]

def rule(l, m, r):
    return '  ' + c(DGRAY, l + m.join('─' * (wi + 2) for wi in w) + r)

def render(row):
    sep = c(DGRAY, '│')
    inner = sep.join(' ' + cell.colored + ' ' * (w[i] - len(cell.plain)) + ' '
                     for i, cell in enumerate(row))
    return '  ' + sep + inner + sep

print(rule('┌', '┬', '┐'))
print(render(header))
for row in table:
    print(rule('├', '┼', '┤'))
    print(render(row))
print(rule('└', '┴', '┘'))
print(c(DIM, '  usage is live per account · ? = fetch failed (relaunch that profile) · --json for machine output'))
EOF
}
