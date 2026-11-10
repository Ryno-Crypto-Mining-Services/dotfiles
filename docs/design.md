# Design and safety

## Deliberately small defaults

This repository owns interactive developer preferences, not project runtimes, authorization, provisioning, or production workflows. It adds a few shell aliases/functions, a `PATH` entry for this checkout, and a narrow Git include. It does not configure identities, credentials, signing, SSH, hooks, pushes, cloud accounts, or operational tools. Shell startup is interactive-only, quiet, and performs no network, package, project-code, or filesystem-creation work.

The installer has no network or package dependency. Bash and Git are used for setup; standard local utilities handle file staging. This keeps Codespaces and workstation setup explicit and limits changes to managed user configuration.

## Managed content, ownership, and backups

`install.sh` resolves its own checkout and manages exact marked source/include blocks in `~/.bashrc`, an existing `~/.gitconfig` (or the XDG global config when that file does not exist), and optionally `~/.zshrc`. It records the owning absolute checkout, Git config path, Zsh activation, and whether it added a shared global excludes path in `~/.local/state/terrahash-dotfiles/owner`. State, lock, and backup directories are private. State is not a deployment database; it only prevents silent checkout takeover and allows the Git block to be reconstructed exactly for removal.

Before each changed existing file is replaced, a private, timestamped full-file backup is kept in `~/.local/state/terrahash-dotfiles/backups/`. Writes use same-directory temporary files and rename. Re-runs do not back up unchanged files. The `mkdir` lock serializes actual install/uninstall operations; a stale lock is not removed automatically and must be cleared manually only after confirming no operation is active.

Malformed, duplicate, or edited managed markers cause an error rather than guessed cleanup. Uninstall removes only exact managed blocks, backs up files it changes, retains backups, and leaves unrelated edits in place. It never restores an old whole-file backup. If state is missing while markers remain, ownership cannot be proven and manual resolution is required.

Startup-file symlinks are refused for Bash, Zsh, and Git configuration. This avoids silently modifying a symlink target; move or resolve the link manually before installing. The checkout must remain at its installed path. A different checkout cannot retarget the managed references; uninstall from the owning checkout before switching.

## Git precedence

The include contains only `st`, `df`, and bounded `lg` aliases. The managed include block is placed before existing entries in the selected global config; personal values in that file remain authoritative. User identity and credential configuration are not written. If a global `core.excludesFile` already exists, it is preserved; otherwise this installer may set it to this checkout’s small `git/ignore` file. That path remains tied to the checkout. The installer refuses a custom `GIT_CONFIG_GLOBAL` location rather than changing a config file it cannot reliably target.

Git may also read configuration from XDG or system locations; precedence can depend on the user's Git setup. Inspect `git config --show-origin --get <key>` when resolving a personal override. Do not assume the shared include provides an authorization boundary.

## Boundaries and future decisions

Project tool versions, services, and reproducible dependencies belong in each project’s devcontainer/configuration. Infrastructure automation belongs in its dedicated repository. Dotfiles do not enforce tool permissions, tenant isolation, or production access control.

Known limitations: local validation is Linux-only unless a macOS runner has executed CI; Zsh-specific runtime behavior is skipped when Zsh is unavailable. Bash 3.2 and macOS portability are targeted but not established by Linux tests alone. `PATH` cannot represent a checkout path containing a colon, so installation rejects that case. No license was selected; the repository owner must decide.
