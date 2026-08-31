# claude-accounts

Run **multiple Claude Code accounts side by side on one Mac.**

Each account gets an isolated profile (its own login) while sharing your chat
history, sessions, settings, and skills, so switching accounts is just typing a
different command:

```
claude          # your main account
claude-mohan    # a second account
claude-rohan    # a third...
```

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/Piyush-Goenka/claude-accounts/main/install.sh | bash
```

Installs the terminal tool and, when VS Code is present, the claude-switch
extension (the per-window account switcher) in one go. Then restart your
terminal and reload any open VS Code windows.

## Usage

```bash
claude-create mohan     # create profile → prints next steps
claude-mohan            # launch it → run /login once
claude-accounts         # colorful table of all accounts: live usage bars + login state
claude-delete mohan     # remove profile
```

`claude-accounts` shows, per account, the session (5-hour) and weekly usage in
percent with reset times (fetched live from Anthropic's usage endpoint, the same
one `/usage` inside Claude Code hits) and the login state, including how many
days until the login (refresh token) expires. Add `--json` for machine-readable
output. Dirs like `~/.claude-science` (the Claude research beta) that are not
account profiles are excluded automatically.

The numbers are live for every account, not only the one you last used. An
access token lives about 8 hours and Claude Code only renews the one belonging
to the profile it launches, so `claude-accounts` renews expired tokens itself
and writes the rotated credential back to that profile's Keychain item. If a
refresh or the usage call fails, it falls back to the last snapshot Claude Code
recorded in that profile's `.claude.json`.

**Logins expire when stale.** Anthropic's refresh tokens have their own expiry
(30 days by default). Using an account regularly usually renews it, but once a
profile shows only a few days left (Claude Code itself warns at 3 days or less),
run `/login` in that profile to mint a fresh one. `claude-accounts` shows the
countdown for every account so no login dies silently.

**First login tip:** your browser is probably already signed into claude.ai as
your main account. When the login page opens, pick **"use a different account"**
or copy the URL into an **incognito window**, then sign in with the second
account's credentials.

## VS Code: per-window accounts (claude-switch)

The repo also ships a small companion VS Code extension in
`vscode-claude-switch/`. It puts a **Claude: <account>** item in the status
bar of every window: it shows which account that window's project uses plus
its live usage, hovering shows all accounts, and clicking opens a picker to
switch **just that window** (or add a brand-new account, then /login inside
the Claude panel). No terminal involved at any point.

It is installed automatically by the install one-liner above (and kept up to
date with the tool). Working from a checkout, `./install.sh` refreshes it; for
development you can symlink `vscode-claude-switch/` into
`~/.vscode/extensions/` instead so edits apply on every window reload.

How it works: on first activation it registers a tiny wrapper via the Claude
extension's `claudeCode.claudeProcessWrapper` setting. Every Claude panel
spawn runs through the wrapper, which maps the window's project folder to a
profile (`map.json`) and exports `CLAUDE_CONFIG_DIR` before exec'ing the real
binary. Different windows, different accounts, simultaneously. Full design in
[plan.md](plan.md). `Claude Switch: Uninstall` from the command palette
removes the wrapper and mapping cleanly.

## Updates

You never have to think about updates. Every command checks for a newer release
(at most once per day, 3-second network cap, offline never blocks) and updates
itself **before** running. Manual check: `claude-accounts-update`.

The VS Code extension updates ride along: when a newer release is installed,
the extension files are refreshed from the same release (asset
`vscode-claude-switch.tar.gz`), and each VS Code window picks the new code up
on its next reload.

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/Piyush-Goenka/claude-accounts/main/uninstall.sh | bash
```

Removes every profile (dirs + their logins) except your default account, then
removes the tool itself.

## Caveats, honestly

- **macOS only** (soon releasing the updates for linux and windows).
- Every profile's usage is billed to the account logged into it. Only use claude 
  accounts which belong to you, and check Anthropic's terms regarding account
  sharing.
- Not affiliated with Anthropic.

## Contrinbuting Guidelines

For any type of feature request raise a issue.
```bash
Give it a ⭐ if it worked for you.
```

## License

MIT
