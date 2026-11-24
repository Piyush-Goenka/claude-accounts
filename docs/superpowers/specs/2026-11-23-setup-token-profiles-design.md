# Setup-token profiles for claude-accounts

Size: project
Builds on: `2026-11-23-claude-accounts-subcommands-design.md`. The subcommand
migration lands first; everything here hangs off its dispatcher.

## Intent

Let a named profile log in with a long-lived setup token (from
`claude setup-token`) instead of the browser `/login`, so more accounts can be
added to the existing system. The token is entered once, kept with that
profile, and handed to Claude Code every time the profile is launched, from the
terminal or from VS Code. Token profiles show their session and weekly limits
in the `claude-accounts` table like any other profile.

Why it is worth having: a setup token does not rotate. A browser login is a
rotating refresh token, which is why two machines sharing one login eventually
knock each other out. A token profile has no refresh step at all.

## What testing established

These are measured, not assumed. The design depends on each of them.

1. `claude setup-token` authenticates in the browser and prints the token once,
   to the terminal only. (Owner.)
2. `CLAUDE_CODE_OAUTH_TOKEN=<token> claude` runs Claude Code on that token.
   (Owner.)
3. `GET /api/oauth/usage` with a setup token returns 403
   `oauth_scope_insufficient`: it requires `user:profile`. Browser logins carry
   that scope, setup tokens do not. So the tool's existing usage lookup cannot
   work for a token profile.
4. Claude Code running on a setup token writes neither `oauthAccount` nor
   `cachedUsageUtilization` into the profile's `.claude.json` (seen on two
   profiles run this way). There is no account email and no cached usage to
   read.
5. Claude Code still creates its own Keychain item for such a profile
   (`Claude Code-credentials-<hash>`, holding only `mcpOAuth`). The tool does
   not write to it; `delete` removes it, as it does today.
6. A minimal message returns the limits in its response headers. Request:
   `POST https://api.anthropic.com/v1/messages`, headers
   `Authorization: Bearer <token>`, `anthropic-version: 2023-06-01`,
   `anthropic-beta: oauth-2025-04-20`, `Content-Type: application/json`, body
   `{"model":"claude-haiku-4-5-20251001","max_tokens":1,"messages":[{"role":"user","content":"."}]}`.
   No custom User-Agent and no system prompt. Measured: HTTP 200 in 0.82 s,
   8 input + 1 output tokens. Headers that matter:

   ```
   anthropic-ratelimit-unified-5h-utilization: 0.11     (fraction, 0 to 1)
   anthropic-ratelimit-unified-5h-reset: 1795431000     (epoch seconds)
   anthropic-ratelimit-unified-7d-utilization: 0.01
   anthropic-ratelimit-unified-7d-reset: 1796029200
   ```

   The reset times matched the usage endpoint for the same account. The owner
   confirmed the same request succeeds with a setup token.
7. Those headers cover the 5-hour and 7-day windows only. Per-model weekly
   limits (the WEEK FABLE column) are not in them.
8. Not measured: whether a 429 from an exhausted account carries the same
   headers (Claude Code's own refused-request handling reads this header
   family, so it is expected), and whether a ping on an idle account opens a
   new 5-hour window (expected, since a ping is a real message).
9. zsh implements here-strings and here-documents as temp files (checked on
   this machine: a here-string's stdin is a regular file under
   `/private/tmp`).

## Goals

- Create a named profile that logs in with a setup token.
- Enter the token once, by pasting it at a hidden prompt.
- Launching is unchanged for the user: `claude-<name>` in the terminal, the
  mapped account in VS Code.
- The table shows SESSION and WEEK for token profiles, fetched by a
  health-check ping, and shows whether the token still works.
- Replace a profile's token when it expires or is revoked.
- Deleting a profile, or uninstalling the tool, removes its token.

## Non-goals

- The default account (`~/.claude`). Dropped by the owner: it has no launcher
  to attach a token to.
- Setting up a token profile from VS Code. Decided by the owner: it is created
  in the terminal, and the VS Code picker lists it afterwards.
- Pings from VS Code. Decided by the owner: only the terminal table pings.
- Converting a browser-login profile into a token profile, or back. Delete and
  recreate. A profile carrying both kinds of login is not supported; the
  presence of the token file decides what the tool shows.
- Per-model weekly numbers for token profiles (fact 7).
- The account email for token profiles (fact 4). A label typed by the user
  stands in.
- Running `claude setup-token` for the user. Its output goes to their terminal
  and they copy it.

## Anti-goals

Ways this fails even if it technically works:

- The token ends up anywhere except its one file: in shell history, `alias`
  output, a command line (visible in `ps`), a temp file, a log, the ping
  cache, or the interactive shell's own environment.
- The token file is ever readable by anyone but its owner.
- Anything changes for browser-login profiles: their aliases, table rows,
  token refresh, or VS Code behaviour.
- A message is sent to an account without the user having just asked for the
  table, or more than once per 5 minutes in normal use.
- The table calls a token profile logged in when its token is rejected, or
  logged out when it works.

## Constraints

