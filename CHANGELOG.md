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