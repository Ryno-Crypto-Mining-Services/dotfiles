#!/usr/bin/env bash

set -eu

repo=$(CDPATH='' cd -P "$(dirname "$0")/.." && pwd -P)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/terrahash-cursor-skills-tests.XXXXXX")
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
}

run_installer() {
  env -i \
    HOME="$test_home" \
    XDG_STATE_HOME="$XDG_STATE_HOME" \
    PATH="$PATH" \
    "$@"
}

file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
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
  cp "$repo/scripts/install-cursor-skills.sh" "$repo/scripts/cursor-skills-helper.py" "$fixture/scripts/"
  chmod +x "$fixture/scripts/install-cursor-skills.sh"
  printf '%s\n' "$fixture"
}

printf '%s\n' 'Cursor skills: validate real vendored payload'
mkdir -p "$tmp/validate-home" "$tmp/validate-state"
env -i \
  HOME="$tmp/validate-home" \
  XDG_STATE_HOME="$tmp/validate-state" \
  PATH="$PATH" \
  python3 "$repo/scripts/cursor-skills-helper.py" \
  --repo-root "$repo" \
  --manifest "$repo/agent-skills/sources.json" \
  --validate-only >/dev/null || fail 'real sources.json failed validation'

printf '%s\n' 'Cursor skills: fresh install, idempotent rerun, dry-run writes'
fixture=$(setup_fixture_repo 'fresh')
write_skill_tree "$fixture" 'demo-skill' '# Demo' '#!/bin/sh\necho ok'
write_manifest "$fixture"
new_home 'cursor fresh'
run_installer "$fixture/scripts/install-cursor-skills.sh" --dry-run >/dev/null
[ ! -e "$test_home/.cursor" ] || fail 'dry-run created ~/.cursor'
[ ! -e "$test_home/.local" ] || fail 'dry-run created state under HOME'
run_installer "$fixture/scripts/install-cursor-skills.sh" >/dev/null
[ -f "$test_home/.cursor/skills/demo-skill/SKILL.md" ] || fail 'skill was not installed'
[ -x "$test_home/.cursor/skills/demo-skill/run.sh" ] || fail 'executable bit was not preserved'
[ "$(file_mode "$test_home/.local/state/terrahash-dotfiles/cursor-skills")" = 700 ] ||
  fail 'cursor-skills state directory is not private'
first_skill=$(cat "$test_home/.cursor/skills/demo-skill/SKILL.md")
first_owner=$(cat "$test_home/.local/state/terrahash-dotfiles/cursor-skills/managed/demo-skill.json")
run_installer "$fixture/scripts/install-cursor-skills.sh" >/dev/null
[ "$first_skill" = "$(cat "$test_home/.cursor/skills/demo-skill/SKILL.md")" ] ||
  fail 'idempotent install changed skill content'
[ "$first_owner" = "$(cat "$test_home/.local/state/terrahash-dotfiles/cursor-skills/managed/demo-skill.json")" ] ||
  fail 'idempotent install changed ownership state'
before_dry=$(find "$test_home" -type f | wc -l | tr -d ' ')
run_installer "$fixture/scripts/install-cursor-skills.sh" --dry-run >/dev/null
after_dry=$(find "$test_home" -type f | wc -l | tr -d ' ')
[ "$before_dry" = "$after_dry" ] || fail 'post-install dry-run wrote files'

printf '%s\n' 'Cursor skills: invoke from another working directory and paths with spaces'
space_fixture=$tmp/'fixture with spaces'
mkdir -p "$space_fixture/scripts" "$space_fixture/agent-skills"
cp "$repo/scripts/install-cursor-skills.sh" "$repo/scripts/cursor-skills-helper.py" "$space_fixture/scripts/"
chmod +x "$space_fixture/scripts/install-cursor-skills.sh"
write_skill_tree "$space_fixture" 'space-skill' '# Space'
write_manifest "$space_fixture"
new_home 'space home'
(
  CDPATH='' cd "$tmp"
  env -i HOME="$test_home" XDG_STATE_HOME="$test_home/.local/state" PATH="$PATH" \
    "$space_fixture/scripts/install-cursor-skills.sh" >/dev/null
) || fail 'installer failed when invoked from another directory'
[ -f "$test_home/.cursor/skills/space-skill/SKILL.md" ] ||
  fail 'space-path checkout did not install'

