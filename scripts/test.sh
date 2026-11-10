#!/usr/bin/env bash

set -eu

repo=$(CDPATH='' cd -P "$(dirname "$0")/.." && pwd -P)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/terrahash-dotfiles-tests.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_file_contains() {
  grep -F "$2" "$1" >/dev/null || fail "expected $1 to contain: $2"
}

assert_file_lacks() {
  if grep -F "$2" "$1" >/dev/null; then
    fail "expected $1 not to contain: $2"
  fi
}

new_home() {
  test_home=$tmp/"$1"
  mkdir -p "$test_home"
  export test_home
}

run() {
  env -i \
    HOME="$test_home" \
    XDG_CONFIG_HOME="$test_home/.config" \
    GIT_CONFIG_NOSYSTEM=1 \
    PATH="$PATH" \
    "$@"
}

backup_count() {
  if [ -d "$test_home/.local/state/terrahash-dotfiles/backups" ]; then
    find "$test_home/.local/state/terrahash-dotfiles/backups" -type f | wc -l | tr -d ' '
  else
    printf '0'
  fi
}

file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

printf '%s\n' 'Test 1-2, 6-7, 12, 14-16, 21-24: install, dry run, idempotency, aliases, and uninstall'
new_home 'empty home with spaces'
run "$repo/install.sh" --dry-run >/dev/null
[ ! -e "$test_home/.local" ] || fail 'dry-run created state'
[ ! -e "$test_home/.bashrc" ] || fail 'dry-run created .bashrc'
[ ! -e "$test_home/.gitconfig" ] || fail 'dry-run created .gitconfig'
run "$repo/install.sh" >/dev/null
[ ! -e "$test_home/.zshrc" ] || fail 'default install activated Zsh'
assert_file_contains "$test_home/.bashrc" 'managed: bash'
git_config_file=$test_home/.config/git/config
run git config --global --includes --get alias.st | grep -Fx status >/dev/null ||
  fail 'shared Git alias st is unavailable'
first_bash=$(cat "$test_home/.bashrc")
first_git=$(cat "$git_config_file")
run "$repo/install.sh" >/dev/null
[ "$first_bash" = "$(cat "$test_home/.bashrc")" ] || fail 'second install changed .bashrc'
[ "$first_git" = "$(cat "$git_config_file")" ] || fail 'second install changed Git config'
[ "$(backup_count)" -eq 0 ] || fail 'unnecessary backup on fresh install or no-change rerun'
owner_before=$(cat "$test_home/.local/state/terrahash-dotfiles/owner")
run "$repo/install.sh" --dry-run >/dev/null
[ "$owner_before" = "$(cat "$test_home/.local/state/terrahash-dotfiles/owner")" ] ||
  fail 'install dry-run changed ownership state'
dry_run_bash=$(cat "$test_home/.bashrc")
dry_run_git=$(cat "$git_config_file")
dry_run_backups=$(backup_count)
run "$repo/uninstall.sh" --dry-run >/dev/null
[ "$dry_run_bash" = "$(cat "$test_home/.bashrc")" ] || fail 'uninstall dry-run changed .bashrc'
[ "$dry_run_git" = "$(cat "$git_config_file")" ] || fail 'uninstall dry-run changed Git config'
[ "$owner_before" = "$(cat "$test_home/.local/state/terrahash-dotfiles/owner")" ] ||
  fail 'uninstall dry-run changed ownership state'
[ "$dry_run_backups" = "$(backup_count)" ] || fail 'uninstall dry-run created a backup'
run "$repo/uninstall.sh" >/dev/null
assert_file_lacks "$test_home/.bashrc" 'terrahash-dotfiles managed'
assert_file_lacks "$git_config_file" 'terrahash-dotfiles managed'
run "$repo/uninstall.sh" >/dev/null

printf '%s\n' 'Test 3-5, 13, 17, 22: preserve existing files, back up changes, and honor personal Git settings'
new_home 'existing files'
printf 'personal bash setting\n' > "$test_home/.bashrc"
cat > "$test_home/.gitconfig" <<'EOF'
[user]
	name = Local Test User
	email = local@example.invalid
