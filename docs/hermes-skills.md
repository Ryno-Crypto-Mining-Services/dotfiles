# Hermes skills (opt-in pinned inventory)

This checkout can install the same reviewed, pinned agent skills used for Cursor
into Hermes Agent’s personal skills library:

```text
${HERMES_HOME:-$HOME/.hermes}/skills/<skill-name>/
```

Hermes discovers `SKILL.md` trees under that directory (including nested
category layouts used by bundled skills). This installer places flat skill
directories at the skills root, matching the in-repo `agent-skills/vendor/`
layout.

The mechanism is offline and opt-in. It is separate from `./install.sh` and from
`hermes skills` / the Hermes skills hub. Repository storage alone does not sync
or publish skills to a remote Hermes profile.

## Canonical source

`agent-skills/sources.json` is the shared installable inventory. Vendored
payloads live under:

```text
agent-skills/vendor/<upstream-id>/<skill-name>/
```

Selection, pins, licenses, and integrity rules are documented in
[Cursor skills](cursor-skills.md). This Hermes path installs that same
inventory; it does not invent proprietary skill content.

## Commands

```sh
scripts/install-hermes-skills.sh --help
scripts/install-hermes-skills.sh --dry-run
scripts/install-hermes-skills.sh
```

Optional environment:

| Variable | Effect |
|----------|--------|
| `HERMES_HOME` | Absolute Hermes home directory; skills install under `$HERMES_HOME/skills`. When unset, `$HOME/.hermes` is used. |
| `HOME` | Required absolute writable home directory. |
| `XDG_STATE_HOME` | Ownership/backup state root (default `$HOME/.local/state`). |

Requirements: Bash and Python 3 (standard library only). The installer does not
use the network, package managers, `hermes` CLI, `sudo`, or Git remote
operations.

## Ownership, updates, backups, and recovery

Ownership state is stored under:

```text
${XDG_STATE_HOME:-$HOME/.local/state}/terrahash-dotfiles/hermes-skills/
```

That tree is separate from the baseline dotfiles `owner` record and from the
Cursor skills state directory. Behavior matches the Cursor installer:

- Missing destination: install an ordinary copy.
- Existing destination without ownership state: fail closed (no adoption).
- Managed destination matching recorded state and desired content: no-op.
- Managed destination unchanged on disk, with a newer vendored payload: update
  on an explicit installer run.
- Local modifications, extra/missing files, or mode changes: stop.
- Skill removed from the manifest: report retention; do not delete the
  destination or discard ownership.
- There is no `--force` and no automatic uninstall/prune in this change.

Ordinary directory copies are used (not symlinks) so ownership checks and
idempotent updates stay reliable beside Hermes’ own bundled/hub skill trees.
Unrelated skills under the Hermes skills root—including Hermes bundled skills
and hub installs—are left untouched.

Backups of replaced managed skill directories are kept under the hermes-skills
state `backups/` directory. Writes use staging directories and rename. An
incomplete marker named `.<skill>.terrahash-incomplete` beside the skills root
means an interrupted install; inspect and remove that marker (and any partial
tree) before retrying. A held `lock/` directory blocks concurrent runs and is
not removed automatically.

## Boundaries

- Skills installation does not configure Hermes credentials, profiles, MCP, or
  hub trust settings.
- The installer does not invoke `hermes skills`, contact skill registries, or
  modify `.bundled_manifest`.
- Unrelated skills under `${HERMES_HOME:-$HOME/.hermes}/skills/` are left
  untouched.
- Keep the checkout in place after install: re-run this script after updating
  the vendored inventory to refresh managed skills.