printf '%s\n' 'Cursor skills: invalid JSON / unsupported schema / unsafe paths'
bad=$tmp/bad-manifest
mkdir -p "$bad/agent-skills/vendor/langchain"
cp "$repo/scripts/cursor-skills-helper.py" "$bad/scripts/" 2>/dev/null || mkdir -p "$bad/scripts"
cp "$repo/scripts/install-cursor-skills.sh" "$repo/scripts/cursor-skills-helper.py" "$bad/scripts/"
chmod +x "$bad/scripts/install-cursor-skills.sh"
printf '{not-json\n' >"$bad/agent-skills/sources.json"
new_home 'bad json'
if run_installer "$bad/scripts/install-cursor-skills.sh" --dry-run >/dev/null 2>&1; then
  fail 'installer accepted invalid JSON'
fi
printf '%s\n' '{"schema_version":999,"upstreams":{},"skills":[]}' >"$bad/agent-skills/sources.json"
if run_installer "$bad/scripts/install-cursor-skills.sh" --dry-run >/dev/null 2>&1; then
  fail 'installer accepted unsupported schema'
fi
write_skill_tree "$bad" 'safe' '# Safe'
write_manifest "$bad"
python3 - "$bad/agent-skills/sources.json" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
data = json.loads(path.read_text())
data["skills"][0]["files"][0]["path"] = "../escape"
path.write_text(json.dumps(data))
PY
if run_installer "$bad/scripts/install-cursor-skills.sh" --dry-run >/dev/null 2>&1; then
  fail 'installer accepted path traversal in file path'
fi
write_skill_tree "$bad" 'safe' '# Safe'
write_manifest "$bad"
python3 - "$bad/agent-skills/sources.json" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
data = json.loads(path.read_text())
data["skills"][0]["destination"] = ".hidden-skill"
path.write_text(json.dumps(data))
PY
if run_installer "$bad/scripts/install-cursor-skills.sh" --dry-run >/dev/null 2>&1; then
  fail 'installer accepted a hidden destination name'
fi
write_skill_tree "$bad" 'dup-a' '# A'
write_skill_tree "$bad" 'dup-b' '# B'
write_manifest "$bad"
python3 - "$bad/agent-skills/sources.json" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
data = json.loads(path.read_text())
data["skills"][1]["destination"] = data["skills"][0]["destination"]
path.write_text(json.dumps(data))
PY
if run_installer "$bad/scripts/install-cursor-skills.sh" --dry-run >/dev/null 2>&1; then
  fail 'installer accepted duplicate destinations'
fi

validate_only() {
  root=$1
  env -i \
    HOME="$tmp/validate-home" \
    XDG_STATE_HOME="$tmp/validate-state" \
    PATH="$PATH" \
    python3 "$root/scripts/cursor-skills-helper.py" \
    --repo-root "$root" \
    --manifest "$root/agent-skills/sources.json" \
    --validate-only
}

printf '%s\n' 'Cursor skills: missing, unexpected, tampered, executable-mode'
mkdir -p "$tmp/validate-home" "$tmp/validate-state"
tamper=$(setup_fixture_repo 'tamper')
write_skill_tree "$tamper" 'tamper-skill' '# Tamper' '#!/bin/sh\ntrue'
write_manifest "$tamper"
printf 'extra\n' >"$tamper/agent-skills/vendor/langchain/tamper-skill/extra.txt"
if validate_only "$tamper" >/dev/null 2>&1; then
  fail 'unexpected vendored file was accepted'
fi
rm -f "$tamper/agent-skills/vendor/langchain/tamper-skill/extra.txt"
write_manifest "$tamper"
rm -f "$tamper/agent-skills/vendor/langchain/tamper-skill/references/note.md"
if validate_only "$tamper" >/dev/null 2>&1; then
  fail 'missing vendored file was accepted'
fi
write_skill_tree "$tamper" 'tamper-skill' '# Tamper' '#!/bin/sh\ntrue'
write_manifest "$tamper"
printf 'changed\n' >"$tamper/agent-skills/vendor/langchain/tamper-skill/SKILL.md"
if validate_only "$tamper" >/dev/null 2>&1; then
  fail 'hash mismatch was accepted'
fi
write_skill_tree "$tamper" 'tamper-skill' '# Tamper' '#!/bin/sh\ntrue'
write_manifest "$tamper"
chmod 644 "$tamper/agent-skills/vendor/langchain/tamper-skill/run.sh"
if validate_only "$tamper" >/dev/null 2>&1; then
  fail 'executable-mode mismatch was accepted'
fi

