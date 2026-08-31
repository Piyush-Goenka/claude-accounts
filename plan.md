# Plan: per-window Claude accounts in VS Code, fully terminal-free

Goal: every VS Code window (project) can use a different Claude Code account.
Everything happens inside VS Code: a status bar item shows the account this
window is using plus its usage, clicking it opens a picker with every account
(email, session/week/per-model limits, login state), and picking one switches
only this window. Setup, switching, and even adding a new account never touch
a terminal.

This plan is based on the reverse engineering already done in this repo's
sessions. Every mechanism referenced below was verified against the real
binaries and the installed extension on this machine.

---

## 1. The facts this design stands on (all verified)

1. **The VS Code extension is the CLI.** The extension
   (`anthropic.claude-code`) ships a byte-identical copy of the Claude Code
   native binary (`resources/native-binary/claude`, md5 matches the terminal
   CLI) and spawns it as a child process per session, speaking JSON over
   stdio.

2. **The binary picks its login from `CLAUDE_CONFIG_DIR`.** Credentials live
   in the macOS Keychain as a generic password with service name
   `Claude Code-credentials` plus, when `CLAUDE_CONFIG_DIR` is set, a suffix
   of `-<first 8 hex of sha256(configDir)>`. This is the exact mechanism the
   `claude-accounts` zsh tool already uses for the terminal (`claude-abhi` is
   just `CLAUDE_CONFIG_DIR=~/.claude-abhi claude`).

3. **The extension has a process wrapper hook.** The setting
   `claudeCode.claudeProcessWrapper` (string, machine scope) makes the
   extension launch that executable INSTEAD of the binary. Decompiled
   `resolveClaudeBinary()` shows the launch shape:

   ```
   pathToClaudeCodeExecutable = <wrapper path>
   executableArgs             = [<real binary path>]   // real binary becomes argv[1]
   env                        = {...process.env, ...claudeCode.environmentVariables}
   ```

   The session's own arguments are appended after. So a wrapper that runs
   `exec "$@"` behaves exactly like the real binary.

4. **The child is spawned with `cwd` = the window's workspace folder.** Proven
   live: the session powering this repo's conversation runs with its cwd set
   to this project folder. Therefore a wrapper can decide things per window
   by looking at its own working directory.

5. **Usage data is fetchable per account.** `GET
   https://api.anthropic.com/api/oauth/usage` with
   `Authorization: Bearer <accessToken>` and header
   `anthropic-beta: oauth-2025-04-20` returns session (5 hour), weekly, and
   scoped per-model weekly limits (the `limits` array carries entries like
   `weekly_scoped` with `scope.model.display_name = "Fable"`). When the live
   fetch fails (the endpoint rate limits per account), Claude Code's own
   snapshot in each profile's `.claude.json` under `cachedUsageUtilization`
   is a reliable fallback.

6. **Why the simpler routes fail.** `claudeCode.environmentVariables` is
   machine scope, so VS Code refuses per-workspace values: it can only switch
   all windows at once. Per-session (per conversation) is impossible without
   forking Anthropic's extension, because every spawn in a window carries
   identical inputs. Per window via the wrapper is the sweet spot.

---

## 2. Architecture overview

Three pieces. One is Anthropic's, untouched. Two are ours.

```
┌─ VS Code window (project A) ─────────────────────────────────────────┐
│                                                                      │
│  Anthropic Claude extension            claude-switch (ours)          │
│  ┌──────────────────────────┐          ┌──────────────────────────┐  │
│  │ chat panel (webview)     │          │ status bar item          │  │
│  │ extension host glue      │          │  "✓ Claude: abhi 63%"    │  │
│  └────────────┬─────────────┘          │ picker (QuickPick)       │  │
│               │ spawns, cwd=projectA   │ tooltip (all accounts)   │  │
│               ▼                        └───────────┬──────────────┘  │
│  ┌──────────────────────────┐                      │ reads/writes    │
│  │ wrapper.sh (ours)        │◄─────────────────────┘                 │
│  │  profile = map[cwd]      │        ┌──────────────────────────┐    │
│  │  export CLAUDE_CONFIG_DIR│──reads─│ map.json                 │    │
│  │  exec real binary        │        │ {"/path/projA": "abhi"}  │    │
│  └────────────┬─────────────┘        └──────────────────────────┘    │
│               ▼                                                      │
│  real claude binary ── reads Keychain item for ~/.claude-abhi        │
│                        (service Claude Code-credentials-<hash>)      │
└──────────────────────────────────────────────────────────────────────┘

A second window on project B goes through the same wrapper, finds a different
map entry (or none, meaning the default account), and authenticates as a
different user at the same time. One VS Code instance, many accounts.
```

