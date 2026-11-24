# Helpers for the claude-accounts test suite, sourced by tests/run.zsh.
# Each test runs in its own subshell inside a sandbox: a temporary HOME and a
# PATH whose security, curl and claude are the doubles in tests/bin. Nothing
# here may touch the real HOME, the real Keychain or the network.

CA_FAILS=0

_ca_fail() { CA_FAILS=$(( CA_FAILS + 1 )); print -r -- "    assertion failed: $*" >&2 }

assert_eq()      { [[ "$1" == "$2" ]] || _ca_fail "expected [$1], got [$2]" }
assert_has()     { [[ "$1" == *"$2"* ]] || _ca_fail "missing [$2] in:"$'\n'"$1" }
assert_lacks()   { [[ "$1" != *"$2"* ]] || _ca_fail "unexpected [$2] in:"$'\n'"$1" }
assert_exists()  { [[ -e "$1" || -L "$1" ]] || _ca_fail "missing path: $1" }
assert_missing() { [[ ! -e "$1" && ! -L "$1" ]] || _ca_fail "path should not exist: $1" }
assert_mode()    { local m; m=$(stat -f %Lp "$2" 2>/dev/null); [[ "$m" == "$1" ]] || _ca_fail "mode of $2 is [$m], expected [$1]" }

# Fresh sandbox in $CA_T (created by the runner). Exits 99, which aborts the
# whole run, if the security double is not the one on PATH.
ca_sandbox() {
  # a token or profile exported in the caller's shell must not leak into tests,
  # nor into failure output
  unset CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR
  export HOME="$CA_T/home"
  mkdir -p "$HOME/.claude" "$HOME/.cache"
  print -r -- '{}' > "$HOME/.claude.json"
  touch "$HOME/.cache/claude-accounts-check"
  export PATH="$CA_REPO/tests/bin:$PATH"
  if [[ "$(command -v security)" != "$CA_REPO/tests/bin/security" ]]; then
    print -r -- "ABORT: security is $(command -v security), not the test double" >&2
    exit 99
  fi
}

ca_load() { source "$CA_REPO/claude-accounts.zsh" }

ca_hash() { printf '%s' "$1" | shasum -a 256 | cut -c1-8 }

# A browser-login profile: email in .claude.json and a Keychain credential
# whose access token is valid for 8 hours and whose login has 28.4 days left.
ca_login_profile() {
  local dir="$HOME/.claude-$1"
  mkdir -p "$dir"
  python3 - "$dir" "$2" "$1" "$(ca_hash "$dir")" "${USER:-test}" <<'PY'
import json, os, sys, time
d, email, name, h, user = sys.argv[1:6]
json.dump({'oauthAccount': {'emailAddress': email}}, open(os.path.join(d, '.claude.json'), 'w'))
now_ms = int(time.time() * 1000)
cred = {'claudeAiOauth': {'accessToken': 'at-' + name, 'refreshToken': 'rt-' + name,
                          'expiresAt': now_ms + 8 * 3600 * 1000,
                          'refreshTokenExpiresAt': now_ms + int(28.4 * 86400 * 1000),
                          'scopes': ['user:inference', 'user:profile'], 'subscriptionType': 'max'}}
store = os.path.join(os.environ['HOME'], '.fake-keychain')
os.makedirs(store, exist_ok=True)
json.dump({'acct': user, 'password': json.dumps(cred)},
          open(os.path.join(store, 'Claude Code-credentials-' + h), 'w'))
PY
}

# A setup-token profile: .setup-token (mode 600, empty when the token is '')
# and, when a third argument is given, the label file.
ca_token_profile() {
  local dir="$HOME/.claude-$1"
  mkdir -p "$dir"
  ( umask 077
    if [[ -n "$2" ]]; then print -r -- "$2" > "$dir/.setup-token"; else : > "$dir/.setup-token"; fi )
  if (( $# >= 3 )); then
    python3 -c 'import json, sys; json.dump({"label": sys.argv[2]}, open(sys.argv[1], "w"))' \
      "$dir/.claude-accounts.json" "$3"
    chmod 600 "$dir/.claude-accounts.json"
  fi
}

ca_calls() { [[ -f "$HOME/.calls/$1.log" ]] && print -r -- "$(<$HOME/.calls/$1.log)"; return 0 }
