#!/usr/bin/env bash

set -eu

repo=$(CDPATH='' cd -P "$(dirname "$0")/.." && pwd -P)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/terrahash-hermes-skills-tests.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
tmp=$(CDPATH='' cd -P "$tmp" && pwd -P)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

new_home() {
  test_home=$tmp/"$1"
  mkdir -p "$test_home"
  export test_home
  export XDG_STATE_HOME="$test_home/.local/state"
  unset HERMES_HOME || true
}

run_installer() {
  env -i \
    HOME="$test_home" \
    XDG_STATE_HOME="$XDG_STATE_HOME" \
    PATH="$PATH" \
    ${HERMES_HOME+"HERMES_HOME=$HERMES_HOME"} \
    "$@"
}

file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

write_skill_tree() {
  root=$1
  name=$2
  body=$3
  executable_body=${4:-}
  source_id=${5:-langchain}
  mkdir -p "$root/agent-skills/vendor/$source_id/$name/references"
  printf '%s\n' "$body" >"$root/agent-skills/vendor/$source_id/$name/SKILL.md"
  printf 'ref\n' >"$root/agent-skills/vendor/$source_id/$name/references/note.md"
  if [ -n "$executable_body" ]; then
    printf '%s\n' "$executable_body" >"$root/agent-skills/vendor/$source_id/$name/run.sh"
    chmod 755 "$root/agent-skills/vendor/$source_id/$name/run.sh"
  fi
}