printf '%s\n' 'Cursor skills: unmanaged conflict, local modification, upgrade, retained obsolete'
fixture=$(setup_fixture_repo 'lifecycle')
write_skill_tree "$fixture" 'life-skill' '# Life v1' '#!/bin/sh\necho v1'
write_manifest "$fixture" 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
new_home 'lifecycle'
mkdir -p "$test_home/.cursor/skills/life-skill"
printf 'unmanaged\n' >"$test_home/.cursor/skills/life-skill/SKILL.md"
if run_installer "$fixture/scripts/install-cursor-skills.sh" >/dev/null 2>&1; then
  fail 'installer adopted an unmanaged destination'
fi
[ "$(cat "$test_home/.cursor/skills/life-skill/SKILL.md")" = unmanaged ] ||
  fail 'unmanaged destination was modified'
rm -rf "$test_home/.cursor/skills/life-skill"
run_installer "$fixture/scripts/install-cursor-skills.sh" >/dev/null
printf 'edited\n' >>"$test_home/.cursor/skills/life-skill/SKILL.md"
if run_installer "$fixture/scripts/install-cursor-skills.sh" >/dev/null 2>&1; then
  fail 'installer overwrote a locally modified managed skill'
fi
# Restore matching content for upgrade path
write_skill_tree "$fixture" 'life-skill' '# Life v1' '#!/bin/sh\necho v1'
write_manifest "$fixture" 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
# Reinstall cleanly
rm -rf "$test_home/.cursor/skills/life-skill"
rm -f "$test_home/.local/state/terrahash-dotfiles/cursor-skills/managed/life-skill.json"
run_installer "$fixture/scripts/install-cursor-skills.sh" >/dev/null
write_skill_tree "$fixture" 'life-skill' '# Life v2' '#!/bin/sh\necho v2'
write_manifest "$fixture" 'cccccccccccccccccccccccccccccccccccccccc'
run_installer "$fixture/scripts/install-cursor-skills.sh" >/dev/null
grep -F '# Life v2' "$test_home/.cursor/skills/life-skill/SKILL.md" >/dev/null ||
  fail 'managed upgrade did not apply new content'
[ -d "$test_home/.local/state/terrahash-dotfiles/cursor-skills/backups" ] ||
  fail 'upgrade did not create backups directory'
# Remove from manifest; destination should remain owned
rm -rf "$fixture/agent-skills/vendor/langchain/life-skill"
# Keep an empty declared upstream directory so schema validation stays focused on skills.
mkdir -p "$fixture/agent-skills/vendor/langchain"
write_manifest "$fixture" 'cccccccccccccccccccccccccccccccccccccccc'
out=$(run_installer "$fixture/scripts/install-cursor-skills.sh" --dry-run 2>&1) ||
  fail 'dry-run failed for retained obsolete skill'
printf '%s\n' "$out" | grep -F 'retain' >/dev/null ||
  fail 'dry-run did not report retained obsolete skill'
[ -f "$test_home/.cursor/skills/life-skill/SKILL.md" ] ||
  fail 'obsolete skill destination was deleted'
[ -f "$test_home/.local/state/terrahash-dotfiles/cursor-skills/managed/life-skill.json" ] ||
  fail 'obsolete skill ownership was discarded'

printf '%s\n' 'Cursor skills: unrelated skill untouched, symlink rejection, lock, incomplete recovery'
fixture=$(setup_fixture_repo 'guards')
write_skill_tree "$fixture" 'guard-skill' '# Guard'
write_manifest "$fixture"
new_home 'guards'
mkdir -p "$test_home/.cursor/skills/other-skill"
printf 'leave me\n' >"$test_home/.cursor/skills/other-skill/SKILL.md"
run_installer "$fixture/scripts/install-cursor-skills.sh" >/dev/null
[ "$(cat "$test_home/.cursor/skills/other-skill/SKILL.md")" = 'leave me' ] ||
  fail 'unrelated skill was modified'

new_home 'symlink dest'
mkdir -p "$test_home/.cursor"
ln -s "$test_home/somewhere" "$test_home/.cursor/skills"
if run_installer "$fixture/scripts/install-cursor-skills.sh" >/dev/null 2>&1; then
  fail 'installer followed a symlinked skills root'
fi

vf=$(setup_fixture_repo 'symlink-vendor')
write_skill_tree "$vf" 'sym-skill' '# Sym'
write_manifest "$vf"
ln -sf /etc/passwd "$vf/agent-skills/vendor/langchain/sym-skill/evil"
if validate_only "$vf" >/dev/null 2>&1; then
  fail 'symlink in vendored payload was accepted'