EOF
run git config --global alias.st show
run git config --global core.excludesFile "$test_home/custom ignore"
original_git_config=$(cat "$test_home/.gitconfig")
run "$repo/install.sh" >/dev/null
assert_file_contains "$test_home/.bashrc" 'personal bash setting'
[ "$(backup_count)" -eq 2 ] || fail 'existing files were not backed up exactly once'
original_bash_backup=$(find "$test_home/.local/state/terrahash-dotfiles/backups" -name '.bashrc.*' -type f)
[ "$(cat "$original_bash_backup")" = 'personal bash setting' ] ||
  fail 'Bash backup did not preserve the pre-install file'
original_git_backup=$(find "$test_home/.local/state/terrahash-dotfiles/backups" -name '.gitconfig.*' -type f)
[ "$(cat "$original_git_backup")" = "$original_git_config" ] ||
  fail 'Git backup did not preserve the pre-install file'
[ "$(file_mode "$test_home/.local/state/terrahash-dotfiles")" = 700 ] ||
  fail 'state directory is not private'
[ "$(file_mode "$test_home/.local/state/terrahash-dotfiles/backups")" = 700 ] ||
  fail 'backup directory is not private'
[ "$(run git config --global --get user.name)" = 'Local Test User' ] ||
  fail 'personal Git identity changed'
[ "$(run git config --global --get user.email)" = 'local@example.invalid' ] ||
  fail 'personal Git email changed'
[ "$(run git config --global --get alias.st)" = show ] ||
  fail 'existing personal alias was not authoritative'
[ "$(run git config --global --get core.excludesFile)" = "$test_home/custom ignore" ] ||
  fail 'existing global excludes setting changed'
before_uninstall=$(backup_count)
run "$repo/install.sh" >/dev/null
[ "$(backup_count)" -eq "$before_uninstall" ] || fail 'no-change install created a backup'
printf 'later user bash edit\n' >> "$test_home/.bashrc"
printf '\n# later user Git edit\n' >> "$test_home/.gitconfig"
run "$repo/uninstall.sh" >/dev/null
assert_file_contains "$test_home/.bashrc" 'personal bash setting'
assert_file_contains "$test_home/.bashrc" 'later user bash edit'
assert_file_contains "$test_home/.gitconfig" 'later user Git edit'
[ "$(backup_count)" -gt "$before_uninstall" ] || fail 'uninstall did not preserve a pre-change backup'

printf '%s\n' 'Test 8, 15: checkout paths with spaces work'
space_repo=$tmp/'checkout with spaces'
mkdir -p "$space_repo"
cp "$repo/install.sh" "$repo/uninstall.sh" "$space_repo/"
cp -R "$repo/scripts" "$repo/shell" "$repo/git" "$repo/bin" "$space_repo/"
chmod +x "$space_repo/install.sh" "$space_repo/uninstall.sh" "$space_repo/bin/terrahash-doctor"
new_home 'space path target'
env -i HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" GIT_CONFIG_NOSYSTEM=1 PATH="$PATH" \
  "$space_repo/install.sh" >/dev/null
assert_file_contains "$test_home/.bashrc" "$space_repo/shell/bash.sh"
# shellcheck disable=SC2016
installed_shell_output=$(env -i HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" PATH=/usr/bin:/bin \
  bash --noprofile --rcfile "$test_home/.bashrc" -i -c '
    alias gs >/dev/null
    case ":$PATH:" in *":$1:"*) ;; *) exit 1 ;; esac
  ' bash "$space_repo/shell/../bin" 2>/dev/null) ||
  fail 'managed Bash block did not source correctly from a checkout path with spaces'
[ -z "$installed_shell_output" ] || fail 'managed Bash block produced startup output'
[ "$(run git config --global --includes --get alias.lg)" = 'log --oneline --decorate -10' ] ||
  fail 'Git include path containing spaces failed'
run "$space_repo/uninstall.sh" >/dev/null

