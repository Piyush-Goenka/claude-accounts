# Changelog

## 1.0.0 (2026-07-11)

Initial release.

- `claude-create <name>`: isolated profile (own login) sharing history/settings/skills via symlinks
- `claude-delete <name>`: removes profile dir + its Keychain credential (computed via the hashed service name)
- `claude-accounts`: live-generated JSON registry (profile, dir, keychain item, account email, login state)
- `claude-accounts-update`: manual self-update from GitHub Releases
- Auto-update-on-invoke: daily throttled version check before any command runs; offline-safe; syntax-checks downloads; keeps `.bak` for rollback
- Dynamic aliases: `claude-<name>` generated from existing `~/.claude-*` dirs at shell startup, zero state files

## 1.0.1 (2026-07-11)

Added a few sanity checks and more good UX.

## 1.1.0 (2026-08-20)

- `claude-accounts` is now a colorful bar-graph table with live usage per
  account: session (5-hour) and weekly utilization bars (green/yellow/red by
  load) with reset times, pulled from Anthropic's `/api/oauth/usage` endpoint.
  Per-model weekly columns (Fable, Opus, Sonnet, anything the API reports as a
  scoped weekly limit) appear automatically when those limits exist. When a
  live fetch fails (rate limit, offline), it falls back to the snapshot Claude
  Code itself keeps in each profile's .claude.json. The grid auto-shrinks to
  fit narrow terminals (shorter bars, then no reset times, then percent-only,
  then truncated emails and compact labels).
  Colors disable when piped or with NO_COLOR. Old JSON output via `--json`.
- Shows login expiry: days until each account's refresh token expires, with a
  "run /login" nudge at 3 days or less (matches Claude Code's own warning).
- Excludes non-account `~/.claude-*` dirs (currently `science`, the Claude
  research beta) from aliases, the registry, and create/delete.
- Auto-update only runs when the published release is strictly newer, so a
  locally newer copy is never downgraded.
- All commands print in a consistent Claude-palette style (aligned ✓/·/✗ rows,
  no raw paths). Uninstall now removes every profile except the default
  account, then the tool.
## 1.2.0 (2026-08-24)

Usage is now live for every account, not just the one you last ran.

- An OAuth access token lives about 8 hours and the `claude` binary only renews
  the one belonging to the profile you actually launch. Every other profile's
  token was expired, so the usage call 401'd and the table silently showed the
  stale snapshot from that profile's `.claude.json`, which is why numbers only
  moved after you started that account. `claude-accounts` now renews expired
  access tokens itself against the OAuth token endpoint and writes the rotated
  credential pair back to that profile's Keychain item. Refresh happens only
  when the token is expired (60s skew), plus one retry if the usage call comes
  back 401/403.
- The cached snapshot in `.claude.json` stays as the fallback for when a refresh
  or the usage call fails, rendered exactly as before.
- The Keychain write passes the credential hex-encoded via `-X`, which keeps the
  plaintext out of the process argument list and, unlike prompting for it on
  stdin, is not capped at 128 bytes (that cap silently truncates and destroys a
  real credential). It preserves the item's existing `acct` attribute and reads
  the value back to verify it; a failed write-back warns loudly on stderr, since
  the server-side rotation has already invalidated the old refresh token.
- `--json` gains `stale` and `usageFetchedAtMs` per account.

## 2.0.2 (2026-08-28)

Fixes the token refresh, which never actually worked against the real endpoint.

- The refresh request carried curl's default User-Agent, and the token endpoint
  answers those with a blanket `429 rate_limit_error` before it ever evaluates
  the grant. Every refresh failed, so `abhi` and `dhruv` silently fell back to
  their cached snapshot the moment their tokens expired: the exact bug 2.0.1 was
  meant to fix. Verified A/B/A against the live endpoint with an invalid grant:
  claude-cli User-Agent gives `400 invalid_grant`, curl's default gives `429`.
  The request now sends a CLI-shaped User-Agent.
- A failed refresh is no longer silent. It prints one stderr line per affected
  profile naming the HTTP status, e.g.
  `abhi: token refresh failed (HTTP 429, rate_limit_error), showing cached usage`.
  The table itself is unchanged. Warnings now also print in `--json` mode.
- The version constant said `1.2.0` while the released tag was `v2.0.1`, which
  would have made the daily auto-update re-download the same release forever
  once the release asset is reachable. Constant now tracks the tag.