### The three components

**A. `wrapper.sh` (generated, never hand-edited).** A tiny zsh script. Reads
`map.json`, matches its `$PWD` against the mapped folders (longest prefix
wins, so a monorepo subfolder inherits its root's mapping), exports
`CLAUDE_CONFIG_DIR` when a mapping exists, then `exec "$@"`. Because it is an
`exec`, it adds zero runtime overhead and is invisible to the child. If the
map is missing or unreadable it execs untouched, so the Claude panel can
never be broken by our layer.

**B. `map.json` (the single source of truth for folder to account).** Plain
JSON: absolute folder path to profile name. Contains no secrets. Lives next
to the wrapper. Both the wrapper (read) and the companion extension
(read/write) use it, and the format stays open so the `claude-accounts`
terminal tool could later read it too.

**C. `claude-switch` companion extension (the only thing the user sees).**
Plain JavaScript, no build step, no dependencies, installed by folder drop
into `~/.vscode/extensions/`. Responsibilities:

- **Bootstrap (first activation):** write `wrapper.sh` into the extension's
  own `globalStorage` directory, `chmod +x` it, create an empty `map.json`,
  and set `claudeCode.claudeProcessWrapper` to the wrapper path through the
  VS Code configuration API (which safely handles JSONC settings files).
  Idempotent on every activation: if the wrapper content is outdated it is
  rewritten; if the setting points elsewhere the user is asked before fixing.
- **Status bar item (per window):** shows the account this window's folder
  maps to and its session usage percent. Color states: normal, warning
  (usage above 80 percent or login expiring within 3 days), error (logged
  out or login expired). Hover tooltip renders a small markdown table of all
  accounts with session, week, per-model weekly, and login countdown.
- **Picker:** a QuickPick listing every account: profile name, email,
  session/week/per-model percents, login state, with the active one marked.
  Selecting writes the map entry for this window's folder and offers a one
  click restart of the Claude panel. A "use default" row removes the entry,
  and an "Add a new account" row starts the new-profile flow.
- **Add a new account (terminal-free onboarding):** prompts for a name,
  creates `~/.claude-<name>` with the same shared symlinks `claude-create`
  makes (projects, history.jsonl, settings.json, CLAUDE.md, skills,
  plugins), maps the current folder to it, restarts the panel, and tells the
  user to run /login inside the Claude panel, which drives Anthropic's own
  browser OAuth flow and stores the credential in the profile's Keychain
  item. No shell at any point.

---

## 3. Data flows in detail

### Spawn flow (how a window gets its account)

1. User opens the Claude panel in a window whose folder is `/path/projA`.
2. Anthropic's extension resolves the binary; because
   `claudeProcessWrapper` is set, it spawns
   `wrapper.sh <realBinary> <session args...>` with `cwd=/path/projA`.
3. The wrapper matches `/path/projA` in `map.json`, finds `abhi`, exports
   `CLAUDE_CONFIG_DIR=$HOME/.claude-abhi`, and execs the real binary.
4. The binary hashes that dir, opens Keychain item
   `Claude Code-credentials-<hash>`, and the whole session (API calls, token
   refresh, /login, /usage) runs as abhi. Unmapped folders skip step 3's
   export and run as the default account.

### Switch flow (what a click does)

1. Picker selection writes `{"/path/projA": "stair"}` into `map.json`.
2. The status bar updates immediately (it reads the map, not the running
   process).
3. A toast offers "Restart Claude panel"; the restart makes the next spawn go
   through the wrapper again and come up as the new account. Other windows
   are untouched because their folders map independently.

### Account and usage data (what fills the picker and tooltip)

For each profile (default plus every `~/.claude-*` dir, excluding non-account
dirs like `claude-science`):

1. Email and identity from the profile's `.claude.json` (`oauthAccount`).
2. Login state and expiry from the Keychain blob (`claudeAiOauth.expiresAt`,
   `refreshTokenExpiresAt`), read with
   `security find-generic-password -a <user> -w -s <service>` via Node
   `child_process`.
3. Usage from the live endpoint (parallel fetches, short timeout), falling
   back to that profile's `cachedUsageUtilization` snapshot on any failure,
   the same live-then-cache strategy `claude-accounts` uses.
4. Refresh cadence: on picker open always; status bar number every 5 minutes
   and on window focus. In-memory cache between refreshes so the endpoint's
   per-account rate limit (observed HTTP 429) is never a visible problem.

---

## 4. File layout

```
claude-accounts/                        (this repo)
├── claude-accounts.zsh                 existing terminal tool (unchanged)
├── vscode-claude-switch/               NEW: the companion extension
│   ├── package.json                    manifest: activation, commands, no deps
│   ├── extension.js                    all logic (~300 lines plain JS)
│   └── wrapper.template.sh             wrapper source, copied at bootstrap
└── plan.md                             this document

~/Library/Application Support/Code/User/globalStorage/<claude-switch>/
├── wrapper.sh                          generated at bootstrap, executable
└── map.json                            {"/abs/project/path": "profileName"}
```

Install for personal use: copy or symlink `vscode-claude-switch/` into
`~/.vscode/extensions/`, reload once. No marketplace, no vsce packaging
needed (a `.vsix` can be added later if wanted).

---

## 5. Edge cases and honest limits

- **Per session is out of scope permanently:** all sessions in one window
  share the window's account. Per window is the granularity.
- **No workspace folder** (untitled window): wrapper finds no match, default
  account, status bar says so.
- **Multi-root workspaces:** use the first workspace folder for both the map
  lookup and the status bar; document this.
- **Path forms:** store map keys as absolute, symlink-resolved, NFC
  normalized paths; the wrapper normalizes `$PWD` the same way before
  matching. Longest-prefix matching covers subfolders.
- **Anthropic extension updates:** the wrapper contract (`argv[1]` is the
  real binary) is an undocumented internal; bootstrap therefore verifies on
  each activation that the spawned layout still holds (cheap sanity check:
  the setting exists and our wrapper file is intact) and the wrapper's
  fail-open `exec "$@"` means the worst case is "everything works but as the
  default account".
- **Permission mode nuance:** the decompiled code sets
  `resolvePermissionModeInCli` to false when a wrapper is configured. Watch
  for permission-mode differences during Phase 1 validation; if defaults
  shift, mirror the expected mode explicitly in the map or wrapper env.
- **UI label mismatch:** Anthropic's own status fallback reads the extension
  host's env, so its account label can briefly show the default email while
  the child genuinely runs as the mapped account. Cosmetic; our status bar is
  the truthful indicator.
- **Keychain prompts:** the first `security` read per profile may pop a
  Keychain permission dialog, same as the terminal tool. One-time allow.
- **Uninstall:** a `Claude Switch: Uninstall` command unsets
  `claudeProcessWrapper` (only if it points at our wrapper), removes the
  generated files, and leaves every profile and login untouched.
- **Security posture:** the extension never writes tokens anywhere, never
  logs them, and `map.json` holds only folder-to-name pairs. All credential
  handling stays where it already lives: the Keychain and the Claude binary.

---

## 6. Implementation phases

**Phase 0: validate the wrapper contract (half an hour).** Point
`claudeProcessWrapper` at a throwaway script that logs its argv, cwd, and env
to a file and execs through. Open two project windows, confirm argv[1] is the
real binary, cwd is the workspace folder, and sessions behave identically.
This de-risks the one undocumented assumption before any real code.

**Phase 1: wrapper plus map, hand-edited (the mechanism).** Write the real
wrapper, create `map.json` manually mapping one test folder to a secondary
profile, set the setting, restart the panel, and verify with /status inside
the panel that the session is authenticated as the mapped account while
another window stays on default. Exit criteria: two windows, two accounts,
simultaneously.

**Phase 2: the extension skeleton (bootstrap plus switching).** Manifest,
activation, bootstrap (wrapper write, setting set, map create), status bar
item showing the mapped account name, QuickPick listing profiles from disk,
selection writes the map and offers the panel restart. No usage data yet.

**Phase 3: account intelligence.** Keychain reads for login state and
expiry countdown, usage fetch with cached fallback, percents in the picker
rows, the markdown hover tooltip, color states, refresh cadence.

**Phase 4: polish.** "Add a new account" flow, "use default" row, uninstall
command, README section in this repo, and a final pass over the edge cases
above with a testing checklist (fresh machine simulation: delete generated
files and re-bootstrap; JSONC settings; profile deleted while mapped; map
entry for a folder that no longer exists).

Each phase is independently verifiable and the system degrades gracefully at
every stage: if development stops after Phase 1 the mechanism still works via
a hand-edited map.

---

## 7. What stays out of scope

- Forking or patching Anthropic's extension or binary. Everything rides on
  public extension settings and observable behavior.
- Windows and Linux (Keychain and paths are macOS-specific here, matching
  the existing claude-accounts tool).
- Syncing map or settings across machines.
- Automating /login itself: interactive browser auth is the security
  boundary and remains manual, one time per new account.