fi

new_home 'lock'
mkdir -p "$test_home/.local/state/terrahash-dotfiles/cursor-skills/lock"
if run_installer "$fixture/scripts/install-cursor-skills.sh" >/dev/null 2>&1; then
  fail 'installer ignored a held cursor-skills lock'
fi
[ ! -e "$test_home/.cursor/skills/guard-skill" ] || fail 'locked install wrote a skill'

new_home 'incomplete'
run_installer "$fixture/scripts/install-cursor-skills.sh" >/dev/null
rm -rf "$test_home/.cursor/skills/guard-skill"
mkdir -p "$test_home/.cursor/skills/.guard-skill.terrahash-incomplete"
printf 'partial\n' >"$test_home/.cursor/skills/.guard-skill.terrahash-incomplete/SKILL.md"
# ownership still present from previous install in this home? recreate cleanly
rm -rf "$test_home/.local/state/terrahash-dotfiles/cursor-skills/managed"
mkdir -p "$test_home/.local/state/terrahash-dotfiles/cursor-skills/managed"
if run_installer "$fixture/scripts/install-cursor-skills.sh" >/dev/null 2>&1; then
  fail 'installer ignored an incomplete installation marker'
fi

printf '%s\n' 'Cursor skills: real vendored payload dry-run and install'
new_home 'real pin'
out=$(run_installer "$repo/scripts/install-cursor-skills.sh" --dry-run 2>&1) ||
  fail 'real-pin dry-run failed'
for expected in \
  agents-langchain langgraph langfuse \
  ecosystem-primer langchain-dependencies langchain-fundamentals langchain-middleware \
  langchain-rag langgraph-fundamentals langgraph-persistence langgraph-human-in-the-loop \
  deep-agents-core deep-agents-memory deep-agents-orchestration; do
  printf '%s\n' "$out" | grep -F "Would install skill: $expected" >/dev/null ||
    fail "real-pin dry-run missing $expected"
done
# langchain-skills plugin skills (including tracing) stay out of the installable set
printf '%s\n' "$out" | grep -F 'Would install skill: langchain-build-agent' >/dev/null &&
  fail 'real-pin dry-run unexpectedly planned langchain-build-agent'
printf '%s\n' "$out" | grep -F 'Would install skill: langchain-agent-tracing' >/dev/null &&
  fail 'real-pin dry-run unexpectedly planned langchain-agent-tracing'
[ ! -e "$test_home/.cursor" ] || fail 'real-pin dry-run created ~/.cursor'
run_installer "$repo/scripts/install-cursor-skills.sh" >/dev/null
[ -f "$test_home/.cursor/skills/agents-langchain/SKILL.md" ] ||
  fail 'agents-langchain was not installed from real payload'
[ -f "$test_home/.cursor/skills/ecosystem-primer/SKILL.md" ] ||
  fail 'ecosystem-primer was not installed from skills-benchmarks'
[ -f "$test_home/.cursor/skills/langchain-fundamentals/SKILL.md" ] ||
  fail 'langchain-fundamentals was not installed from skills-benchmarks'
[ -f "$test_home/.cursor/skills/deep-agents-orchestration/SKILL.md" ] ||
  fail 'deep-agents-orchestration was not installed from skills-benchmarks'
[ ! -e "$test_home/.cursor/skills/langchain-eval-engineering" ] ||
  fail 'langchain-eval-engineering was incorrectly installed from langchain-skills'
[ ! -e "$test_home/.cursor/skills/langchain-agent-tracing" ] ||
  fail 'langchain-agent-tracing was incorrectly installed'
[ -f "$test_home/.cursor/skills/agents-langchain/references/rag.md" ] ||
  fail 'agents-langchain references were not installed'
# LangSmith skills must remain absent
[ ! -e "$test_home/.cursor/skills/langsmith-trace" ] ||
  fail 'langsmith-trace was incorrectly installed'

printf '%s\n' 'Cursor skills: baseline install.sh unchanged by skills tooling presence'
new_home 'baseline still works'
env -i HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" GIT_CONFIG_NOSYSTEM=1 PATH="$PATH" \
  "$repo/install.sh" --dry-run >/dev/null
[ ! -e "$test_home/.bashrc" ] || fail 'baseline dry-run created bashrc after skills work'

printf '%s\n' 'All isolated Cursor skills tests passed.'