printf '%s\n' 'Test 18: symlinked startup files are rejected safely'
new_home 'symlink target'
printf 'keep me\n' > "$test_home/target"
ln -s "$test_home/target" "$test_home/.bashrc"
if run "$repo/install.sh" >/dev/null 2>&1; then
  fail 'installer followed a symlinked startup file'
fi
[ "$(cat "$test_home/target")" = 'keep me' ] || fail 'symlink target was changed'
new_home 'unmanaged Zsh symlink'
printf 'leave Zsh alone\n' > "$test_home/zsh-target"
ln -s "$test_home/zsh-target" "$test_home/.zshrc"
run "$repo/install.sh" >/dev/null
run "$repo/uninstall.sh" >/dev/null
[ -L "$test_home/.zshrc" ] || fail 'default install/uninstall changed an unrequested Zsh symlink'
[ "$(cat "$test_home/zsh-target")" = 'leave Zsh alone' ] ||
  fail 'default install/uninstall changed an unrequested Zsh target'

printf '%s\n' 'Test XDG Git configuration precedence'
new_home 'XDG Git config'
mkdir -p "$test_home/.config/git"
cat > "$test_home/.config/git/config" <<'EOF'
[alias]
	st = show
EOF
run "$repo/install.sh" >/dev/null
[ "$(run git config --global --includes --get alias.st)" = show ] ||
  fail 'existing XDG alias was not authoritative'
run "$repo/uninstall.sh" >/dev/null

printf '%s\n' 'Test 19: malformed managed markers are rejected'
new_home 'malformed markers'
printf '%s\n' '# >>> terrahash-dotfiles managed: bash >>>' > "$test_home/.bashrc"
if run "$repo/install.sh" >/dev/null 2>&1; then
  fail 'installer accepted malformed managed markers'
fi
[ ! -e "$test_home/.gitconfig" ] || fail 'preflight failure partially changed Git config'

printf '%s\n' 'Test uninstall refuses user-modified managed content'
new_home 'modified managed content'
run "$repo/install.sh" >/dev/null
sed 's@/shell/bash.sh@/shell/changed.sh@' "$test_home/.bashrc" > "$tmp/modified-bashrc"
mv "$tmp/modified-bashrc" "$test_home/.bashrc"
if run "$repo/uninstall.sh" >/dev/null 2>&1; then
  fail 'uninstaller removed user-modified managed content'
fi
assert_file_contains "$test_home/.bashrc" '/shell/changed.sh'
[ -f "$test_home/.local/state/terrahash-dotfiles/owner" ] ||
  fail 'uninstall removed ownership state after refusing modified content'

printf '%s\n' 'Test 20: a second checkout cannot take over an installation'
new_home 'checkout conflict'
run "$repo/install.sh" >/dev/null
if env -i HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" GIT_CONFIG_NOSYSTEM=1 PATH="$PATH" \
  "$space_repo/install.sh" >/dev/null 2>&1; then
  fail 'second checkout took over the installed configuration'
fi
run "$repo/uninstall.sh" >/dev/null

printf '%s\n' 'Test 9: doctor treats missing optional tools as informational'
new_home 'doctor'
doctor_bin=$tmp/doctor-bin
mkdir -p "$doctor_bin"
for tool in bash git uname; do
  ln -s "$(command -v "$tool")" "$doctor_bin/$tool"
done
doctor_output=$(cd "$repo" && env -i HOME="$test_home" PATH="$doctor_bin" "$repo/bin/terrahash-doctor")
printf '%s\n' "$doctor_output" | grep -F 'Optional gh: unavailable' >/dev/null ||
  fail 'doctor did not report a missing optional tool'
printf '%s\n' "$doctor_output" | grep -F 'Dotfiles installation: not registered' >/dev/null ||
  fail 'doctor did not report installation state'

printf '%s\n' 'Test 10-11: repeated sourcing preserves PATH; non-interactive sourcing is quiet'
new_home 'shell source'
# shellcheck disable=SC2016
shell_output=$(env -i HOME="$test_home" PATH=/usr/bin:/bin bash --noprofile --norc -i -c '
  . "$1"
  first=$PATH
  . "$1"
  [ "$PATH" = "$first" ]
  case ":$PATH:" in *":$2:"*) ;; *) exit 1 ;; esac
  alias gs >/dev/null
