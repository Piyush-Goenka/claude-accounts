# claude-accounts: one entry point with subcommands

Date: 2026-11-23
Size: small change (one script plus docs)

## Intent

Collapse the four separate admin functions into a single `claude-accounts`
command that takes subcommands, because five sibling `claude-*` functions in
the global shell namespace reads as dated and makes the tool's surface look
larger than it is. Drop `--json` at the same time: it is unused.

## Goals

- One entry point for every administrative action.
- Every argument is a subcommand. After `--json` goes there are no modifier
  flags left, so the parser has exactly one kind of thing to recognise.
- `--help` keeps working as a flag, since that is what people type first.
- Existing users are not stranded when the daily auto-update lands.

## Non-goals

- `claude-<name>` launch aliases stay exactly as they are. They are the
  most-typed thing in the tool and are not an admin action.
- The VS Code extension is untouched. It calls `security` directly through
  `child_process` and never shells out to `claude-accounts`.
- No change to what the table shows, how usage is fetched, or the token
  refresh path.

## Anti-goals

Ways this fails even if it technically works:

- `claude-accounts` bare renders any differently than today. That is the
  most-used path and the whole point of the tool.
- Someone's `claude-create` stops working after an unattended auto-update with
  no hint about what replaced it.
- The `warnings` list stops reaching the user when the JSON branch is removed.

## Constraints

- Every installed copy auto-updates daily with no opt-in, so the migration has
  to be survivable without the user reading a release note.
- zsh only. The script is sourced into interactive shells, so every helper
  added to the global namespace is a cost.
- Removing `--json` is a one-way door for anyone scripting against the tool.
  Verified unused inside this repo; accepted as the owner's call.

## Approaches

**A. Pure flags** (`--create mohan`, `--delete mohan`). Exactly as originally
requested. Rejected: it puts actions and modifiers in one namespace, and an
action flag that then takes a positional does not extend cleanly to per-action
options later.

**B. Subcommands for actions.** Chosen. The git/docker/gh shape. `--help`
still works as a flag, and per-action flags compose later without special
cases in the parser.

**C. Accept both spellings permanently.** Dropped: two forms for every command
doubles the help text and the docs for no real gain. The deprecation shims
below are deliberately temporary, which is a different thing.

## The surface

```
claude-accounts                  # table (unchanged)
claude-accounts create <name>
claude-accounts delete <name>
claude-accounts update
claude-accounts help             # --help and -h also accepted
claude-<name>                    # launch, unchanged
```

## How it is built

**Dispatch.** `claude-accounts()` becomes a thin `case` over `$1`. The
auto-update re-entry guard currently repeated in every public function moves
here, so it exists once instead of five times.

**Existing bodies become internal helpers**, renamed and with their own
re-entry guards removed:

| today | becomes |
|---|---|
| `claude-create()` | `_ca_cmd_create()` |
| `claude-delete()` | `_ca_cmd_delete()` |
| `claude-accounts-update()` | `_ca_cmd_update()` |
| `claude-help()` | `_ca_cmd_help()` |
| body of `claude-accounts()` | `_ca_cmd_table()` |

**Removing `--json`.** Delete `as_json` (line 230) and the branch at lines
424-428. Warnings already print again in table mode at line 575, so they keep
reaching the user. The row fields `stale`, `usageFetchedAtMs`, `keychainItem`
and `dir` were read only by the JSON branch and become dead once it goes.
The cached-usage fallback logic itself stays; only the reporting of it goes.

**Deprecation shims, for one release.** `claude-create`, `claude-delete`,
`claude-help` and `claude-accounts-update` stay as one-line forwarders. Each
prints a single dim notice to stderr naming the new form, then calls it.
stderr so the notice never mixes into the table output. They come out in the
release after.

**Unknown input** exits 1 with a message pointing at `claude-accounts help`.
An unrecognised leading `-` is reported as an unknown flag rather than an
unknown subcommand, so a typo'd flag does not produce a confusing message.

**Help text** is rewritten to the new forms, drops `--json`, and still lists
the per-profile `claude-<name>` aliases found on the machine.

## Files touched

- `claude-accounts.zsh`: dispatch, renames, shims, `--json` removal, help
  text, header comment block (lines 12 and 207 both mention `--json`)
- `install.sh:74`: the post-install hint prints `claude-create <name>` today
- `uninstall.sh:18`: a code comment referring to `claude-delete` (cosmetic)
- `README.md`: the quick-reference block, the command mentions, and the
  `--json` sentence at line 38
- `CHANGELOG.md`: an `Unreleased` entry. Historical entries that mention
  `--json` stay as they are; they are a record of past releases.

## Left to the builder

- Exact wording of the deprecation notice and the unknown-input errors.
- Whether `create`/`delete` keep accepting a `claude-` prefixed name the way
  the current functions do via `${1#claude-}`. Keeping it is the default,
  since it costs nothing and matches existing behaviour.
- Ordering of the entries in the rewritten help output.
- Whether to strip the now-dead row fields or leave them computed. Stripping
  is tidier; leaving them costs nothing at runtime.
