# _ca_py modes: the health-check ping, its cache, and the token and label files.

_cache() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["http"], d["five_hour"]["utilization"], d["seven_day"]["utilization"])' "$HOME/.cache/claude-accounts/ping-$1.json" }

test_ping_accepted() {
  ca_load; local out; out=$(CA_PING_TOKEN=tok-secret _ca_py ping mohan); assert_eq 0 $?
  assert_eq '200 5 20' "$out"; assert_eq '200 5.0 20.0' "$(_cache mohan)"
  assert_lacks "$(<$HOME/.cache/claude-accounts/ping-mohan.json)" 'tok-secret'
}

test_ping_token_travels_on_stdin_only() {
  ca_load; CA_PING_TOKEN=tok-secret _ca_py ping mohan >/dev/null
  assert_has   "$(ca_calls curl-stdin)" 'Authorization: Bearer tok-secret'
  assert_lacks "$(ca_calls curl-argv)"  'tok-secret'
  assert_has   "$(ca_calls curl-argv)"  'anthropic-beta: oauth-2025-04-20'
  assert_has   "$(ca_calls curl-argv)"  '{"model":"claude-haiku-4-5-20251001","max_tokens":1,"messages":[{"role":"user","content":"."}]}'
}

test_ping_at_limit_is_accepted() {   # Review Focus 4
  ca_load; local out; out=$(FAKE_PING=429 FAKE_5H=1.0 CA_PING_TOKEN=t _ca_py ping m); assert_eq 0 $?
  assert_eq '429 100 20' "$out"
}

test_ping_rejected_writes_no_cache() {   # Review Focus 5
  ca_load; local out; out=$(FAKE_PING=401 CA_PING_TOKEN=t _ca_py ping m); assert_eq 2 $?
  assert_eq '401 - -' "$out"; assert_missing "$HOME/.cache/claude-accounts/ping-m.json"
}

test_ping_no_answer()    { ca_load; local out; out=$(FAKE_PING=neterr CA_PING_TOKEN=t _ca_py ping m); assert_eq 3 $?; assert_eq '0 - -' "$out" }

test_ping_other_status() { ca_load; local out; out=$(FAKE_PING=404 CA_PING_TOKEN=t _ca_py ping m); assert_eq 3 $?; assert_eq '404 - -' "$out" }

test_save_writes_token_and_label() {
  ca_load; mkdir -p "$HOME/.claude-mohan"; CA_PING_TOKEN=tok-secret _ca_py save mohan 'work max'
  assert_eq tok-secret "$(<$HOME/.claude-mohan/.setup-token)"; assert_mode 600 "$HOME/.claude-mohan/.setup-token"
  assert_has "$(<$HOME/.claude-mohan/.claude-accounts.json)" '"label": "work max"'
  assert_mode 600 "$HOME/.claude-mohan/.claude-accounts.json"
}

test_save_replaces_a_wide_file_and_keeps_label() {
  ca_token_profile mohan old-tok 'work max'; chmod 644 "$HOME/.claude-mohan/.setup-token"; ca_load
  CA_PING_TOKEN=new-tok _ca_py save mohan
  assert_eq new-tok "$(<$HOME/.claude-mohan/.setup-token)"; assert_mode 600 "$HOME/.claude-mohan/.setup-token"
  assert_has "$(<$HOME/.claude-mohan/.claude-accounts.json)" 'work max'
  assert_eq '.claude-accounts.json .setup-token' "$(cd $HOME/.claude-mohan && print -r -- .*(N))"
}

test_save_without_profile_fails() { ca_load; CA_PING_TOKEN=t _ca_py save ghost; assert_eq 1 $? }

test_ping_survives_an_unwritable_cache() {   # final review: create --token failed with "HTTP 200"
  ca_load; mkdir -p "$HOME/.cache/claude-accounts"; chmod 500 "$HOME/.cache/claude-accounts"
  local out; out=$(CA_PING_TOKEN=t _ca_py ping m 2>&1); assert_eq 0 $?
  assert_eq '200 5 20' "$out"
}