write_manifest() {
  root=$1
  commit=${2:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}
  python3 - "$root" "$commit" <<'PY'
import hashlib, json, stat, sys
from pathlib import Path

root = Path(sys.argv[1])
commit = sys.argv[2]
vendor_root = root / "agent-skills" / "vendor"
skills = []
upstreams = {}
if vendor_root.is_dir():
    for source_dir in sorted(p for p in vendor_root.iterdir() if p.is_dir()):
        upstreams[source_dir.name] = {
            "repository": f"https://example.invalid/{source_dir.name}",
            "commit": commit,
            "license": {
                "spdx_id": "MIT",
                "name": "MIT License",
                "path": "LICENSE",
                "copyright": "Copyright (c) Test Fixture",
            },
        }
        for skill_dir in sorted(p for p in source_dir.iterdir() if p.is_dir()):
            files = []
            for path in sorted(skill_dir.rglob("*")):
                if not path.is_file():
                    continue
                rel = path.relative_to(skill_dir).as_posix()
                digest = hashlib.sha256(path.read_bytes()).hexdigest()
                executable = bool(path.stat().st_mode & (stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH))
                files.append({"path": rel, "sha256": digest, "executable": executable})
            skills.append(
                {
                    "name": skill_dir.name,
                    "upstream": source_dir.name,
                    "upstream_path": f"skills/{skill_dir.name}",
                    "vendor_path": f"agent-skills/vendor/{source_dir.name}/{skill_dir.name}",
                    "destination": skill_dir.name,
                    "files": files,
                }
            )

if not upstreams:
    upstreams = {
        "langchain": {
            "repository": "https://example.invalid/langchain",
            "commit": commit,
            "license": {
                "spdx_id": "MIT",
                "name": "MIT License",
                "path": "LICENSE",
                "copyright": "Copyright (c) Test Fixture",
            },
        }
    }

manifest = {
    "schema_version": 2,
    "upstreams": upstreams,
    "skills": skills,
}
(root / "agent-skills").mkdir(parents=True, exist_ok=True)
(root / "agent-skills" / "sources.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
PY
}

setup_fixture_repo() {
  name=$1
  fixture=$tmp/"fixture-$name"
  mkdir -p "$fixture/scripts" "$fixture/agent-skills"
  cp "$repo/scripts/install-hermes-skills.sh" "$repo/scripts/cursor-skills-helper.py" "$fixture/scripts/"
  chmod +x "$fixture/scripts/install-hermes-skills.sh"
  printf '%s\n' "$fixture"
}

printf '%s\n' 'Hermes skills: --help and validate real vendored payload'
env -i PATH="$PATH" "$repo/scripts/install-hermes-skills.sh" --help >/dev/null
mkdir -p "$tmp/validate-home" "$tmp/validate-state"
env -i \
  HOME="$tmp/validate-home" \
  XDG_STATE_HOME="$tmp/validate-state" \
  PATH="$PATH" \
  python3 "$repo/scripts/cursor-skills-helper.py" \
  --repo-root "$repo" \
  --manifest "$repo/agent-skills/sources.json" \
  --target hermes \
  --validate-only >/dev/null || fail 'real sources.json failed hermes validation'

printf '%s\n' 'Hermes skills: fresh install, idempotent rerun, dry-run writes'
fixture=$(setup_fixture_repo 'fresh')
write_skill_tree "$fixture" 'demo-skill' '# Demo' '#!/bin/sh\necho ok'
write_manifest "$fixture"
new_home 'hermes fresh'
run_installer "$fixture/scripts/install-hermes-skills.sh" --dry-run >/dev/null
[ ! -e "$test_home/.hermes" ] || fail 'dry-run created ~/.hermes'
[ ! -e "$test_home/.local" ] || fail 'dry-run created state under HOME'
run_installer "$fixture/scripts/install-hermes-skills.sh" >/dev/null
[ -f "$test_home/.hermes/skills/demo-skill/SKILL.md" ] || fail 'skill was not installed'
[ -x "$test_home/.hermes/skills/demo-skill/run.sh" ] || fail 'executable bit was not preserved'
[ "$(file_mode "$test_home/.local/state/terrahash-dotfiles/hermes-skills")" = 700 ] ||
  fail 'hermes-skills state directory is not private'
first_skill=$(cat "$test_home/.hermes/skills/demo-skill/SKILL.md")
first_owner=$(cat "$test_home/.local/state/terrahash-dotfiles/hermes-skills/managed/demo-skill.json")
run_installer "$fixture/scripts/install-hermes-skills.sh" >/dev/null
[ "$first_skill" = "$(cat "$test_home/.hermes/skills/demo-skill/SKILL.md")" ] ||
  fail 'idempotent install changed skill content'
[ "$first_owner" = "$(cat "$test_home/.local/state/terrahash-dotfiles/hermes-skills/managed/demo-skill.json")" ] ||
  fail 'idempotent install changed ownership state'
before_dry=$(find "$test_home" -type f | wc -l | tr -d ' ')
run_installer "$fixture/scripts/install-hermes-skills.sh" --dry-run >/dev/null
after_dry=$(find "$test_home" -type f | wc -l | tr -d ' ')
[ "$before_dry" = "$after_dry" ] || fail 'post-install dry-run wrote files'
grep -F 'terrahash-dotfiles-hermes-skills' \
  "$test_home/.local/state/terrahash-dotfiles/hermes-skills/managed/demo-skill.json" >/dev/null ||
  fail 'ownership kind is not hermes-specific'

printf '%s\n' 'Hermes skills: HERMES_HOME override'
fixture=$(setup_fixture_repo 'hermes-home')
write_skill_tree "$fixture" 'home-skill' '# Home'
write_manifest "$fixture"
new_home 'custom hermes home'
export HERMES_HOME="$test_home/custom-hermes"
run_installer "$fixture/scripts/install-hermes-skills.sh" >/dev/null
[ -f "$HERMES_HOME/skills/home-skill/SKILL.md" ] || fail 'HERMES_HOME skills root was not used'
[ ! -e "$test_home/.hermes/skills/home-skill" ] || fail 'default ~/.hermes was used despite HERMES_HOME'
unset HERMES_HOME

printf '%s\n' 'Hermes skills: invalid HERMES_HOME rejected'
new_home 'bad hermes home'
export HERMES_HOME=relative/path
if run_installer "$fixture/scripts/install-hermes-skills.sh" --dry-run >/dev/null 2>&1; then
  fail 'installer accepted relative HERMES_HOME'
fi
export HERMES_HOME=/
if run_installer "$fixture/scripts/install-hermes-skills.sh" --dry-run >/dev/null 2>&1; then
  fail 'installer accepted HERMES_HOME=/'
fi
unset HERMES_HOME

printf '%s\n' 'Hermes skills: unmanaged conflict, unrelated skill, lock, upgrade'
fixture=$(setup_fixture_repo 'lifecycle')
write_skill_tree "$fixture" 'life-skill' '# Life v1'
write_manifest "$fixture" 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
new_home 'lifecycle'
mkdir -p "$test_home/.hermes/skills/life-skill"
printf 'unmanaged\n' >"$test_home/.hermes/skills/life-skill/SKILL.md"
if run_installer "$fixture/scripts/install-hermes-skills.sh" >/dev/null 2>&1; then
  fail 'installer adopted an unmanaged destination'
fi
[ "$(cat "$test_home/.hermes/skills/life-skill/SKILL.md")" = unmanaged ] ||
  fail 'unmanaged destination was modified'
rm -rf "$test_home/.hermes/skills/life-skill"
mkdir -p "$test_home/.hermes/skills/bundled-other"
printf 'bundled\n' >"$test_home/.hermes/skills/bundled-other/SKILL.md"
printf 'keep\n' >"$test_home/.hermes/skills/.bundled_manifest"
run_installer "$fixture/scripts/install-hermes-skills.sh" >/dev/null
[ "$(cat "$test_home/.hermes/skills/bundled-other/SKILL.md")" = bundled ] ||
  fail 'unrelated Hermes skill was modified'
[ "$(cat "$test_home/.hermes/skills/.bundled_manifest")" = keep ] ||
  fail 'Hermes .bundled_manifest was modified'
write_skill_tree "$fixture" 'life-skill' '# Life v2'
write_manifest "$fixture" 'cccccccccccccccccccccccccccccccccccccccc'
run_installer "$fixture/scripts/install-hermes-skills.sh" >/dev/null
grep -F '# Life v2' "$test_home/.hermes/skills/life-skill/SKILL.md" >/dev/null ||
  fail 'managed upgrade did not apply new content'
[ -d "$test_home/.local/state/terrahash-dotfiles/hermes-skills/backups" ] ||
  fail 'upgrade did not create backups directory'

new_home 'symlink dest'
mkdir -p "$test_home/.hermes"
ln -s "$test_home/somewhere" "$test_home/.hermes/skills"
if run_installer "$fixture/scripts/install-hermes-skills.sh" >/dev/null 2>&1; then
  fail 'installer followed a symlinked Hermes skills root'
fi

new_home 'lock'
mkdir -p "$test_home/.local/state/terrahash-dotfiles/hermes-skills/lock"
if run_installer "$fixture/scripts/install-hermes-skills.sh" >/dev/null 2>&1; then
  fail 'installer ignored a held hermes-skills lock'
fi
[ ! -e "$test_home/.hermes/skills/life-skill" ] || fail 'locked install wrote a skill'

printf '%s\n' 'Hermes skills: real vendored payload dry-run and install'
new_home 'real pin'
out=$(run_installer "$repo/scripts/install-hermes-skills.sh" --dry-run 2>&1) ||
  fail 'real-pin dry-run failed'
for expected in \
  agents-langchain langgraph langfuse \
  ecosystem-primer langchain-dependencies langchain-fundamentals langchain-middleware \
  langchain-rag langgraph-fundamentals langgraph-persistence langgraph-human-in-the-loop \
  deep-agents-core deep-agents-memory deep-agents-orchestration; do
  printf '%s\n' "$out" | grep -F "Would install skill: $expected" >/dev/null ||
    fail "real-pin dry-run missing $expected"
done
[ ! -e "$test_home/.hermes" ] || fail 'real-pin dry-run created ~/.hermes'
run_installer "$repo/scripts/install-hermes-skills.sh" >/dev/null
[ -f "$test_home/.hermes/skills/agents-langchain/SKILL.md" ] ||
  fail 'agents-langchain was not installed from real payload'
[ -f "$test_home/.hermes/skills/ecosystem-primer/SKILL.md" ] ||
  fail 'ecosystem-primer was not installed from skills-benchmarks'
[ -f "$test_home/.hermes/skills/deep-agents-orchestration/SKILL.md" ] ||
  fail 'deep-agents-orchestration was not installed from skills-benchmarks'
[ ! -e "$test_home/.hermes/skills/langsmith-trace" ] ||
  fail 'langsmith-trace was incorrectly installed'
[ ! -e "$test_home/.cursor/skills" ] ||
  fail 'Hermes installer wrote Cursor skills paths'

printf '%s\n' 'Hermes skills: cursor and hermes installs stay isolated'
new_home 'both targets'
env -i HOME="$test_home" XDG_STATE_HOME="$test_home/.local/state" PATH="$PATH" \
  "$repo/scripts/install-cursor-skills.sh" >/dev/null
env -i HOME="$test_home" XDG_STATE_HOME="$test_home/.local/state" PATH="$PATH" \
  "$repo/scripts/install-hermes-skills.sh" >/dev/null
[ -f "$test_home/.cursor/skills/ecosystem-primer/SKILL.md" ] ||
  fail 'cursor install missing after dual install'
[ -f "$test_home/.hermes/skills/ecosystem-primer/SKILL.md" ] ||
  fail 'hermes install missing after dual install'
[ -d "$test_home/.local/state/terrahash-dotfiles/cursor-skills/managed" ] ||
  fail 'cursor ownership state missing'
[ -d "$test_home/.local/state/terrahash-dotfiles/hermes-skills/managed" ] ||
  fail 'hermes ownership state missing'

printf '%s\n' 'All isolated Hermes skills tests passed.'