- macOS, zsh, Python 3 standard library and curl only. No new dependencies.
- The VS Code wrapper must stay fail-open: on any problem it launches Claude
  untouched. It writes a breadcrumb log today; the token must not reach it.
- Because of fact 9, the token never travels through a here-string or a
  here-document. It reaches a child process through that process's
  environment or a pipe. For curl that means the bearer header is supplied on
  standard input (`-H @-`), not on the command line.
- The ping is inference sent by this tool, not by Claude Code, on a
  subscription login. As the designer understands Anthropic's terms, such
  logins are meant for Claude Code and claude.ai. The owner was told this and
  chose the ping; sending it only when the table is drawn, at 1 token, with a
  5-minute floor, keeps its footprint as small as it can be.
- The ping model is a constant in the script. When that model is retired the
  ping starts failing and the constant has to be updated.
- End-to-end acceptance needs a real setup token, which only the owner can
  mint. Any valid OAuth access token passes the ping, so the ping and cache
  paths can be exercised without one.

## Approaches

### Where the token lives

**A dotfile in the profile folder.** Chosen by the owner, who proposed it at
the start. The profile folder is self-contained: the launcher and the VS Code
wrapper read one file, the tool adds no Keychain entry of its own, and
deleting the folder deletes the token. What it costs: a year-long,
non-rotating credential sits in a plain file, protected by file permissions
and nothing else, and it travels with any backup or copy of that folder.

**The Keychain, with a marker file in the profile folder.** The designer's
recommendation, not taken. It keeps the token out of plain files and backups.
What it costs: a second Keychain entry per token profile next to Claude Code's
own, and secret handling through the `security` CLI in four places (launcher,
table, wrapper, extension), each needing a "no token" state.

**The Keychain only.** Considered and dropped before either of the above: the
profile folder would then say nothing about how the profile logs in, so every
launch and every VS Code spawn would need a Keychain lookup just to find out.

### How the table gets limits for a token profile

**Health-check ping.** Chosen; the owner's idea. One 1-token message per token
profile when the table is drawn, limits read from the response headers
(fact 6). Current as of that moment, about 9 tokens and under a second, and it
doubles as the check that the token still works.

**Status line snapshot.** Claude Code already hands these numbers to the
user's status line script on stdin; the script could save them per profile for
the table to read. Zero requests, and it stays entirely inside Claude Code.
Not chosen: it goes stale whenever the account is used somewhere the script
does not run (the VS Code panel, another machine, claude.ai), it is empty
until the profile's first session, and the script is the owner's personal
file, not something this tool ships.

**Snapshot first, ping when stale.** Fewest pings. Not chosen: two mechanisms
to keep working in order to save a few tokens.

Dead ends, for the record: the usage endpoint (fact 3), Claude Code's own
cached usage (fact 4), and running `claude -p` headless to read its
`rate_limit_event` (reports one window per event, and costs seconds plus a
full system prompt per profile).

### Where pings come from

**The terminal table only.** Chosen by the owner. A message is sent only when
the user draws the table. VS Code shows what the table last saw.

**Also when the VS Code picker is opened**, and **on every background refresh
of the extension** (every 5 minutes per open window, for every token
profile). Not chosen. The second would have kept a session running on every
token account whenever VS Code was open, if a ping opens a 5-hour window.

## The design

### What is stored

Everything lives in the profile folder, plus one cache file.

- **Token:** `~/.claude-<name>/.setup-token`, mode 600 from the moment it is
  created, containing the token and a trailing newline and nothing else. The
  presence of this file is the single test for "this is a token profile"; an
  empty or unreadable one is a token profile with no token.
- **Label:** `~/.claude-<name>/.claude-accounts.json`, mode 600, containing
  `{"label": "<text>"}`. Optional; absent or empty means no label. No secret.
- **Ping cache:** `~/.cache/claude-accounts/ping-<name>.json`. Contents:
  `{"ts": <epoch seconds>, "http": <status>, "five_hour": {"utilization":
  <percent>, "resets_at": "<ISO 8601>"}, "seven_day": {...}}`. No secret.
  Written by the table, read by the table and by the VS Code extension.

### Commands

On top of the subcommand surface:

```
claude-accounts create <name> --token   # new profile that logs in with a setup token
claude-accounts token <name>            # replace the token of a token profile
```

`create <name> --token` does what `create` does today (folder, symlinks,
launcher), then:

```
  next  in another terminal run:  claude setup-token
        sign in as the account you want, then paste the token here

  token: (hidden)
  label for the ACCOUNT column, enter to skip: work max

  ✓ token accepted       session 5% · week 20%
  ✓ profile created      mohan
  ✓ launcher ready       claude-mohan
```

- The token is read with echo off and is never accepted as an argument.
- There is no format check. The ping is the check: the token is pinged before
  anything is saved.
- Ping answers 200 or 429: write the token file and the label, and write the
  ping result to the cache so the first table needs no second ping.
- Ping answers 401 or 403: say the token was rejected, save nothing, and
  remove the folder this run created.
- No answer (network): save nothing, remove the folder this run created, say
  so. A stored token is always one that worked at least once.

