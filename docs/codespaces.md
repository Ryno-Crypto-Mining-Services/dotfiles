# GitHub Codespaces setup

GitHub’s current documentation says Codespaces looks for a root setup script in this order, including `install.sh`, and runs dotfiles setup when creating a new codespace. Selecting a dotfiles repository is a per-account preference and applies to new codespaces; changes do not update existing codespaces. See [Personalizing GitHub Codespaces for your account](https://docs.github.com/en/codespaces/setting-your-user-preferences/personalizing-github-codespaces-for-your-account#dotfiles).

1. Create or choose a repository that you own. Review this implementation and its setup script before enabling it; dotfiles scripts can execute arbitrary code.
2. Commit and push this implementation only after the repository owner separately approves those actions. This task does not perform them.
3. On GitHub, open **Settings → Codespaces**.
4. Under **Dotfiles**, enable **Automatically install dotfiles** and select this repository.
5. Create a new codespace to verify setup. Existing codespaces are not changed by an updated dotfiles checkout.
6. In the new codespace, inspect the managed Bash block in `~/.bashrc` and run `terrahash-doctor`. For a setup failure, use GitHub’s documented [Codespaces dotfiles troubleshooting](https://docs.github.com/en/codespaces/troubleshooting/troubleshooting-personalization-for-codespaces#troubleshooting-dotfiles) facilities.

Dotfiles are account personalization, not a per-project enforcement mechanism. Each contributor must configure their own account; choosing an organization-owned repository does not automatically make it the default for every organization member. Keep project runtimes, services, and reproducible dependency versions in each project’s devcontainer/configuration.

VS Code Settings Sync is separate from shell dotfiles. GitHub documents it as a way to synchronize editor settings and provides separate Codespaces preferences; use it where appropriate rather than treating shell dotfiles as a user-scoped VS Code settings mechanism.
