# create --token, token, and the cleanup in delete and uninstall. Where a
# test checks a launcher defined in the current shell, output goes to a file:
# $(...) would run the command in a subshell.

test_create_token_profile() {   # Review Focus 2
  ca_load
  print -l '  tok-secret  ' 'work max' | claude-accounts create mohan --token >$HOME/out 2>&1
  assert_eq 0 $?
  assert_eq tok-secret "$(<$HOME/.claude-mohan/.setup-token)"
  assert_has "$(<$HOME/out)" 'session 5% · week 20%'; assert_lacks "$(<$HOME/out)" 'tok-secret'
  assert_has "$(whence -w claude-mohan)" 'function'; assert_exists "$HOME/.claude-mohan/settings.json"
  claude-accounts >/dev/null 2>&1
  assert_eq 1 "$(ca_calls curl | grep -c v1/messages)"   # the first table reuses create's ping
}

test_create_token_flag_first() {
  ca_load; print -l t x | claude-accounts create --token mohan >/dev/null 2>&1
  assert_exists "$HOME/.claude-mohan/.setup-token"
}

test_create_token_existing_name() {   # Review Focus 3
  mkdir "$HOME/.claude-mohan"; ca_load
  print -l tok-secret '' | claude-accounts create mohan --token >$HOME/out 2>&1; assert_eq 1 $?
  assert_has "$(<$HOME/out)" 'already exists'; assert_lacks "$(<$HOME/out)" 'setup-token'
  assert_lacks "$(ca_calls curl)" 'v1/messages'
}

test_create_token_rejected_leaves_nothing() {
  ca_load; print -l bad '' | FAKE_PING=401 claude-accounts create mohan --token >$HOME/out 2>&1
  assert_eq 1 $?; assert_has "$(<$HOME/out)" 'rejected'
  assert_missing "$HOME/.claude-mohan"; assert_missing "$HOME/.cache/claude-accounts/ping-mohan.json"
}

test_create_token_no_answer_leaves_nothing() {
  ca_load; print -l t '' | FAKE_PING=neterr claude-accounts create mohan --token >/dev/null 2>&1
  assert_eq 1 $?; assert_missing "$HOME/.claude-mohan"
}

test_create_token_empty_input() {
  ca_load; print -l '' '' | claude-accounts create mohan --token >/dev/null 2>&1
  assert_eq 1 $?; assert_missing "$HOME/.claude-mohan"; assert_lacks "$(ca_calls curl)" 'v1/messages'
}

test_token_replaces_and_keeps_label() {
  ca_token_profile mohan old-tok 'work max'; ca_load
  print -l new-tok | claude-accounts token mohan >/dev/null 2>&1; assert_eq 0 $?
  assert_eq new-tok "$(<$HOME/.claude-mohan/.setup-token)"
  assert_has "$(<$HOME/.claude-mohan/.claude-accounts.json)" 'work max'
}

test_token_rejected_keeps_old_and_cache() {   # Review Focus 5
  ca_token_profile mohan old-tok; ca_load; CA_PING_TOKEN=old-tok _ca_py ping mohan >/dev/null
  print -l bad | FAKE_PING=401 claude-accounts token mohan >/dev/null 2>&1; assert_eq 1 $?
  assert_eq old-tok "$(<$HOME/.claude-mohan/.setup-token)"
  assert_has "$(<$HOME/.cache/claude-accounts/ping-mohan.json)" '"http": 200'
}

test_token_refuses_non_token_profiles() {
  ca_login_profile work w@example.com; ca_load; local n
  for n in work default ghost; do print -l t | claude-accounts token $n >/dev/null 2>&1; assert_eq 1 $?; done
  assert_has "$(print -l t | claude-accounts token work 2>&1)" '--token'
}

test_delete_token_profile_cleans_up() {
  ca_token_profile mohan tok; ca_load; CA_PING_TOKEN=tok _ca_py ping mohan >/dev/null
  claude-accounts delete mohan >/dev/null
  assert_missing "$HOME/.claude-mohan"; assert_missing "$HOME/.cache/claude-accounts/ping-mohan.json"
  assert_has "$(whence -w claude-mohan)" 'none'
}

test_uninstall_removes_tokens_and_cache() {
  ca_token_profile mohan tok; mkdir -p "$HOME/.cache/claude-accounts"
  touch "$HOME/.cache/claude-accounts/ping-mohan.json"
  bash "$CA_REPO/uninstall.sh" >/dev/null 2>&1
  assert_missing "$HOME/.claude-mohan"; assert_missing "$HOME/.cache/claude-accounts"
}

test_help_lists_token_forms() {
  ca_load; local out; out=$(claude-accounts help)
  assert_has "$out" 'claude-accounts create <name> --token'; assert_has "$out" 'claude-accounts token <name>'
}

test_create_token_joins_a_wrapped_paste() {   # final review: the tail of a wrapped paste was left behind
  ca_load
  python3 "$CA_REPO/tests/pty_drive.py" 'source "$CA_REPO/claude-accounts.zsh"; claude-accounts create mohan --token' \
    'wait:token: ' 'send:tok-first\ntok-second\n' 'sleep:2' 'send:work max\n' 'until:launcher ready' >/dev/null
  assert_eq tok-firsttok-second "$(<$HOME/.claude-mohan/.setup-token)"
  assert_lacks "$(<$HOME/.claude-mohan/.claude-accounts.json)" 'tok-second'
  assert_has "$(<$HOME/.claude-mohan/.claude-accounts.json)" 'work max'
}

_create_in_terminal() {   # create mohan --token in a real terminal, typing $1 as the token
  python3 "$CA_REPO/tests/pty_drive.py" 'source "$CA_REPO/claude-accounts.zsh"; claude-accounts create mohan --token' \
    'wait:token: ' "send:$1" 'wait:to skip' 'send:\n' 'until:launcher ready'
}

test_token_prompt_shows_a_star_per_character() {
  ca_load; local out; out=$(_create_in_terminal 'tok-secret\n')
  assert_has "$out" 'token: **********'$'\n'          # ten characters, ten stars
  assert_lacks "$out" 'secret'
  assert_eq tok-secret "$(<$HOME/.claude-mohan/.setup-token)"
}

test_token_prompt_backspace_removes_a_character() {
  ca_load; _create_in_terminal 'tok-secretX\x7f\n' >/dev/null
  assert_eq tok-secret "$(<$HOME/.claude-mohan/.setup-token)"
}

test_label_prompt_says_what_it_is_for() {
  ca_load; local out; out=$(_create_in_terminal 'tok-secret\n')
  assert_has "$out" 'name to show for this account (e.g. its email), Enter to skip:'
}

test_ctrl_c_at_the_token_prompt_restores_the_terminal() {
  ca_load
  local out; out=$(python3 "$CA_REPO/tests/pty_drive.py" --interactive - \
    'send:PS1="$ "; source "$CA_REPO/claude-accounts.zsh"; claude-accounts create mohan --token\n' \
    'wait:token: ' 'send:tok-sec' 'sleep:0.3' 'send:\x03' 'sleep:0.8' \
    'send:stty -a | tr " " "\\n" | grep -x -- "-\\?echo"\n' 'sleep:1')
  assert_has "$out" $'\necho\n'; assert_lacks "$out" $'\n-echo\n'
  assert_lacks "$out" 'tok-sec'; assert_missing "$HOME/.claude-mohan"
}
