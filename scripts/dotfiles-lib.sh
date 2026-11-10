TH_STATE_DIR=
TH_BACKUP_DIR=
TH_LOCK_DIR=
TH_TEMP_FILE=

th_die() {
  printf 'terrahash-dotfiles: %s\n' "$*" >&2
  exit 1
}

th_validate_home() {
  [ -n "${HOME:-}" ] || th_die 'HOME is empty.'
  case $HOME in
  /*) ;;
  *) th_die 'HOME must be an absolute path.' ;;
  esac
  case $HOME in
  *$'\n'* | *$'\r'*) th_die 'HOME cannot contain a newline.' ;;
  esac
  if ! { [ -d "$HOME" ] && [ -r "$HOME" ] && [ -w "$HOME" ] && [ -x "$HOME" ]; }; then
    th_die 'HOME must be an accessible, writable directory.'
  fi
  home_real=$(CDPATH='' cd -P "$HOME" && pwd -P) ||
    th_die 'Cannot resolve HOME safely.'
  [ "$home_real" != / ] || th_die 'Refusing HOME that resolves to /.'
}

th_repo_path() {
  case $0 in
  */*) script_path=$0 ;;
  *) script_path=$(command -v "$0") || th_die 'Cannot locate this script.' ;;
  esac
  case $script_path in
  /*) ;;
  *) script_path=./$script_path ;;
  esac
  TH_REPO=$(CDPATH='' cd -P "$(dirname "$script_path")" && pwd -P) ||
    th_die 'Cannot resolve the repository directory.'
  case $TH_REPO in
  *:*) th_die 'The checkout path cannot contain a colon because it is added to PATH.' ;;
  esac
  case $TH_REPO in
  *$'\n'* | *$'\r'*) th_die 'The checkout path cannot contain a newline.' ;;
  esac
}

th_init_paths() {
  TH_STATE_DIR=$HOME/.local/state/terrahash-dotfiles
  TH_BACKUP_DIR=$TH_STATE_DIR/backups
  TH_LOCK_DIR=$TH_STATE_DIR/lock
  case $TH_STATE_DIR/ in
  "$TH_REPO/"*) th_die 'Installation state and backups must be outside the checkout.' ;;
  esac
}

th_check_state_path() {
  for path in "$HOME/.local" "$HOME/.local/state" "$TH_STATE_DIR"; do
    [ ! -L "$path" ] || th_die "Refusing symlinked state path: $path"
  done
}

th_prepare_state_dir() {
  th_check_state_path
  mkdir -p "$TH_STATE_DIR" || th_die "Cannot create state directory: $TH_STATE_DIR"
  chmod 700 "$TH_STATE_DIR" || th_die "Cannot secure state directory: $TH_STATE_DIR"
}

th_lock() {
  if [ -d "$TH_LOCK_DIR" ]; then
    th_die "Another operation may be active; if it is not, remove the stale lock directory: $TH_LOCK_DIR"
  fi
  mkdir "$TH_LOCK_DIR" 2>/dev/null ||
    th_die "Could not acquire the installer lock: $TH_LOCK_DIR"
  chmod 700 "$TH_LOCK_DIR" || th_die "Cannot secure lock directory: $TH_LOCK_DIR"
  trap th_cleanup EXIT
  trap 'exit 1' HUP INT TERM
}

th_cleanup() {
  if [ -n "$TH_TEMP_FILE" ]; then
    rm -f "$TH_TEMP_FILE"
  fi
  if [ -n "$TH_LOCK_DIR" ] && [ -d "$TH_LOCK_DIR" ]; then
    rmdir "$TH_LOCK_DIR" 2>/dev/null || :
  fi
}

th_validate_target() {
  target=$1
  [ ! -L "$target" ] || th_die "Refusing symlinked configuration file: $target"
  if [ -e "$target" ]; then
    [ -f "$target" ] || th_die "Expected a regular file: $target"
    [ -r "$target" ] || th_die "Cannot read configuration file: $target"
  fi
}

th_managed_status() {
  target=$1
  start=$2
  end=$3
  expected=$4
  th_validate_target "$target"
  if [ ! -e "$target" ]; then
    return 1
  fi

  marker_count=$(grep -F -c 'terrahash-dotfiles managed:' "$target" 2>/dev/null || :)
  start_count=$(grep -F -c "$start" "$target" 2>/dev/null || :)
  end_count=$(grep -F -c "$end" "$target" 2>/dev/null || :)
  if [ "$marker_count" -eq 0 ] && [ "$start_count" -eq 0 ] && [ "$end_count" -eq 0 ]; then
    return 1
  fi
  if ! { [ "$marker_count" -eq 2 ] && [ "$start_count" -eq 1 ] && [ "$end_count" -eq 1 ]; }; then
    th_die "Ambiguous managed markers in $target; resolve them manually."
  fi
  actual=$(awk -v s="$start" -v e="$end" '
    $0 == s { inside = 1 }
    inside { print; if ($0 == e) exit }
  ' "$target") || th_die "Cannot inspect managed block in $target"
  [ "$actual" = "$expected" ] ||
    th_die "Managed content in $target was changed; resolve it manually."
  return 0
}

th_backup() {
  target=$1
  [ -f "$target" ] || return 0
  mkdir -p "$TH_BACKUP_DIR" || th_die "Cannot create backup directory: $TH_BACKUP_DIR"
  chmod 700 "$TH_BACKUP_DIR" || th_die "Cannot secure backup directory: $TH_BACKUP_DIR"
  stamp=$(date '+%Y%m%d%H%M%S') || th_die 'Cannot obtain a backup timestamp.'
  name=$(basename "$target")
  index=0
  while :; do
    backup=$TH_BACKUP_DIR/$name.$stamp.$$.$index
    [ ! -e "$backup" ] && [ ! -L "$backup" ] && break
    index=$((index + 1))
  done
  cp -p "$target" "$backup" || th_die "Cannot back up $target to $backup"
  chmod 600 "$backup" || th_die "Cannot secure backup: $backup"
  printf 'Backed up %s to %s\n' "$target" "$backup"
}

th_new_temp() {
  target=$1
  TH_TEMP_FILE=$(mktemp "$target.terrahash.XXXXXX") ||
    th_die "Cannot create a temporary file beside $target"
  if [ -f "$target" ]; then
    cp -p "$target" "$TH_TEMP_FILE" ||
      th_die "Cannot preserve configuration file metadata: $target"
    : >"$TH_TEMP_FILE" || th_die "Cannot prepare temporary file for $target"
  else
    chmod 600 "$TH_TEMP_FILE" || th_die "Cannot secure temporary file for $target"
  fi
}

th_append_block() {
  target=$1
  block=$2
  th_new_temp "$target"
  if [ -f "$target" ]; then
    cat "$target" >"$TH_TEMP_FILE" || th_die "Cannot copy $target"
  fi
  if [ -s "$TH_TEMP_FILE" ]; then
    last_byte=$(tail -c 1 "$TH_TEMP_FILE" | od -An -t x1 | tr -d '[:space:]')
    [ "$last_byte" = 0a ] || printf '\n' >>"$TH_TEMP_FILE"
  fi
  printf '%s\n' "$block" >>"$TH_TEMP_FILE" ||
    th_die "Cannot prepare updated configuration: $target"
  th_backup "$target"
  mv -f "$TH_TEMP_FILE" "$target" || th_die "Cannot replace configuration file: $target"
  TH_TEMP_FILE=
  printf 'Updated %s\n' "$target"
}

th_prepend_block() {
  target=$1
  block=$2
  th_new_temp "$target"
  printf '%s\n' "$block" >"$TH_TEMP_FILE" ||
    th_die "Cannot prepare updated configuration: $target"
  if [ -f "$target" ]; then
    cat "$target" >>"$TH_TEMP_FILE" || th_die "Cannot copy $target"
  fi
  th_backup "$target"
  mv -f "$TH_TEMP_FILE" "$target" || th_die "Cannot replace configuration file: $target"
  TH_TEMP_FILE=
  printf 'Updated %s\n' "$target"
}

th_remove_block() {
  target=$1
  start=$2
  end=$3
  th_new_temp "$target"
  awk -v s="$start" -v e="$end" '
    $0 == s { inside = 1; next }
    inside && $0 == e { inside = 0; next }
    !inside { print }
    END { if (inside) exit 2 }
  ' "$target" >"$TH_TEMP_FILE" ||
    th_die "Cannot safely remove the managed block from $target"
  th_backup "$target"
  mv -f "$TH_TEMP_FILE" "$target" || th_die "Cannot replace configuration file: $target"
  TH_TEMP_FILE=
  printf 'Updated %s\n' "$target"
}

th_shell_quote() {
  value=$1
  quoted="'"
  while [ -n "$value" ]; do
    character=${value%"${value#?}"}
    value=${value#?}
    if [ "$character" = "'" ]; then
      quoted="${quoted}'\\''"
    else
      quoted=$quoted$character
    fi
  done
  printf "%s'" "$quoted"
}

th_git_quote() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

th_bash_block() {
  source_path=$(th_shell_quote "$TH_REPO/shell/bash.sh")
  printf '%s\n' \
    '# >>> terrahash-dotfiles managed: bash >>>' \
    'case $- in' \
    "  *i*) [ -r $source_path ] && . $source_path ;;" \
    'esac' \
    '# <<< terrahash-dotfiles managed: bash <<<'
}

th_zsh_block() {
  source_path=$(th_shell_quote "$TH_REPO/shell/zsh.sh")
  printf '%s\n' \
    '# >>> terrahash-dotfiles managed: zsh >>>' \
    'case $- in' \
    "  *i*) [ -r $source_path ] && . $source_path ;;" \
    'esac' \
    '# <<< terrahash-dotfiles managed: zsh <<<'
}

th_git_block() {
  config_path=$(th_git_quote "$TH_REPO/git/config")
  if [ "$1" -eq 1 ]; then
    ignore_path=$(th_git_quote "$TH_REPO/git/ignore")
    printf '%s\n' \
      '# >>> terrahash-dotfiles managed: git >>>' \
      '[include]' \
      "    path = \"$config_path\"" \
      '[core]' \
      "    excludesFile = \"$ignore_path\"" \
      '# <<< terrahash-dotfiles managed: git <<<'
  else
    printf '%s\n' \
      '# >>> terrahash-dotfiles managed: git >>>' \
      '[include]' \
      "    path = \"$config_path\"" \
      '# <<< terrahash-dotfiles managed: git <<<'
  fi
}

th_owner_read() {
  owner=$TH_STATE_DIR/owner
  [ ! -L "$owner" ] || th_die "Refusing symlinked installation state: $owner"
  [ -f "$owner" ] || return 1
  [ -r "$owner" ] || th_die "Cannot read installation state: $owner"
  OWNER_REPO=
  OWNER_EXCLUDES=
  OWNER_GIT_CONFIG=
  OWNER_ZSH=
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in
    repo=*)
      [ -z "$OWNER_REPO" ] || th_die "Malformed installation state: $owner"
      OWNER_REPO=${line#repo=}
      ;;
    excludes=0 | excludes=1)
      [ -z "$OWNER_EXCLUDES" ] || th_die "Malformed installation state: $owner"
      OWNER_EXCLUDES=${line#excludes=}
      ;;
    gitconfig=*)
      [ -z "$OWNER_GIT_CONFIG" ] || th_die "Malformed installation state: $owner"
      OWNER_GIT_CONFIG=${line#gitconfig=}
      ;;
    zsh=0 | zsh=1)
      [ -z "$OWNER_ZSH" ] || th_die "Malformed installation state: $owner"
      OWNER_ZSH=${line#zsh=}
      ;;
    *) th_die "Malformed installation state: $owner" ;;
    esac
  done <"$owner"
  if ! { [ -n "$OWNER_REPO" ] && [ -n "$OWNER_EXCLUDES" ] &&
    [ -n "$OWNER_GIT_CONFIG" ] && [ -n "$OWNER_ZSH" ]; }; then
    th_die "Malformed installation state: $owner"
  fi
  case $OWNER_GIT_CONFIG in
  /*) ;;
  *) th_die "Malformed installation state: $owner" ;;
  esac
  return 0
}

th_owner_write() {
  owner=$TH_STATE_DIR/owner
  expected=$(printf 'repo=%s\nexcludes=%s\ngitconfig=%s\nzsh=%s' "$TH_REPO" "$1" "$2" "$3")
  if [ -f "$owner" ] && [ ! -L "$owner" ] && [ "$(cat "$owner")" = "$expected" ]; then
    return 0
  fi
  TH_TEMP_FILE=$(mktemp "$TH_STATE_DIR/.owner.XXXXXX") ||
    th_die 'Cannot create installation state.'
  chmod 600 "$TH_TEMP_FILE" || th_die 'Cannot secure installation state.'
  printf 'repo=%s\nexcludes=%s\ngitconfig=%s\nzsh=%s\n' "$TH_REPO" "$1" "$2" "$3" >"$TH_TEMP_FILE" ||
    th_die 'Cannot write installation state.'
  mv -f "$TH_TEMP_FILE" "$owner" || th_die 'Cannot save installation state.'
  TH_TEMP_FILE=
}