`token <name>` runs the same prompt and check on an existing token profile and
replaces the token file on success, leaving the old one in place on failure.
On a profile with no token file it refuses and says why (see non-goals).

### Launching

- **Terminal.** At shell start, a profile with a token file gets a shell
  function named `claude-<name>` instead of the alias; profiles without one
  keep today's alias untouched. The function reads the file at that moment
  and starts Claude with `CLAUDE_CONFIG_DIR` and `CLAUDE_CODE_OAUTH_TOKEN` set
  for that one process only, passing its arguments through. Nothing is
  exported into the shell. If the file is empty or unreadable, it prints one
  line pointing at `claude-accounts token <name>` and does not start Claude.
- **VS Code.** `wrapper.template.sh` gains one step after it exports
  `CLAUDE_CONFIG_DIR`: if that folder has a non-empty token file, export its
  contents as `CLAUDE_CODE_OAUTH_TOKEN`. That is a file test and a read inside
  the shell, with no extra process. Anything else leaves the environment
  alone, which keeps the wrapper fail-open.

### The table

For a profile with a token file:

- ACCOUNT shows the label, or `-`.
- SESSION and WEEK come from the ping cache when it is younger than 300
  seconds, otherwise from a fresh ping, made inside the existing thread pool
  alongside the other profiles' lookups. Header fractions are converted to the
  percent and ISO-time shape the existing table code already consumes, so
  rendering is untouched. Headers are read from any response that carries
  them, including a 429.
- WEEK <MODEL> columns show `-`.
- LOGIN shows `✓ token`. If the last ping answered 401 or 403 it shows
  `✗ token rejected · claude-accounts token <name>`; if the token file is
  empty, `✗ no token · claude-accounts token <name>`. Any other failure (no
  network, a retired ping model) leaves LOGIN at `✓ token` and shows `?` for
  usage, the table's existing sign for "logged in, no data".
- The refresh-token machinery is skipped entirely.

```
PROFILE  ACCOUNT    SESSION               WEEK                    WEEK FABLE  LOGIN
default  <email>    █░░░░░░░░░ 11% 16:20  ░░░░░░░░░░  1% Mon 14:30  ░ 0%       ✓ 28d
mohan    work max   █░░░░░░░░░  5% 18:05  ██░░░░░░░░ 20% Thu 09:00  -          ✓ token
```

There is no flag to force a ping inside the 5 minutes. No locking either: two
tables started in the same instant may both ping, and that is acceptable.

### The VS Code extension

The extension never reads the token and never pings. `accountInfo` treats a
profile with a token file as a token profile: logged in, label in
place of the email, login text `✓ token` (or `✗ token rejected` when the
cache's last status was 401 or 403, or `✗ no token` for an empty file, with
the colouring a logged-out profile gets today). Usage comes from the ping
cache file as the table left it: each window's number is shown with the time
it was taken, and dropped once that window's reset time has passed. With no
cache file there is no usage to show. "Add a new account" is unchanged. The
extension version is bumped.

### Delete and uninstall

`claude-accounts delete <name>` already removes the profile folder, which now
takes the token and label with it, and already removes Claude Code's own
Keychain item. It additionally removes the profile's ping cache file.
`uninstall.sh` additionally removes `~/.cache/claude-accounts/`.

### Docs

Help output lists the two new forms. README gains a short section on token
profiles: how to make one, what they cannot show, that `.setup-token` is a
credential which backups and copies of the profile folder will carry, and a
note to stop exporting `CLAUDE_CODE_OAUTH_TOKEN` by hand once a token is
stored. CHANGELOG gets an `Unreleased` entry.

## Who decided what

| Decision | Whose |
|---|---|
| Token login for named profiles, pasted in, kept per profile, supplied at every launch | Owner |
| Default account out of scope | Owner |
| Must launch correctly from VS Code | Owner |
| Table must show limits; health-check ping is how | Owner |
| Token kept in a dotfile in the profile folder | Owner |
| Only the terminal table pings; VS Code never does | Owner |
| Setting up a token profile from VS Code is out of scope | Owner |
| Command names `create --token` and `token` | Designer |
| Ping before saving; nothing saved unless it answers | Designer |
| Function instead of alias; token scoped to the one process | Designer |
| 5-minute ping floor, no bypass, no locking | Designer |
| Typed label for the ACCOUNT column, in its own small file | Designer |
| VS Code shows the table's last numbers with their time | Designer |

## Left to the builder

- All wording of prompts, errors and help.
- The zsh mechanics of defining one function per token profile at shell start.
- Whether `create --token` pings by calling curl from zsh or by reusing the
  table's Python, within the constraints above.
- Timeouts, and the exact parsing of the headers.
- Accepting `--token` before or after the name.
- Limits on the label (one line, trimmed; the table already truncates).
- How the pure pieces (header parsing, cache age, token-file detection) are
  tested, given the repo has no test harness today.
- Measuring the two open points in fact 8 during the build. A browser-login
  profile that has sat idle past its 5-hour window is enough to see whether a
  ping opens a new one.
