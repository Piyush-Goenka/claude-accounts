# The table, reached through the claude-accounts dispatcher.

test_table_shows_login_profile() {
  ca_login_profile work work@example.com; ca_load
  local out; out=$(claude-accounts 2>&1)
  assert_has "$out" 'work@example.com'; assert_has "$out" ' 11%'; assert_has "$out" '✓ 28d'
}

test_table_falls_back_to_cached_usage() {   # keeps row['dir'] alive
  ca_login_profile work work@example.com
  python3 - "$HOME/.claude-work/.claude.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d['cachedUsageUtilization'] = {'utilization': {'five_hour': {'utilization': 42, 'resets_at': None}}}
json.dump(d, open(p, 'w'))
PY
  ca_load
  assert_has "$(FAKE_USAGE=fail claude-accounts 2>&1)" ' 42%'
}

test_json_flag_is_rejected() {
  ca_load; local out rc; out=$(claude-accounts --json 2>&1); rc=$?
  assert_eq 1 $rc; assert_has "$out" 'unknown flag'; assert_lacks "$out" 'PROFILE'
}

test_unknown_command_is_rejected() {
  ca_load; local out rc; out=$(claude-accounts frobnicate 2>&1); rc=$?
  assert_eq 1 $rc; assert_has "$out" 'claude-accounts help'
}
