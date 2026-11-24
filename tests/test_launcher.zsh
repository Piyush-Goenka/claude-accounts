# claude-<name> launchers: a function that supplies the token for token
# profiles, today's alias for browser-login profiles. eval makes zsh parse the
# call after the launcher exists, as an interactive prompt would.

test_token_profile_launches_with_its_token() {
  ca_token_profile mohan tok-secret; ca_load
  assert_has "$(whence -w claude-mohan)" 'function'
  local out; out=$(eval 'claude-mohan --resume abc')
  assert_has "$out" "CLAUDE_CONFIG_DIR=$HOME/.claude-mohan"
  assert_has "$out" 'CLAUDE_CODE_OAUTH_TOKEN=tok-secret'; assert_has "$out" 'ARGS=--resume abc'
  assert_eq '<unset>' "${CLAUDE_CODE_OAUTH_TOKEN-<unset>}"
  assert_lacks "$(alias; functions claude-mohan)" 'tok-secret'
}

test_login_profile_keeps_alias() {
  ca_login_profile work w@example.com; ca_load
  assert_eq "CLAUDE_CONFIG_DIR=$HOME/.claude-work claude" "${aliases[claude-work]}"
}

test_resource_over_a_stale_alias_uses_token() {   # Review Focus 1
  ca_token_profile mohan tok-secret
  alias claude-mohan="CLAUDE_CONFIG_DIR=$HOME/.claude-mohan claude"
  ca_load
  assert_has "$(eval 'claude-mohan')" 'CLAUDE_CODE_OAUTH_TOKEN=tok-secret'
}

test_empty_token_refuses_to_launch() {
  ca_token_profile mohan ''; ca_load; local out rc; out=$(eval 'claude-mohan' 2>&1); rc=$?
  assert_eq 1 $rc; assert_has "$out" 'claude-accounts token mohan'; assert_lacks "$out" 'CLAUDE_CONFIG_DIR='
}

test_token_launcher_honours_a_claude_alias() {   # final review: the alias launchers already do
  ca_token_profile mohan tok-secret; ca_load
  alias claude='claude --via-alias'
  local out; out=$(eval 'claude-mohan x')
  assert_has "$out" 'ARGS=--via-alias x'; assert_has "$out" 'CLAUDE_CODE_OAUTH_TOKEN=tok-secret'
  assert_eq '<unset>' "${CLAUDE_CODE_OAUTH_TOKEN-<unset>}"
}

test_token_launcher_honours_a_claude_function() {
  ca_token_profile mohan tok-secret; ca_load
  claude() { print -r -- 'WRAPPED'; command claude "$@" }
  local out; out=$(eval 'claude-mohan x')
  assert_has "$out" 'WRAPPED'; assert_has "$out" 'CLAUDE_CODE_OAUTH_TOKEN=tok-secret'
}
