# Token profiles in the table: limits from the health check, the ping floor,
# and the LOGIN states.

_row()  { print -r -- "$1" | grep " $2 " }
_cell() { local -a f; f=("${(@s:│:)1}"); print -r -- ${=f[$(( $2 + 1 ))]} }   # column 1 = PROFILE; ${=} trims by word-splitting

test_table_token_row() {
  ca_token_profile mohan tok-secret 'work max'; ca_load
  local row; row=$(_row "$(claude-accounts 2>&1)" mohan)
  assert_has "$row" 'work max'; assert_has "$row" '  5%'; assert_has "$row" ' 20%'; assert_has "$row" '✓ token'
  assert_lacks "$(ca_calls security)" "$(ca_hash $HOME/.claude-mohan)"
}

test_table_pings_at_most_every_five_minutes() {
  ca_token_profile mohan tok; ca_load
  claude-accounts >/dev/null 2>&1; claude-accounts >/dev/null 2>&1
  assert_eq 1 "$(ca_calls curl | grep -c v1/messages)"
  python3 -c 'import json,sys,time; p=sys.argv[1]; d=json.load(open(p)); d["ts"]=time.time()-301; json.dump(d,open(p,"w"))' \
    "$HOME/.cache/claude-accounts/ping-mohan.json"
  claude-accounts >/dev/null 2>&1
  assert_eq 2 "$(ca_calls curl | grep -c v1/messages)"
}

test_table_token_rejected() {
  ca_token_profile mohan tok; ca_load
  assert_has "$(_row "$(FAKE_PING=401 claude-accounts 2>&1)" mohan)" '✗ token rejected · claude-accounts token mohan'
}

test_table_token_missing() {
  ca_token_profile mohan ''; ca_load
  assert_has "$(_row "$(claude-accounts 2>&1)" mohan)" '✗ no token · claude-accounts token mohan'
  assert_lacks "$(ca_calls curl)" 'v1/messages'
}

test_table_token_no_answer() {
  ca_token_profile mohan tok; ca_load; local out; out=$(FAKE_PING=neterr claude-accounts 2>&1)
  assert_has "$(_row "$out" mohan)" '✓ token'; assert_eq '?' "$(_cell "$(_row "$out" mohan)" 3)"
  assert_has "$out" 'mohan: health check got no answer'
}

test_table_token_at_limit() {   # Review Focus 4
  ca_token_profile mohan tok; ca_load; local row; row=$(_row "$(FAKE_PING=429 FAKE_5H=1.0 claude-accounts 2>&1)" mohan)
  assert_has "$row" '100%'; assert_has "$row" '✓ token'
}

test_table_mixed_profiles() {
  ca_login_profile work work@example.com; ca_token_profile mohan tok; ca_load
  local out; out=$(claude-accounts 2>&1)
  assert_has "$(_row "$out" work)" '✓ 28d'; assert_has "$out" 'WEEK FABLE'
  assert_eq '-' "$(_cell "$(_row "$out" mohan)" 5)"
  assert_eq 1 "$(ca_calls curl | grep -c v1/messages)"
}

test_table_survives_an_unwritable_cache() {   # final review: one failed cache write took down every row
  ca_login_profile work work@example.com; ca_token_profile mohan tok; ca_load
  mkdir -p "$HOME/.cache/claude-accounts"; chmod 500 "$HOME/.cache/claude-accounts"
  local out; out=$(claude-accounts 2>&1)
  assert_lacks "$out" 'Traceback'
  assert_has "$(_row "$out" work)" 'work@example.com'
  assert_has "$(_row "$out" mohan)" '  5%'; assert_has "$(_row "$out" mohan)" '✓ token'
}
