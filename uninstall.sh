#!/usr/bin/env bash

set -eu

usage() {
  cat <<'EOF'
Usage: ./uninstall.sh [--dry-run]

Remove exact managed blocks belonging to this checkout. Backups are retained.
  --dry-run  Show planned removals without changing files or state
  --help     Show this help
EOF
}

dry_run=0
for option in "$@"; do
  case $option in
  --dry-run) dry_run=1 ;;
  --help)
    usage
    exit 0
    ;;
  *)
    printf 'uninstall.sh: unsupported option: %s\n' "$option" >&2
    usage >&2
    exit 2
    ;;
  esac
done

script_path=$0
case $script_path in
*/*) ;;
*) script_path=$(command -v "$script_path") || {
  printf '%s\n' 'uninstall.sh: cannot locate this script.' >&2
  exit 1
} ;;
esac
case $script_path in
/*) ;;
*) script_path=./$script_path ;;
esac
repo_dir=$(CDPATH='' cd -P "$(dirname "$script_path")" && pwd -P) || {
  printf '%s\n' 'uninstall.sh: cannot resolve the repository directory.' >&2
  exit 1
}
. "$repo_dir/scripts/dotfiles-lib.sh"
th_validate_home
th_repo_path
th_init_paths
th_check_state_path
th_owner_read || {
  printf '%s\n' 'No registered dotfiles installation; nothing to remove.'
  exit 0
}
git_file=$OWNER_GIT_CONFIG
if [ "$dry_run" -eq 0 ]; then
  th_prepare_state_dir
  th_lock
  th_owner_read || th_die 'Installation state changed while acquiring the lock.'
fi
[ "$OWNER_REPO" = "$TH_REPO" ] ||
  th_die 'This checkout does not own the installation. Use the original checkout to uninstall it.'

bash_file=$HOME/.bashrc
zsh_file=$HOME/.zshrc
bash_start='# >>> terrahash-dotfiles managed: bash >>>'
bash_end='# <<< terrahash-dotfiles managed: bash <<<'
git_start='# >>> terrahash-dotfiles managed: git >>>'
git_end='# <<< terrahash-dotfiles managed: git <<<'
bash_block=$(th_bash_block)
git_block=$(th_git_block "$OWNER_EXCLUDES")
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
if [ "$OWNER_ZSH" -eq 1 ]; then

  zsh_start='# >>> terrahash-dotfiles managed: zsh >>>'
  zsh_end='# <<< terrahash-dotfiles managed: zsh <<<'
  zsh_block=$(th_zsh_block)
  if th_managed_status "$zsh_file" "$zsh_start" "$zsh_end" "$zsh_block"; then
    zsh_status=present
  else
    zsh_status=absent
  fi
fi

if [ "$dry_run" -eq 1 ]; then
  [ ! -d "$TH_LOCK_DIR" ] || th_die "An operation may be active: $TH_LOCK_DIR"
  for item in "Bash:$bash_file:$bash_status" "Git:$git_file:$git_status" "Zsh:$zsh_file:$zsh_status"; do
    name=${item%%:*}
    rest=${item#*:}
    file=${rest%%:*}
    state=${rest##*:}
    [ "$state" != present ] || printf 'Would remove %s managed block from %s\n' "$name" "$file"
  done
  printf 'Would remove installation state: %s/owner\n' "$TH_STATE_DIR"
  exit 0
fi

if [ "$bash_status" = present ]; then th_remove_block "$bash_file" "$bash_start" "$bash_end"; fi
if [ "$git_status" = present ]; then th_remove_block "$git_file" "$git_start" "$git_end"; fi
if [ "$OWNER_ZSH" -eq 1 ] && [ "$zsh_status" = present ]; then
  th_remove_block "$zsh_file" "$zsh_start" "$zsh_end"
fi
rm -f "$TH_STATE_DIR/owner" || th_die 'Could not remove installation state.'
printf '%s\n' 'Uninstall complete; backups were preserved.'