' bash "$repo/shell/bash.sh" "$repo/shell/../bin" 2>/dev/null) ||
  fail 'interactive shell sourcing did not remain idempotent'
[ -z "$shell_output" ] || fail 'interactive shell sourcing produced output'
# shellcheck disable=SC2016
noninteractive_output=$(env -i HOME="$test_home" PATH=/usr/bin:/bin bash --noprofile --norc -c '. "$1"' bash "$repo/shell/bash.sh" 2>&1)
[ -z "$noninteractive_output" ] || fail 'non-interactive sourcing was not quiet'
# shellcheck disable=SC2016
repo_root=$(env -i HOME="$test_home" PATH=/usr/bin:/bin bash --noprofile --norc -i -c '
  . "$1"
  cd "$2/scripts"
  croot
  printf "%s" "$PWD"
' bash "$repo/shell/bash.sh" "$repo" 2>/dev/null)
[ "$repo_root" = "$repo" ] || fail 'croot did not change to the worktree root'
# shellcheck disable=SC2016
if env -i HOME="$test_home" PATH=/usr/bin:/bin bash --noprofile --norc -i -c '
  . "$1"
  cd "$2"
  croot
' bash "$repo/shell/bash.sh" "$tmp" >/dev/null 2>&1; then
  fail 'croot succeeded outside a worktree'
fi

printf '%s\n' 'Test 17: explicitly requested Zsh activation'
new_home 'zsh'
run "$repo/install.sh" --zsh >/dev/null
assert_file_contains "$test_home/.zshrc" 'managed: zsh'
run "$repo/install.sh" >/dev/null
assert_file_contains "$test_home/.zshrc" 'managed: zsh'
run "$repo/uninstall.sh" >/dev/null
if command -v zsh >/dev/null 2>&1; then
  printf '%s\n' 'Test Zsh startup runtime'
  new_home 'zsh runtime'
  run "$repo/install.sh" --zsh >/dev/null
  env -i HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" PATH="$PATH" zsh -ic 'alias gs >/dev/null' >/dev/null 2>&1 ||
    fail 'Zsh startup integration failed'
  run "$repo/uninstall.sh" >/dev/null
else
  printf '%s\n' 'SKIP: Zsh-specific runtime test (zsh is unavailable)'
fi

printf '%s\n' 'Test partial failure: invalid Git config target does not partially install Bash'
new_home 'partial failure'
mkdir "$test_home/.gitconfig"
if run "$repo/install.sh" >/dev/null 2>&1; then
  fail 'installer accepted a directory as .gitconfig'
fi
[ ! -e "$test_home/.bashrc" ] || fail 'preflight error partially installed Bash'

printf '%s\n' 'Test lock: a held installer lock stops before config changes'
new_home 'lock'
mkdir -p "$test_home/.local/state/terrahash-dotfiles/lock"
if run "$repo/install.sh" >/dev/null 2>&1; then
  fail 'installer ignored a held lock'
fi
[ ! -e "$test_home/.bashrc" ] || fail 'locked install modified Bash configuration'

printf '%s\n' 'Test invalid HOME values are rejected'
if env -i HOME= PATH="$PATH" "$repo/install.sh" >/dev/null 2>&1; then
  fail 'installer accepted empty HOME'
fi
if env -i HOME=/ PATH="$PATH" "$repo/install.sh" >/dev/null 2>&1; then
  fail 'installer accepted HOME=/'
fi
env -i PATH="$PATH" "$repo/install.sh" --help >/dev/null
env -i PATH="$PATH" "$repo/uninstall.sh" --help >/dev/null
if grep -E '(^|[[:space:]])(curl|wget|apt-get|brew|npm|pip)([[:space:]]|$)' \
  "$repo/install.sh" "$repo/uninstall.sh" "$repo/shell/common.sh" "$repo/shell/bash.sh" "$repo/shell/zsh.sh" >/dev/null; then
  fail 'setup or shell startup contains a network/package bootstrap command'
fi

printf '%s\n' 'All isolated dotfiles tests passed.'
