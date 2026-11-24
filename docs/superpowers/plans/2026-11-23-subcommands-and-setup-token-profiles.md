# Subcommands and Setup-Token Profiles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move every admin command behind one `claude-accounts` entry point, then let named profiles log in with a setup token that is stored per profile, supplied at every launch, and health-checked for limits in the table.

**Architecture:** All CLI code stays in the one distributed file `claude-accounts.zsh`. A zsh dispatcher calls `_ca_cmd_*` functions, and one embedded Python program, `_ca_py`, runs in three modes: `table` (today's table), `ping` (health check) and `save` (writes the token and label files). A token profile is marked by `~/.claude-<name>/.setup-token`; its terminal launcher becomes a zsh function and the VS Code wrapper reads the same file. A new sandboxed suite under `tests/` stubs `security`, `curl` and `claude`.

**Tech Stack:** zsh 5.9, Python 3 standard library, curl, macOS `security`, a plain Node VS Code extension. Tests: zsh, plus `node --test` for the extension (Node is test-only).

**Spec:** Tasks 1-2: `docs/superpowers/specs/2026-11-23-claude-accounts-subcommands-design.md`. Tasks 3-7: `docs/superpowers/specs/2026-11-23-setup-token-profiles-design.md`.

## Global Constraints

- No em dashes anywhere: code, comments, messages, docs, commit messages.
- Runtime dependencies stay macOS, zsh, Python 3 standard library, curl and `security`.
- All CLI code stays in `claude-accounts.zsh`, the release asset. Tests live in `tests/`, never in `vscode-claude-switch/`, which ships as the extension.
- Do not change `CLAUDE_ACCOUNTS_VERSION`.
- Browser-login profiles behave exactly as before: their `claude-<name>` alias, table row, token refresh and VS Code behaviour.
- The setup token exists only in `~/.claude-<name>/.setup-token`. Never in shell history, alias or function text, a command line, a temp file, a here-string or here-document, a log, the ping cache, any printed output, or the interactive shell's environment. It reaches a child process only through that process's environment or a pipe; curl gets the bearer header on stdin with `-H @-`.
- `.setup-token` and `.claude-accounts.json` are mode 600 from the moment they exist.
- Ping request, verbatim: `POST https://api.anthropic.com/v1/messages`, headers `Authorization: Bearer <token>`, `anthropic-version: 2023-06-01`, `anthropic-beta: oauth-2025-04-20`, `Content-Type: application/json`, body `{"model":"claude-haiku-4-5-20251001","max_tokens":1,"messages":[{"role":"user","content":"."}]}`, no custom User-Agent.
- Ping floor 300 seconds per profile, no bypass. Cache `~/.cache/claude-accounts/ping-<name>.json` = `{"ts": <epoch seconds>, "http": <status>, "five_hour": {"utilization": <percent>, "resets_at": "<ISO 8601>"}, "seven_day": {...}}`, no secret.
- The VS Code extension never reads the token and never pings. The wrapper stays fail-open.
- Tests never touch the real Keychain, the network or the real `$HOME`. Run them only with `zsh -f tests/run.zsh`.
- Commits only with the owner's explicit go-ahead for that commit. Plain `git commit`: no co-author or other trailer, no identity flags or variables.

## Review Focus

1. Re-sourcing the script in a shell where `claude-<name>` is already an alias (the daily auto-update does exactly this) must leave the token launcher in charge: zsh expands an alias before it looks up a function of the same name. Test in Task 4.
2. A token pasted with spaces around it is stored trimmed. Test in Task 5.
3. `create <name> --token` for a name that already exists fails before asking for a token. Test in Task 5.
4. An account at its limit (ping answers 429, headers present) counts as a working token and shows its numbers. Tests in Tasks 3 and 6.
5. A rejected replacement in `token <name>` keeps the old token and does not mark the profile rejected. Tests in Tasks 3 and 5.

---

### Task 1: Test harness, and the table behind the new dispatcher

**Files:**
- Create: `tests/run.zsh`, `tests/lib.zsh`, `tests/bin/security`, `tests/bin/curl`, `tests/bin/claude` (all three executable), `tests/test_table.zsh`
- Modify: `claude-accounts.zsh:220-577`

**Interfaces:**
- Produces, for every later task:
  - `zsh -f tests/run.zsh`: runs each `test_*` function of each `tests/test_*.zsh` in its own subshell after `ca_sandbox`, prints `ok` or `FAIL` per test and a total, then runs `node --test tests/extension.test.js` when that file exists and `node` is on PATH. Exits non-zero on any failure.
  - `tests/lib.zsh`: `ca_sandbox` (exported temp `HOME` containing `~/.claude` and `~/.claude.json`, a fresh `~/.cache/claude-accounts-check`, `PATH=$CA_REPO/tests/bin:$PATH`, `CA_REPO` set; aborts the whole run unless `command -v security` resolves to the shim), `ca_load` (sources `claude-accounts.zsh`; may be called again), `ca_hash <dir>`, `ca_login_profile <name> <email>` (folder, `.claude.json` with `oauthAccount.emailAddress`, Keychain item `Claude Code-credentials-<hash>` holding access token `at-<name>` valid for 8 hours and `refreshTokenExpiresAt` 28.4 days ahead), `ca_token_profile <name> <token> [label]` (folder, `.setup-token` mode 600 with the token and a newline, an empty file when the token is `''`, and the label file when a label is given), `ca_calls <log>` (contents of `$HOME/.calls/<log>.log`, empty when that log does not exist yet), `assert_eq <want> <got>`, `assert_has <text> <needle>`, `assert_lacks <text> <needle>`, `assert_exists <path>`, `assert_missing <path>`, `assert_mode <600> <file>`.
  - Shims, controlled by environment variables, logging under `$HOME/.calls/`:

| Shim | Behaviour |
|---|---|
| `security` | Store in `$HOME/.fake-keychain/`. `find-generic-password -s S [-a A] [-w]`: the password with `-w`, otherwise a line `"acct"<blob>="A"`; exit 44 when absent. `add-generic-password -U -s S -a A -X HEX` stores the decoded value. `delete-generic-password -s S [-a A]`. Logs each call's arguments to `security.log`, with any `-X` value masked. |
| `curl` | Accepts `-s -S -f -L --max-time -o -D -w -H` (including `@-`), `-d -X -A`. Logs the URL to `curl.log`, the arguments to `curl-argv.log`, stdin to `curl-stdin.log`. `https://api.anthropic.com/v1/messages`: `FAKE_PING` is `ok` (200, default), `429`, `401`, `404` or `neterr` (exit 7, no output); 200 and 429 carry `anthropic-ratelimit-unified-5h-utilization: $FAKE_5H` (default 0.05), `anthropic-ratelimit-unified-7d-utilization: $FAKE_7D` (default 0.20) and `-5h-reset`/`-7d-reset` epochs 2 hours and 6 days ahead, CRLF line ends. `https://api.anthropic.com/api/oauth/usage`: 200 with five_hour 11.0 (resets in 2 hours), seven_day 1.0 (6 days) and one `weekly_scoped` limit for model `Fable` at 0, or 500 when `FAKE_USAGE=fail`. GitHub URLs exit 22. Anything else exits 6. |
| `claude` | Prints `CLAUDE_CONFIG_DIR=<value or <unset>>`, `CLAUDE_CODE_OAUTH_TOKEN=<value or <unset>>` and `ARGS=<arguments>`, one per line. |

  - `claude-accounts` with no argument draws the table through `_ca_cmd_table`. An argument starting with `-` is an unknown flag, any other is an unknown command: both exit 1 with a message naming `claude-accounts help`, before the update gate runs.

- [ ] **Step 1: Build the harness and shims as specified above.** Check: `zsh -f tests/run.zsh` with no test files reports 0 tests and exits 0.

- [ ] **Step 2: Write the failing tests in `tests/test_table.zsh`**

```zsh
test_table_shows_login_profile() {
  ca_login_profile work work@example.com; ca_load
  local out; out=$(claude-accounts 2>&1)
  assert_has "$out" 'work@example.com'; assert_has "$out" ' 11%'; assert_has "$out" '✓ 28d'
}
test_table_falls_back_to_cached_usage() {   # keeps row['dir'] alive
  ca_login_profile work work@example.com
  # merge into ~/.claude-work/.claude.json:
  #   {"cachedUsageUtilization": {"utilization": {"five_hour": {"utilization": 42, "resets_at": null}}}}
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
```

- [ ] **Step 3: Run `zsh -f tests/run.zsh`.** Expected: the first two pass (today's behaviour, which also proves the harness), the last two FAIL.

- [ ] **Step 4: Move the body of `claude-accounts()` into `_ca_cmd_table()` and make `claude-accounts()` the dispatcher.** Help, update, create and delete arrive in Task 2. Delete `as_json` (line 230) and its branch (lines 424-428). Drop the dead row fields `stale` and `usageFetchedAtMs` (lines 408-409) and `keychainItem` (line 386). Keep `dir`.

- [ ] **Step 5: Run `zsh -f tests/run.zsh` and `zsh -n claude-accounts.zsh`.** Expected: 4 passed, 0 failed; the syntax check prints nothing.

- [ ] **Step 6: Checkpoint.** Ask the owner whether to commit. On a yes: `git add tests claude-accounts.zsh && git commit -m "add test harness; table behind the claude-accounts dispatcher, drop --json"`

---

### Task 2: create, delete, update and help as subcommands; old names forward

**Files:**
- Modify: `claude-accounts.zsh:8-14` (header comment), `:126-218` (commands), the Task 1 dispatcher
- Modify: `install.sh:74`, `uninstall.sh:18`, `README.md:27-33,38,86`, `CHANGELOG.md` (`## Unreleased`)
- Test: `tests/test_commands.zsh`

**Interfaces:**
- Consumes: Task 1's dispatcher and harness.
- Produces: `_ca_cmd_create <name>`, `_ca_cmd_delete <name>`, `_ca_cmd_update`, `_ca_cmd_help`; dispatcher arms `create`, `delete`, `update`, `help|--help|-h`. The update gate runs exactly once for the table, `create` and `delete`, and never for `help`, `update` or unknown input. `_ca_deprecated <old> <new>` prints one dim line on stderr naming the new form. The shims `claude-create`, `claude-delete`, `claude-help` and `claude-accounts-update` call `_ca_deprecated`, then the new form with their arguments.

- [ ] **Step 1: Write the failing tests**

```zsh
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
```

- [ ] **Step 2: Run the suite.** Expected: these 8 FAIL, Task 1's 4 pass.

- [ ] **Step 3: Implement.** Rename the four command bodies to `_ca_cmd_*`, dropping their own gate blocks, and wire the dispatcher. Add `_ca_deprecated` and the four shims. Rewrite the help to the new forms, keeping the per-profile launcher list and the `claude` default line. Update the header comment (lines 8-14), `install.sh:74` to `claude-accounts create <name>  →  claude-<name>  →  /login`, and the `uninstall.sh:18` comment to `claude-accounts delete`.

- [ ] **Step 4: Docs.** README: the usage block (27-33) in the new forms, the `--json` sentence (38) removed, `claude-accounts update` at line 86, and one sentence saying the old names still work for one release and print a notice. CHANGELOG `## Unreleased`: the subcommands, the deprecated names (removed in the next release), `--json` removed.

- [ ] **Step 5: Run the suite and the syntax checks** (`zsh -n claude-accounts.zsh && bash -n install.sh && bash -n uninstall.sh`). Expected: 12 passed, 0 failed, no syntax output.

- [ ] **Step 6: Checkpoint.** On the owner's yes: `git commit -m "move admin commands behind claude-accounts subcommands"` with the files above.

---

### Task 3: `_ca_py` modes: health-check ping, ping cache, token and label files

**Files:**
- Modify: `claude-accounts.zsh` (the `_ca_cmd_table` heredoc becomes `_ca_py`)
- Test: `tests/test_ping.zsh`

**Interfaces:**
- Consumes: `_ca_cmd_table` from Task 1.
- Produces:
  - `_ca_py <mode> [args]` runs the embedded Python with the mode as `sys.argv[1]`; `_ca_cmd_table` becomes `_ca_py table`.
  - `CA_PING_TOKEN=<token> _ca_py ping <name>`: one ping. Prints `<http> <session> <week>`: integer percents or `-`, and http `0` when nothing answered. Exit 0 for 200 and 429, 2 for 401 and 403, 3 otherwise. Writes the cache only when it exits 0.
  - `CA_PING_TOKEN=<token> _ca_py save <name> [label]`: writes `.setup-token` (token plus newline) and, when a label is given, `.claude-accounts.json` = `{"label": "<label>"}` (json.dump default separators). Both are written by atomic replace from a sibling created with mode 600. Exit 1 when `~/.claude-<name>` is missing or a write fails.
  - Python names that Task 6 uses: `PING_TTL = 300`; `ping(token) -> (int, dict)` returning the status (0 when nothing answered) and a dict mapping `five_hour`/`seven_day` to `{"utilization": header fraction x 100 rounded to 2 places, "resets_at": the reset epoch as ISO 8601 UTC}`, each present only when both its headers parse, read from any response that has them; `write_ping_cache(name, http, windows)` (atomic, creates the folder); `read_ping_cache(name) -> dict | None`; `cache_is_fresh(c) -> bool`; `read_token(name) -> str` (trimmed, `''` when empty or unreadable); `read_label(name) -> str`.

- [ ] **Step 1: Write the failing tests**

```zsh
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
```

- [ ] **Step 2: Run the suite.** Expected: these FAIL with `_ca_py: command not found`.

- [ ] **Step 3: Implement.** Rename the heredoc's function to `_ca_py` (passing `"$@"`, keeping `_CA_EXCLUDE_CSV`) and add `_ca_cmd_table() { _ca_py table }`. In the Python, put the new helpers with the other `def`s, and add `ping` and `save` branches that `sys.exit` before `rows = [...]`. The ping runs curl with `--max-time 10 -o /dev/null -D - -H @-`, sends the bearer header on stdin, and reads the status line and headers (CRLF) from stdout. Integer percents for the `ping` output are `round()` of the cached value.

- [ ] **Step 4: Run the suite.** Expected: all pass.

- [ ] **Step 5: Checkpoint.** On the owner's yes: `git commit -m "add health-check ping, ping cache and token file writer"`

---

### Task 4: Token launchers

**Files:**
- Modify: `claude-accounts.zsh:39-47` (startup loop) and the alias line in `_ca_cmd_create`
- Test: `tests/test_launcher.zsh`

**Interfaces:**
- Consumes: Task 2's `_ca_cmd_create`.
- Produces:
  - `_ca_launcher_define <name>`: when `~/.claude-<name>/.setup-token` exists, removes any `claude-<name>` alias and defines a function `claude-<name>` that runs `_ca_launch_token <name> "$@"`. Otherwise removes any such function and defines today's alias.
  - `_ca_launch_token <name> [args]`: reads the token file when called. Empty or unreadable: one `_ca_err` line naming `claude-accounts token <name>`, exit 1, Claude not started. Otherwise `command claude "$@"` with `CLAUDE_CONFIG_DIR` and `CLAUDE_CODE_OAUTH_TOKEN` set for that one process.
  - Both are defined above the startup loop, which calls `_ca_launcher_define` for each profile. Plain `_ca_cmd_create` calls it instead of setting its alias inline.

- [ ] **Step 1: Write the failing tests** (`eval` makes zsh parse the call after the launcher exists, as an interactive prompt would)

```zsh
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
```

- [ ] **Step 2: Run the suite.** Expected: the token tests FAIL, because token profiles still get the plain alias.

- [ ] **Step 3: Implement as specified in Interfaces.**

- [ ] **Step 4: Run the suite.** Expected: all pass.

- [ ] **Step 5: Checkpoint.** On the owner's yes: `git commit -m "launch token profiles with their setup token"`

---

### Task 5: `create --token`, `token`, cleanup, and docs

**Files:**
- Modify: `claude-accounts.zsh` (`_ca_cmd_create`, new `_ca_cmd_token`, `_ca_cmd_delete`, dispatcher, help, header comment), `uninstall.sh`, `README.md`, `CHANGELOG.md`
- Test: `tests/test_token_commands.zsh`

**Interfaces:**
- Consumes: `_ca_py ping` and `_ca_py save` (Task 3), `_ca_launcher_define` (Task 4).
- Produces: `claude-accounts create <name> --token` (the flag may come before or after the name) and `claude-accounts token <name>`, both behind the update gate.

The order of `create --token` is chosen so that an abort or failure at any point leaves nothing behind. This differs from the order the spec lists; the outcome is the same.

1. Validate the name and refuse an existing profile.
2. Print the `claude setup-token` instructions.
3. Read the token with echo off (`read -rs`), trimmed. Empty input exits 1.
4. Read the label (`create` only).
5. `CA_PING_TOKEN=<token> _ca_py ping <name>`. Exit 2: report the token rejected; exit 3: report the HTTP status or "no answer". Either way exit 1 having created nothing.
6. On exit 0: create the folder and symlinks (`create` only), `_ca_py save`, `_ca_launcher_define`, then print `✓ token accepted  session S% · week W%` and the usual rows.

`token <name>` refuses `default`, unknown profiles, and profiles without `.setup-token` (its message names `create <name> --token`). It keeps the old token on any failure and never changes the label. `delete` additionally removes a `claude-<name>` function and `~/.cache/claude-accounts/ping-<name>.json`. `uninstall.sh` additionally removes `~/.cache/claude-accounts`.

- [ ] **Step 1: Write the failing tests.** Where a test checks a launcher defined in the current shell, capture output in a file, not with `$(...)`, which would run the command in a subshell.

```zsh
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
```

- [ ] **Step 2: Run the suite.** Expected: these FAIL (`--token` is not understood yet).

- [ ] **Step 3: Implement** the commands, the `token` dispatcher arm (behind the gate), the `delete` and `uninstall.sh` additions, the two help lines, and the header comment lines.

- [ ] **Step 4: Docs.** README: a "Setup-token accounts" section after the first-login tip (line 58) covering: making one (`claude setup-token` in another terminal, choosing the account in the browser, then `claude-accounts create <name> --token`); replacing a token (`claude-accounts token <name>`); where the token lives (`~/.claude-<name>/.setup-token`, mode 600) and that backups and copies of that folder carry it; what the table shows (session and week from a 1-token health check sent when you run `claude-accounts`, at most once per 5 minutes per account; no per-model weekly; the label instead of an email; the three LOGIN states); that launching works the same in the terminal and VS Code; to stop exporting `CLAUDE_CODE_OAUTH_TOKEN` by hand; that the default account is not supported. CHANGELOG `## Unreleased`: one bullet per new command plus one for the table and VS Code support.

- [ ] **Step 5: Run the suite and the syntax checks.** Expected: all pass, no syntax output.

- [ ] **Step 6: Checkpoint.** On the owner's yes: `git commit -m "add setup-token profiles: create --token, token, cleanup"`

---

### Task 6: Token profiles in the table

**Files:**
- Modify: `claude-accounts.zsh` (Python: `entry`, the thread pool, row post-processing, `login_cell`)
- Test: `tests/test_table_tokens.zsh`

**Interfaces:**
- Consumes: Task 3's Python names.
- Produces: table rows carry `auth` (`'token'` or `'login'`) and, for token rows, `tokenState` (`'ok'`, `'rejected'` or `'missing'`).

For a non-default profile whose `.setup-token` exists: ACCOUNT is `read_label()` or `-`. There is no Keychain read, no refresh and no usage-endpoint call. An empty token gives `missing`, logged out, and no ping. Otherwise use the cache when `cache_is_fresh`, else `ping()` inside the existing pool and `write_ping_cache` for any status other than 0. 401 or 403: `rejected`, logged out. 200 or 429: the windows go through the existing `limit()` as `session` and `week`, and model columns show `-`. Anything else: logged in, usage `None` (renders `?`), and a warning `<name>: health check returned HTTP <n>, usage not shown` or `<name>: health check got no answer, usage not shown`. LOGIN text: `✓ token`, `✗ token rejected · claude-accounts token <name>`, `✗ no token · claude-accounts token <name>` (tight forms are the builder's wording).

- [ ] **Step 1: Write the failing tests**

```zsh
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
```

- [ ] **Step 2: Run the suite.** Expected: these FAIL; token profiles render as logged-out browser profiles.

- [ ] **Step 3: Implement as specified above.**

- [ ] **Step 4: Run the suite.** Expected: all pass, including every earlier table test.

- [ ] **Step 5: Checkpoint.** On the owner's yes: `git commit -m "show token profiles' limits in the table"`

---

### Task 7: VS Code wrapper and extension

**Files:**
- Modify: `vscode-claude-switch/wrapper.template.sh:31-34`, `vscode-claude-switch/extension.js` (`accountInfo` 113-132, `fmtUsage` 192-197, `fmtLogin` 199-206, exports 392), `vscode-claude-switch/package.json` (version `0.2.0`)
- Test: `tests/test_wrapper.zsh`, `tests/extension.test.js`

**Interfaces:**
- Consumes: the token file, label file and ping cache formats (Global Constraints, Task 3).
- Produces: `module.exports._internals = { accountInfo, fmtLogin, fmtUsage }`. Token `info` objects gain `auth: 'token'`, `tokenState`, and `usage` = `{ session, week, scoped: [], asOf: <ms> }` or `null`.

Wrapper: after exporting `CLAUDE_CONFIG_DIR`, when `$CLAUDE_CONFIG_DIR/.setup-token` is non-empty and readable, export its contents, without the trailing newline, as `CLAUDE_CODE_OAUTH_TOKEN`. Otherwise change nothing. The breadcrumb line stays as it is.

Extension: for a non-default profile with a `.setup-token`, `accountInfo` never calls `readCred` or `fetchUsage` and never opens the token file (it takes the size from `fs.statSync`). `tokenState` is `missing` for size 0, `rejected` when the cache's `http` is 401 or 403, otherwise `ok`. `loggedIn` is `tokenState === 'ok'`. `email` is the label or `null`. Usage comes from the cache: each window's percent rounded, `null` once that window's `resets_at` has passed; no cache gives `usage = null`. `fmtLogin` returns `✓ token`, `✗ token rejected` or `✗ no token`. `fmtUsage` for a token profile returns `S <s or ?>% · W <w or ?>% · as of HH:MM` (local time of `asOf`), `usage n/a` when usage is null or both windows are null, and `logged out` when not logged in. Strings for browser-login profiles are unchanged.

- [ ] **Step 1: Write the failing wrapper tests in `tests/test_wrapper.zsh`**

```zsh
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
```

- [ ] **Step 2: Write the failing extension tests in `tests/extension.test.js`** with `node:test` and `node:assert/strict`. Setup: a temp `HOME` from `fs.mkdtempSync`, assigned to `process.env.HOME`; `process.env.PATH` prefixed with `tests/bin`; the `vscode` module stubbed through a `Module._load` hook before requiring `../vscode-claude-switch/extension.js`; fixture helpers for a token profile, the label file and a cache file. Each test uses its own profile name so fixtures never meet. Tests:
  - token profile with a fresh cache (5 and 20, resets ahead): `auth` `'token'`, `tokenState` `'ok'`, `loggedIn` true, `email` `'work max'`, `usage.session` 5, `usage.week` 20, `fmtLogin` `'✓ token'`, `fmtUsage` matching `/^S 5% · W 20% · as of \d\d:\d\d$/`, and no `$HOME/.calls/security.log`
  - five_hour reset one hour ago: `usage.session` null, `fmtUsage` matching `/^S \?% · W 20% · as of /`
  - cache `http` 401: `tokenState` `'rejected'`, `loggedIn` false, `fmtLogin` `'✗ token rejected'`
  - empty token file: `tokenState` `'missing'`, `fmtLogin` `'✗ no token'`
  - token file mode 000: `tokenState` `'ok'` (state comes from size, never from contents)
  - no cache: `usage` null, `fmtUsage` `'usage n/a'`
  - browser strings unchanged: `fmtLogin({ loggedIn: true, loginDays: 28.4 })` is `'✓ 28d'`; `fmtUsage({ loggedIn: true, usage: { session: 11, week: 1, scoped: [{ name: 'Fable', percent: 0 }] } })` is `'S 11% · W 1% · FABLE 0%'`
  - `package.json` version is `'0.2.0'`

- [ ] **Step 3: Run the suite.** Expected: the wrapper token test and the extension tests FAIL (`_internals` is undefined).

- [ ] **Step 4: Implement as specified above.**

- [ ] **Step 5: Run the suite, `node --check vscode-claude-switch/extension.js` and `zsh -n vscode-claude-switch/wrapper.template.sh`.** Expected: all pass, no check output.

- [ ] **Step 6: Checkpoint.** On the owner's yes: `git commit -m "VS Code: launch token profiles with their token, show their state and cached usage"`

---

## Acceptance with the owner

Needs a real setup token and the real Keychain, so the owner runs it or approves each step. Nothing here is automated.

- [ ] `zsh -f tests/run.zsh`: everything passes.
- [ ] Source the working copy in a fresh terminal (or `./install.sh`). `claude-accounts create test --token` with a fresh `claude setup-token`; `claude-test`, then `/usage` inside it; `claude-accounts` shows the row with the label, session, week and `✓ token`; open a folder mapped to `test` in VS Code and confirm the Claude panel is signed in; `claude-accounts token test` with a new token; `claude-accounts delete test`, then `ls ~/.claude-test ~/.cache/claude-accounts/ping-test.json` shows neither exists.
- [ ] Old names: `claude-create x` prints the notice and creates `x`; `claude-accounts delete x`.
- [ ] Fact 8 of the token design: on a browser-login profile idle past its 5-hour window, read `five_hour.resets_at` from the usage endpoint, send one ping with that profile's access token, and read it again. Record in the design whether a ping opens a window.
