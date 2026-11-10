#!/usr/bin/env bash

set -eu

usage() {
  cat <<'EOF'
Usage: ./install.sh [--dry-run] [--zsh]

Install the shared Bash and Git defaults. Zsh is changed only with --zsh.
  --dry-run  Show planned changes without creating files or state in HOME
  --zsh      Also manage the interactive Zsh startup block
  --help     Show this help
EOF
}

dry_run=0
enable_zsh=0
for option in "$@"; do
  case $option in
  --dry-run) dry_run=1 ;;
  --zsh) enable_zsh=1 ;;
  --help)
    usage
    exit 0
    ;;
  *)
    printf 'install.sh: unsupported option: %s\n' "$option" >&2
    usage >&2
    exit 2
    ;;
  esac
done

script_path=$0
case $script_path in
*/*) ;;
*) script_path=$(command -v "$script_path") || {
  printf '%s\n' 'install.sh: cannot locate this script.' >&2
  exit 1
} ;;
esac
case $script_path in
/*) ;;
*) script_path=./$script_path ;;
esac
repo_dir=$(CDPATH='' cd -P "$(dirname "$script_path")" && pwd -P) || {
  printf '%s\n' 'install.sh: cannot resolve the repository directory.' >&2
  exit 1
}
. "$repo_dir/scripts/dotfiles-lib.sh"
th_validate_home
th_repo_path
th_init_paths
th_check_state_path

[ -z "${GIT_CONFIG_GLOBAL:-}" ] ||
  th_die 'GIT_CONFIG_GLOBAL is set; unset it so the managed include is installed in the standard global config.'

if [ -e "$HOME/.gitconfig" ] || [ -L "$HOME/.gitconfig" ]; then
  git_file=$HOME/.gitconfig
else
  git_config_home=${XDG_CONFIG_HOME:-$HOME/.config}
  case $git_config_home in
  /*) ;;
  *) th_die 'XDG_CONFIG_HOME must be absolute when set.' ;;
  esac
  [ "$git_config_home" != / ] || th_die 'Refusing to use / as XDG_CONFIG_HOME.'
  case $git_config_home in
  *$'\n'* | *$'\r'*) th_die 'XDG_CONFIG_HOME cannot contain a newline.' ;;
  esac
  if [ -L "$git_config_home" ] || [ -L "$git_config_home/git" ]; then
    th_die 'Refusing a symlinked Git configuration directory.'
  fi
  git_file=$git_config_home/git/config
fi

if [ "$dry_run" -eq 0 ]; then
  th_prepare_state_dir
  th_lock
fi

owner_exists=0
zsh_state=0
if th_owner_read; then
  owner_exists=1
  [ "$OWNER_REPO" = "$TH_REPO" ] ||
    th_die 'A different checkout owns this installation. Uninstall it from its original checkout first.'
  [ "$OWNER_GIT_CONFIG" = "$git_file" ] ||
    th_die 'The global Git config location changed. Restore XDG_CONFIG_HOME or uninstall before changing it.'
  excludes=$OWNER_EXCLUDES
  zsh_state=$OWNER_ZSH
else
  excludes=0
  if git config --global --includes --get core.excludesFile >/dev/null 2>&1; then
    excludes=0
  else
    git_status=$?
    [ "$git_status" -eq 1 ] || th_die 'Cannot inspect global Git configuration safely.'
    excludes=1
  fi
  if [ "$enable_zsh" -eq 1 ]; then
    zsh_state=1
  fi
fi

bash_file=$HOME/.bashrc
bash_start='# >>> terrahash-dotfiles managed: bash >>>'
bash_end='# <<< terrahash-dotfiles managed: bash <<<'
git_start='# >>> terrahash-dotfiles managed: git >>>'
git_end='# <<< terrahash-dotfiles managed: git <<<'
bash_block=$(th_bash_block)
git_block=$(th_git_block "$excludes")
if th_managed_status "$bash_file" "$bash_start" "$bash_end" "$bash_block"; then
  bash_status=present
else
  bash_status=absent
fi
if th_managed_status "$git_file" "$git_start" "$git_end" "$git_block"; then
  git_status=present
else
  git_status=absent
fi

zsh_status=absent
if [ "$enable_zsh" -eq 1 ]; then
  zsh_file=$HOME/.zshrc
  zsh_start='# >>> terrahash-dotfiles managed: zsh >>>'
  zsh_end='# <<< terrahash-dotfiles managed: zsh <<<'
  zsh_block=$(th_zsh_block)
  if th_managed_status "$zsh_file" "$zsh_start" "$zsh_end" "$zsh_block"; then
    zsh_status=present
  else
    zsh_status=absent
  fi
fi

if [ "$owner_exists" -eq 0 ]; then
  if [ "$bash_status" = present ] || [ "$git_status" = present ] || [ "$zsh_status" = present ]; then
    th_die 'Managed markers exist without ownership state; resolve them manually.'
  fi
fi

if [ "$dry_run" -eq 1 ]; then
  [ ! -d "$TH_LOCK_DIR" ] || th_die "An operation may be active: $TH_LOCK_DIR"
  printf 'Would %s Bash configuration: %s\n' \
    "$([ "$bash_status" = present ] && printf 'leave unchanged' || printf 'update')" "$bash_file"
  printf 'Would %s shared Git configuration: %s\n' \
    "$([ "$git_status" = present ] && printf 'leave unchanged' || printf 'update')" "$git_file"
  if [ "$enable_zsh" -eq 1 ]; then
    printf 'Would %s Zsh configuration: %s\n' \
      "$([ "$zsh_status" = present ] && printf 'leave unchanged' || printf 'update')" "$zsh_file"
  fi
  printf '%s\n' 'Would record installation ownership.'
  exit 0
fi

mkdir -p "$(dirname "$git_file")" ||
  th_die "Cannot create Git configuration directory: $(dirname "$git_file")"
th_owner_write "$excludes" "$git_file" "$zsh_state"

if [ "$bash_status" = absent ]; then
  th_append_block "$bash_file" "$bash_block"
else
  printf 'Unchanged %s\n' "$bash_file"
fi
if [ "$git_status" = absent ]; then
  th_prepend_block "$git_file" "$git_block"
else
  printf 'Unchanged %s\n' "$git_file"
fi
if [ "$enable_zsh" -eq 1 ]; then
  if [ "$zsh_status" = absent ]; then
    th_append_block "$zsh_file" "$zsh_block"
  else
    printf 'Unchanged %s\n' "$zsh_file"
  fi
fi
printf '%s\n' 'Installation complete.'
