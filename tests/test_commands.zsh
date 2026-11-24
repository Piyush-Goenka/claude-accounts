# create, delete, update and help as subcommands; the old names forward.

test_create_makes_profile_and_alias() {
  ca_load; claude-accounts create mohan >/dev/null
  assert_exists "$HOME/.claude-mohan/settings.json"
  assert_eq "CLAUDE_CONFIG_DIR=$HOME/.claude-mohan claude" "${aliases[claude-mohan]}"
}

test_create_strips_claude_prefix() {
  ca_load; claude-accounts create claude-rohan >/dev/null; assert_exists "$HOME/.claude-rohan"
}

test_delete_removes_profile_credential_and_alias() {
  ca_login_profile work w@example.com; ca_load; claude-accounts delete work >/dev/null
  assert_missing "$HOME/.claude-work"; assert_eq '' "${aliases[claude-work]}"
  assert_has "$(ca_calls security)" "delete-generic-password -s Claude Code-credentials-$(ca_hash $HOME/.claude-work)"
}

test_help_forms() {
  ca_load; local f form out
  for f in help --help -h; do
    out=$(claude-accounts $f)
    for form in 'claude-accounts create <name>' 'claude-accounts delete <name>' \
                'claude-accounts update' 'claude-accounts help'; do assert_has "$out" "$form"; done
    assert_lacks "$out" '--json'; assert_lacks "$out" 'claude-create'
  done
}

test_update_reports_offline() {
  ca_load; local out rc; out=$(claude-accounts update 2>&1); rc=$?
  assert_eq 1 $rc; assert_has "$out" 'could not reach GitHub'
}

test_gate_skips_help_and_runs_for_create() {
  rm "$HOME/.cache/claude-accounts-check"; ca_load
  claude-accounts help >/dev/null;     assert_lacks "$(ca_calls curl)" 'api.github.com'
  claude-accounts create x >/dev/null; assert_has   "$(ca_calls curl)" 'api.github.com'
}

test_old_names_forward_with_notice() {
  ca_load; local err; err=$(claude-create mohan 2>&1 >/dev/null)
  assert_has "$err" 'claude-accounts create'; assert_exists "$HOME/.claude-mohan"
  assert_eq "$(claude-accounts help)" "$(claude-help 2>/dev/null)"
}

test_installer_hint_uses_new_form() { assert_lacks "$(<$CA_REPO/install.sh)" 'claude-create' }
