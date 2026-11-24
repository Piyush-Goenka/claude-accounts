# The VS Code wrapper: a token profile's token reaches claude, nothing else changes.

_wrapper() {   # map ~/proj to profile $1
  sed "s|__MAP_PATH__|$HOME/map.json|" "$CA_REPO/vscode-claude-switch/wrapper.template.sh" >"$HOME/wrapper.sh"
  mkdir -p "$HOME/proj"; print -r -- "{\"$HOME/proj\": \"$1\"}" >"$HOME/map.json"
}
_spawn() { (cd "$HOME/proj" && zsh "$HOME/wrapper.sh" "$CA_REPO/tests/bin/claude" --x 2>&1) }

test_wrapper_exports_token() {
  ca_token_profile mohan tok-secret; _wrapper mohan; local out; out=$(_spawn)
  assert_has "$out" "CLAUDE_CONFIG_DIR=$HOME/.claude-mohan"; assert_has "$out" 'CLAUDE_CODE_OAUTH_TOKEN=tok-secret'
  assert_lacks "$(<$HOME/last-spawn.log)" 'tok-secret'
}

test_wrapper_login_profile_untouched() {
  ca_login_profile work w@example.com; _wrapper work
  assert_has "$(_spawn)" 'CLAUDE_CODE_OAUTH_TOKEN=<unset>'
}

test_wrapper_unreadable_token_fails_open() {
  ca_token_profile mohan tok-secret; chmod 000 "$HOME/.claude-mohan/.setup-token"; _wrapper mohan
  local out; out=$(_spawn); assert_has "$out" 'CLAUDE_CODE_OAUTH_TOKEN=<unset>'; assert_has "$out" 'ARGS=--x'
}
