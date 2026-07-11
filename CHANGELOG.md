# Changelog

## 1.0.0 (2026-07-11)

Initial release.

- `claude-create <name>`: isolated profile (own login) sharing history/settings/skills via symlinks
- `claude-delete <name>`: removes profile dir + its Keychain credential (computed via the hashed service name)
- `claude-accounts`: live-generated JSON registry (profile, dir, keychain item, account email, login state)
- `claude-accounts-update`: manual self-update from GitHub Releases
- Auto-update-on-invoke: daily throttled version check before any command runs; offline-safe; syntax-checks downloads; keeps `.bak` for rollback
- Dynamic aliases: `claude-<name>` generated from existing `~/.claude-*` dirs at shell startup, zero state files

# 1.0.1 (2026-07-11)

Added a few sanity checks and more good UX.