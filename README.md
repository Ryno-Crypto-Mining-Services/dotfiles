# TerraHash developer dotfiles

A small, opt-in baseline for Bash, optional Zsh, and shared Git conveniences on GitHub Codespaces and Linux/macOS workstations. This repository manages developer preferences only; it is not a project devcontainer, provisioning system, secrets manager, or production access-control mechanism.

## Install

Keep the checkout in place after installation: managed source references point to its absolute path.

```sh
./install.sh --dry-run
./install.sh
./install.sh --zsh
./uninstall.sh --dry-run
./uninstall.sh
```

The default install integrates Bash and shared Git aliases. Zsh is untouched unless `--zsh` is supplied. Commands do not prompt, require network access, install packages, or use elevated privileges. Installation is repeatable; the installer stops on conflicting checkouts, ambiguous managed markers, and symlinked configuration files. See [design details](docs/design.md) for recovery and limitations.

Existing files are copied to private backups under `~/.local/state/terrahash-dotfiles/backups/` only immediately before an actual change. Uninstall preserves those backups and all unrelated file content. To recover manually, inspect a backup and selectively copy the needed content; do not blindly replace a newer startup or Git config file with an old full-file backup.

## Shell and Git conveniences

Interactive shells gain `ll` (detailed listing), `gs` (Git status), `gd` (Git diff), `gl` (last ten commits), and `croot` (change to the current worktree root). The shell adds this checkout's `bin` directory to `PATH` once. Startup is quiet and does not create files or run project code.

An optional private override can be placed at `~/.config/terrahash-dotfiles/local.sh`. It is trusted executable shell code: never source it from an untrusted repository, and do not place secrets in this repository. The installer does not create or populate the override.

The read-only `terrahash-doctor` summarizes coarse platform details, baseline tools, installation status, worktree presence, and optional developer tools. Missing optional tools are informational. It does not inspect remotes, credentials, accounts, service endpoints, or cluster state.

Git aliases are deliberately small (`st`, `df`, `lg`). The installer prepends a managed include to an existing `~/.gitconfig`, or to the XDG global config (`$XDG_CONFIG_HOME/git/config`, normally `~/.config/git/config`) when `~/.gitconfig` does not exist. Existing entries follow the managed block and remain authoritative for overlaps. It sets `core.excludesFile` only when no global excludes file is already configured. If you already configure a global excludes file, it is preserved.

## Checks and validation

Run the isolated tests with:

```sh
bash scripts/test.sh
```

The runner uses temporary fake HOME directories and deliberately isolated Git/XDG configuration. CI is configured for Ubuntu and macOS with Bash syntax, ShellCheck, shfmt, and tests; that configuration is not evidence of a CI run. The local environment for this initial implementation is Linux with Bash 5.2, Git 2.56, Python 3.12, and ShellCheck 0.9.0. shfmt and macOS are unavailable locally; see the test output and CI for actual validation status.

## Layout

- `install.sh`, `uninstall.sh`: conservative installation and removal.
- `shell/`: quiet shared shell defaults.
- `git/`: minimal aliases and ignore patterns.
- `bin/terrahash-doctor`: read-only environment summary.
- `scripts/test.sh`: isolated test runner.
- `docs/`: design and Codespaces setup notes.
- `.github/`: contributor instructions and CI.

## Boundaries and maintenance

No automatic environment loading, project execution, package installation, network bootstrap, telemetry, credential configuration, operational commands, or cloud/provider integration is included. This baseline does not provide authorization or tenant isolation. Put reproducible project runtimes and services in each project’s devcontainer/configuration, and infrastructure automation in its dedicated repository.

To update an installation explicitly, review the new checkout and run its `./install.sh` (or `./install.sh --zsh`) from that checkout. A different checkout will not silently take over an existing installation. To switch checkouts, run the old checkout’s `./uninstall.sh` first, then install from the new one.

There is no license file. The repository owner must choose and add a license before granting reuse rights.
