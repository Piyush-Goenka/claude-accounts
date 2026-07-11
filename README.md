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

Then restart your terminal.

## Usage

```bash
claude-create mohan     # create profile → prints next steps
claude-mohan            # launch it → run /login once
claude-accounts         # JSON registry: which profile = which account, logged in or not
claude-delete mohan     # remove profile
```

**First login tip:** your browser is probably already signed into claude.ai as
your main account. When the login page opens, pick **"use a different account"**
or copy the URL into an **incognito window**, then sign in with the second
account's credentials.

## Updates

You never have to think about updates. Every command checks for a newer release
(at most once per day, 3-second network cap, offline never blocks) and updates
itself **before** running. Manual check: `claude-accounts-update`.

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/Piyush-Goenka/claude-accounts/main/uninstall.sh | bash
```

Removes the tool only; run `claude-delete <name>` for each profile first if you
also want those logins gone.

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
