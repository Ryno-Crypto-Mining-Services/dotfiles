#!/usr/bin/env bash

set -eu

usage() {
  cat <<'EOF'
Usage: scripts/install-cursor-skills.sh [--dry-run]

Install pinned LangChain Cursor skills from this checkout into ~/.cursor/skills.
  --dry-run  Validate and report planned changes without writing state or files
  --help     Show this help

This command is offline and opt-in. It does not change the baseline ./install.sh
behavior, configure Cursor sync, enable LangSmith tracing, or touch credentials.
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
    printf 'install-cursor-skills.sh: unsupported option: %s\n' "$option" >&2
    usage >&2
    exit 2
    ;;
  esac
done

script_path=$0
case $script_path in
*/*) ;;
*) script_path=$(command -v "$script_path") || {
  printf '%s\n' 'install-cursor-skills.sh: cannot locate this script.' >&2
  exit 1
} ;;
esac
case $script_path in
/*) ;;
*) script_path=./$script_path ;;
esac
repo_dir=$(CDPATH='' cd -P "$(dirname "$script_path")/.." && pwd -P) || {
  printf '%s\n' 'install-cursor-skills.sh: cannot resolve the repository directory.' >&2
  exit 1
}

if ! command -v python3 >/dev/null 2>&1; then
  printf '%s\n' 'install-cursor-skills.sh: python3 is required.' >&2
  exit 1
fi

manifest=$repo_dir/agent-skills/sources.json
helper=$repo_dir/scripts/cursor-skills-helper.py
[ -f "$manifest" ] || {
  printf 'install-cursor-skills.sh: missing manifest: %s\n' "$manifest" >&2
  exit 1
}
[ -f "$helper" ] || {
  printf 'install-cursor-skills.sh: missing helper: %s\n' "$helper" >&2
  exit 1
}

args=(--repo-root "$repo_dir" --manifest "$manifest" --target cursor)
if [ "$dry_run" -eq 1 ]; then
  args+=(--dry-run)
fi

exec python3 "$helper" "${args[@]}"
