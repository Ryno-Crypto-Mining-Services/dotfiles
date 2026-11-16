# Cursor skills (opt-in pinned inventory)

This checkout can carry reviewed, pinned copies of selected agent skills and
install ordinary directory copies into Cursor’s personal skills directory:

```text
$HOME/.cursor/skills/<skill-name>/
```

The mechanism is offline and opt-in. It is separate from `./install.sh` and does
not change baseline shell or Git setup. Repository storage alone does not sync
skills to Cloud Agents; personal Cloud Agent sync, when available, is enabled
separately in the Cursor Desktop UI (exact labels may change).

## What is vendored and why

`agent-skills/sources.json` is the installable inventory. Skills are copied under:

```text
agent-skills/vendor/<upstream-id>/<skill-name>/
```

### In scope

1. [`langchain-ai/skills-benchmarks`](https://github.com/langchain-ai/skills-benchmarks)
   — source of the requested starter set (`ecosystem-primer`, `langchain-*`,
   `langgraph-*`, `deep-agents-*`) from `skills/main/` and
   `skills/benchmarks/ecosystem-primer`.
2. [`langchain-ai/langchain-skills`](https://github.com/langchain-ai/langchain-skills)
   — inspected at the pinned `main` commit; requested starter names are absent
   there (plugin skills only). Nothing is vendored from this upstream for those
   names.
3. [`davila7/claude-code-templates`](https://github.com/davila7/claude-code-templates)
   skill paths under `cli-tool/components/skills/ai-research/`:
   - `agents-langchain`
   - `langgraph`
   - `langfuse`
4. [`NousResearch/hermes-agent`](https://github.com/NousResearch/hermes-agent)
   at tag `v0.23.1` — development-workflow skills reviewed for TerraHash
   Autopilot work, under `skills/<category>/<name>` and
   `optional-skills/<category>/<name>`:
   - `codebase-inspection`
   - `requesting-code-review`
   - `simplify-code`
   - `spike`
   - `dogfood`
   - `python-debugpy`
   - `sdlc-review`
   - `grounded-citations`
   - `blocked-page-recovery`
   - `claude-code`
   - `codex`
   - `document-to-action-items`

### Out of scope

- [`langchain-ai/langsmith-skills`](https://github.com/langchain-ai/langsmith-skills)
  and LangSmith tracing plugins (not vendored).
- LangSmith skills under `skills-benchmarks` `skills/main/langsmith-*`
  (intentionally omitted).
- Locally curated profile-library variants of `hermes-agent` skills
  (`github`, `systematic-debugging`, `test-driven-development`,
  `hermes-agent`). Their library copies differ from the upstream payloads, so
  vendoring upstream bytes would put two different same-named skills in one
  Hermes library, where the loader cannot resolve them. Only upstream-verbatim
  payloads are carried.

## Pinned sources and selection policy

See `upstreams` and `skills` in `agent-skills/sources.json` for repository URLs,
full commit SHAs, and per-file SHA-256 digests.

Selection rules:

- Prefer exact requested names when present at an inspected pin.
- Also vendor explicitly named path trees when those directories exist and
  licensing permits.
- Missing requested names are recorded; plugin skills from langchain-skills are
  not used as silent substitutes.
- Payloads are upstream-verbatim at the pinned commit. A skill whose local
  library copy has been edited is not vendored, because an installed copy and
  the library copy of one name must stay byte-identical for the loader to
  resolve the name.
- Integrity validation fails closed on missing, unexpected, or mismatched files
  and on executable-mode mismatches.

## License and attribution

| Upstream | License at pin |
|----------|----------------|
| skills-benchmarks | MIT (`LICENSE`, Copyright LangChain, Inc.) |
| langchain-skills | MIT (`LICENSE`, Copyright LangChain, Inc.) |
| claude-code-templates | MIT (`LICENSE`, Copyright 2025 Daniel (San) Ávila) |
| hermes-agent | MIT (`LICENSE`, Copyright (c) 2025 Nous Research) |

Vendored copies retain upstream `LICENSE` / `NOTICE` files under each
`agent-skills/vendor/<upstream-id>/` tree. The `langgraph` and `langfuse` skill
frontmatter cite `vibeship-spawner-skills (Apache 2.0)` as source metadata;
redistribute with that attribution intact.

No credentials, API keys, or authentication state belong in the manifest or
payload.

## Commands

```sh
scripts/install-cursor-skills.sh --help
scripts/install-cursor-skills.sh --dry-run
scripts/install-cursor-skills.sh
```

Requirements: Bash and Python 3 (standard library only). The installer does not
use the network, package managers, `npx`, `sudo`, or Git remote operations.

The same inventory can be installed into Hermes Agent’s skills library with
`scripts/install-hermes-skills.sh` (see [Hermes skills](hermes-skills.md)).

## Ownership, updates, backups, and recovery

Ownership state is stored under:

```text
${XDG_STATE_HOME:-$HOME/.local/state}/terrahash-dotfiles/cursor-skills/
```

That tree is separate from the baseline dotfiles `owner` record. Behavior:

- Missing destination: install an ordinary copy.
- Existing destination without ownership state: fail closed (no adoption).
- Managed destination matching recorded state and desired content: no-op.
- Managed destination unchanged on disk, with a newer vendored payload: update
  on an explicit installer run.
- Local modifications, extra/missing files, or mode changes: stop.
- Skill removed from the manifest: report retention; do not delete the
  destination or discard ownership.
- There is no `--force` and no automatic uninstall/prune in this change.

Backups of replaced managed skill directories are kept under the cursor-skills
state `backups/` directory. Writes use staging directories and rename. An
incomplete marker named `.<skill>.terrahash-incomplete` beside
`~/.cursor/skills/` means an interrupted install; inspect and remove that
marker (and any partial tree) before retrying. A held `lock/` directory blocks
concurrent runs and is not removed automatically.

Per-skill activation is atomic via directory rename where the filesystem
allows. The installer does not claim whole-batch atomicity across multiple
skills.

## Refreshing upstream content manually

1. Inspect each upstream default branch and resolve a full commit SHA.
2. Confirm license terms still permit redistribution.
3. Copy only selected skill directories into `agent-skills/vendor/<upstream-id>/`.
4. Rebuild `agent-skills/sources.json` with deterministic per-file SHA-256
   digests and executable flags (`schema_version` 2, multi-`upstreams`).
5. Run `scripts/install-cursor-skills.sh --dry-run`, then install.
6. Review the diff; do not pull credentials or unrelated repository content.

## Boundaries

- Skills installation does not enable LangSmith tracing or configure credentials.
- The installer does not read or write `mcp.json`, hooks, plugins, or API keys.
- Unrelated skills under `~/.cursor/skills/` are left untouched.
- Personal Cloud Agent sync remains a separate Cursor UI action.
