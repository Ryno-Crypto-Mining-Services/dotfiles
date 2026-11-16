#!/usr/bin/env python3
"""Offline agent-skills installer helper for terrahash-dotfiles.

Validates agent-skills/sources.json and installs ordinary copies into a
host-specific skills library:

- cursor → $HOME/.cursor/skills/<name>/
- hermes → ${HERMES_HOME:-$HOME/.hermes}/skills/<name>/

Ownership state lives under
${XDG_STATE_HOME:-$HOME/.local/state}/terrahash-dotfiles/<target>-skills/.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import stat
import sys
import tempfile
from pathlib import Path
from typing import Any


SCHEMA_VERSION = 2
OWNER_VERSION = 1
VENDOR_ROOT_PREFIX = "agent-skills/vendor/"
VENDOR_ROOT_ALLOWFILES = frozenset({"LICENSE", "NOTICE", "README.md"})

TARGETS: dict[str, dict[str, str]] = {
    "cursor": {
        "label": "Cursor",
        "state_dirname": "cursor-skills",
        "managed_kind": "terrahash-dotfiles-cursor-skills",
        "skills_label": ".cursor/skills",
    },
    "hermes": {
        "label": "Hermes",
        "state_dirname": "hermes-skills",
        "managed_kind": "terrahash-dotfiles-hermes-skills",
        "skills_label": "$HERMES_HOME/skills (default ~/.hermes/skills)",
    },
}


class InstallError(Exception):
    """Fail-closed installer error."""


def die(message: str) -> None:
    raise InstallError(message)


def eprint(message: str) -> None:
    print(message, file=sys.stderr)


def load_json(path: Path) -> Any:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        die(f"Cannot read {path}: {exc}")
    try:
        return json.loads(text)
    except json.JSONDecodeError as exc:
        die(f"Invalid JSON in {path}: {exc}")


def write_json_atomic(path: Path, payload: Any, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    tmp_path = Path(tmp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, indent=2, sort_keys=True)
            handle.write("\n")
        os.chmod(tmp_path, mode)
        os.replace(tmp_path, path)
    except Exception:
        if tmp_path.exists():
            tmp_path.unlink()
        raise


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def is_executable(mode: int) -> bool:
    return bool(mode & (stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH))


def ensure_no_symlink(path: Path, label: str) -> None:
    if path.is_symlink():
        die(f"Refusing symlinked {label}: {path}")


def validate_home(home: Path) -> Path:
    if not str(home):
        die("HOME is empty.")
    if not home.is_absolute():
        die("HOME must be an absolute path.")
    if "\n" in str(home) or "\r" in str(home):
        die("HOME cannot contain a newline.")
    ensure_no_symlink(home, "HOME")
    if not home.is_dir():
        die("HOME must be an accessible directory.")
    if not os.access(home, os.R_OK | os.W_OK | os.X_OK):
        die("HOME must be an accessible, writable directory.")
    resolved = home.resolve()
    if resolved == Path("/"):
        die("Refusing HOME that resolves to /.")
    return resolved


def validate_state_home(raw: str | None, home: Path) -> Path:
    if raw is None or raw == "":
        return home / ".local" / "state"
    state = Path(raw)
    if not state.is_absolute():
        die("XDG_STATE_HOME must be absolute when set.")
    if "\n" in str(state) or "\r" in str(state):
        die("XDG_STATE_HOME cannot contain a newline.")
    if state == Path("/"):
        die("Refusing to use / as XDG_STATE_HOME.")
    ensure_no_symlink(state, "XDG_STATE_HOME")
    return state


def normalize_rel_path(value: str) -> str:
    if not isinstance(value, str) or value == "":
        die("File paths must be non-empty relative strings.")
    if value.startswith("/") or value.startswith("\\"):
        die(f"Absolute paths are not allowed: {value}")
    parts = value.replace("\\", "/").split("/")
    if any(part in ("", ".", "..") for part in parts):
        die(f"Unsafe path component in: {value}")
    return "/".join(parts)


def validate_destination_name(name: str) -> str:
    if not isinstance(name, str) or name == "":
        die("Destination names must be non-empty.")
    if name in (".", ".."):
        die(f"Unsafe destination name: {name}")
    if "/" in name or "\\" in name or "\0" in name:
        die(f"Destination names cannot contain path separators: {name}")
    if name.startswith(".") and name not in (".cursor",):
        # Allow ordinary skill names; reject hidden/relative tricks.
        if name in (".", "..") or "/" in name:
            die(f"Unsafe destination name: {name}")
    return name


def validate_license_info(license_info: Any, label: str) -> dict[str, str]:
    if not isinstance(license_info, dict):
        die(f"{label} must be an object.")
    for key in ("spdx_id", "name", "path", "copyright"):
        if not isinstance(license_info.get(key), str) or not license_info[key]:
            die(f"{label}.{key} must be a non-empty string.")
    return {
        "spdx_id": license_info["spdx_id"],
        "name": license_info["name"],
        "path": license_info["path"],
        "copyright": license_info["copyright"],
    }


def validate_commit(commit: Any, label: str) -> str:
    if not isinstance(commit, str) or len(commit) != 40 or any(
        ch not in "0123456789abcdef" for ch in commit.lower()
    ):
        die(f"{label} must be a 40-character hexadecimal SHA.")
    return commit.lower()


def validate_upstreams(manifest: dict[str, Any]) -> dict[str, dict[str, Any]]:
    upstreams = manifest.get("upstreams")
    if not isinstance(upstreams, dict) or not upstreams:
        die("Manifest upstreams must be a non-empty object.")
    normalized: dict[str, dict[str, Any]] = {}
    for key, entry in sorted(upstreams.items()):
        if not isinstance(key, str) or not key or "/" in key or key in (".", ".."):
            die(f"Invalid upstream key: {key!r}")
        if not isinstance(entry, dict):
            die(f"upstreams[{key}] must be an object.")
        repository = entry.get("repository")
        if not isinstance(repository, str) or not repository.startswith("https://"):
            die(f"upstreams[{key}].repository must be an https URL string.")
        commit = validate_commit(entry.get("commit"), f"upstreams[{key}].commit")
        license_info = validate_license_info(entry.get("license"), f"upstreams[{key}].license")
        normalized[key] = {
            "repository": repository,
            "commit": commit,
            "license": license_info,
        }
    return normalized


def validate_vendor_rel(vendor_path: str, upstream_key: str) -> str:
    vendor_rel = normalize_rel_path(vendor_path)
    expected_prefix = f"{VENDOR_ROOT_PREFIX}{upstream_key}/"
    if not vendor_rel.startswith(expected_prefix):
        die(
            f"vendor_path must be under {expected_prefix}: {vendor_path}"
        )
    remainder = vendor_rel[len(expected_prefix) :]
    if not remainder or "/" in remainder or remainder in (".", ".."):
        die(f"vendor_path must name a single skill directory: {vendor_path}")
    return vendor_rel


def validate_manifest(manifest: Any, repo_root: Path) -> dict[str, Any]:
    if not isinstance(manifest, dict):
        die("Manifest root must be a JSON object.")
    schema_version = manifest.get("schema_version")
    if schema_version != SCHEMA_VERSION:
        die(f"Unsupported schema_version: {schema_version!r} (expected {SCHEMA_VERSION}).")

    upstreams = validate_upstreams(manifest)

    skills = manifest.get("skills")
    if not isinstance(skills, list):
        die("Manifest skills must be an array.")

    seen_names: set[str] = set()
    seen_destinations: set[str] = set()
    skills_by_upstream: dict[str, set[str]] = {key: set() for key in upstreams}
    normalized_skills: list[dict[str, Any]] = []

    for index, skill in enumerate(skills):
        if not isinstance(skill, dict):
            die(f"skills[{index}] must be an object.")
        name = skill.get("name")
        upstream_key = skill.get("upstream")
        upstream_path = skill.get("upstream_path")
        vendor_path = skill.get("vendor_path")
        destination = skill.get("destination")
        files = skill.get("files")
        if not isinstance(name, str) or not name:
            die(f"skills[{index}].name must be a non-empty string.")
        if name in seen_names:
            die(f"Duplicate skill name: {name}")
        seen_names.add(name)
        if not isinstance(upstream_key, str) or upstream_key not in upstreams:
            die(f"skills[{index}].upstream must name a declared upstream.")
        if not isinstance(upstream_path, str) or not upstream_path:
            die(f"skills[{index}].upstream_path must be a non-empty string.")
        normalize_rel_path(upstream_path)
        if not isinstance(vendor_path, str) or not vendor_path:
            die(f"skills[{index}].vendor_path must be a non-empty string.")
        vendor_rel = validate_vendor_rel(vendor_path, upstream_key)
        dest = validate_destination_name(destination if isinstance(destination, str) else "")
        if dest in seen_destinations:
            die(f"Duplicate destination: {dest}")
        seen_destinations.add(dest)
        if not isinstance(files, list) or not files:
            die(f"skills[{index}].files must be a non-empty array.")

        file_map: dict[str, dict[str, Any]] = {}
        for file_index, entry in enumerate(files):
            if not isinstance(entry, dict):
                die(f"skills[{index}].files[{file_index}] must be an object.")
            rel = normalize_rel_path(str(entry.get("path", "")))
            digest = entry.get("sha256")
            executable = entry.get("executable")
            if not isinstance(digest, str) or len(digest) != 64 or any(
                ch not in "0123456789abcdef" for ch in digest.lower()
            ):
                die(f"Invalid sha256 for {name}/{rel}")
            if not isinstance(executable, bool):
                die(f"executable must be a boolean for {name}/{rel}")
            if rel in file_map:
                die(f"Duplicate file path in skill {name}: {rel}")
            file_map[rel] = {
                "path": rel,
                "sha256": digest.lower(),
                "executable": executable,
            }

        vendor_dir = repo_root / vendor_rel
        ensure_no_symlink(vendor_dir, "vendored skill directory")
        if not vendor_dir.is_dir():
            die(f"Missing vendored skill directory: {vendor_rel}")

        actual_files: dict[str, Path] = {}
        for root, dirnames, filenames in os.walk(vendor_dir, followlinks=False):
            root_path = Path(root)
            for dirname in list(dirnames):
                child = root_path / dirname
                if child.is_symlink():
                    die(f"Symlink directory in vendored payload: {child}")
            for filename in filenames:
                child = root_path / filename
                if child.is_symlink():
                    die(f"Symlink file in vendored payload: {child}")
                if not child.is_file():
                    die(f"Special file in vendored payload: {child}")
                rel = child.relative_to(vendor_dir).as_posix()
                actual_files[rel] = child

        expected = set(file_map)
        actual = set(actual_files)
        missing = sorted(expected - actual)
        unexpected = sorted(actual - expected)
        if missing:
            die(f"Missing vendored files in {name}: {', '.join(missing)}")
        if unexpected:
            die(f"Unexpected vendored files in {name}: {', '.join(unexpected)}")

        for rel, meta in sorted(file_map.items()):
            path = actual_files[rel]
            digest = sha256_file(path)
            if digest != meta["sha256"]:
                die(f"Hash mismatch for {name}/{rel}")
            mode = path.stat().st_mode
            if is_executable(mode) != meta["executable"]:
                die(
                    f"Executable-mode mismatch for {name}/{rel}: "
                    f"expected executable={meta['executable']}"
                )

        skills_by_upstream[upstream_key].add(Path(vendor_rel).name)
        upstream_meta = upstreams[upstream_key]
        normalized_skills.append(
            {
                "name": name,
                "upstream": upstream_key,
                "upstream_path": normalize_rel_path(upstream_path),
                "upstream_repository": upstream_meta["repository"],
                "upstream_commit": upstream_meta["commit"],
                "vendor_path": vendor_rel,
                "destination": dest,
                "files": [file_map[key] for key in sorted(file_map)],
                "vendor_dir": vendor_dir,
            }
        )

    vendor_root = repo_root / "agent-skills" / "vendor"
    if vendor_root.exists():
        ensure_no_symlink(vendor_root, "vendor root")
        if vendor_root.is_dir():
            for source_dir in sorted(vendor_root.iterdir()):
                if source_dir.name.startswith("."):
                    continue
                if source_dir.is_file():
                    die(f"Unexpected file directly under vendor root: {source_dir.name}")
                if not source_dir.is_dir():
                    die(f"Unexpected entry under vendor root: {source_dir.name}")
                if source_dir.name not in upstreams:
                    die(
                        "Unexpected vendored source directory not listed in upstreams: "
                        f"{source_dir.name}"
                    )
                known = skills_by_upstream[source_dir.name]
                for child in sorted(source_dir.iterdir()):
                    if child.name.startswith("."):
                        continue
                    if child.is_file() and child.name in VENDOR_ROOT_ALLOWFILES:
                        continue
                    if child.is_dir():
                        if child.name not in known:
                            die(
                                "Unexpected vendored skill directory not listed in manifest: "
                                f"{source_dir.name}/{child.name}"
                            )
                        continue
                    die(
                        "Unexpected file in vendored source directory: "
                        f"{source_dir.name}/{child.name}"
                    )

    return {
        "schema_version": SCHEMA_VERSION,
        "upstreams": upstreams,
        "skills": normalized_skills,
        "requested_skills": manifest.get("requested_skills", []),
    }


def validate_hermes_home(raw: str | None, home: Path) -> Path:
    if raw is None or raw == "":
        return home / ".hermes"
    hermes_home = Path(raw)
    if not hermes_home.is_absolute():
        die("HERMES_HOME must be absolute when set.")
    if "\n" in str(hermes_home) or "\r" in str(hermes_home):
        die("HERMES_HOME cannot contain a newline.")
    if hermes_home == Path("/"):
        die("Refusing to use / as HERMES_HOME.")
    ensure_no_symlink(hermes_home, "HERMES_HOME")
    return hermes_home


def resolve_skills_root(target: str, home: Path) -> tuple[Path, Path]:
    """Return (skills_root, label_parent) for symlink/ancestor checks."""
    if target == "cursor":
        parent = home / ".cursor"
        return parent / "skills", parent
    if target == "hermes":
        hermes_home = validate_hermes_home(os.environ.get("HERMES_HOME"), home)
        return hermes_home / "skills", hermes_home
    die(f"Unsupported install target: {target}")


def state_paths(state_home: Path, repo_root: Path, target: str) -> dict[str, Path]:
    config = TARGETS[target]
    root = state_home / "terrahash-dotfiles" / config["state_dirname"]
    if str(root).startswith(str(repo_root) + os.sep):
        die(f"{config['label']} skills state must be outside the checkout.")
    return {
        "root": root,
        "managed": root / "managed",
        "backups": root / "backups",
        "lock": root / "lock",
        "staging": root / "staging",
    }


def ensure_safe_ancestors(path: Path, stop_at: Path) -> None:
    current = path
    while True:
        ensure_no_symlink(current, "path")
        if current == stop_at or current.parent == current:
            break
        current = current.parent


def inventory_directory(directory: Path) -> dict[str, dict[str, Any]]:
    files: dict[str, dict[str, Any]] = {}
    for root, dirnames, filenames in os.walk(directory, followlinks=False):
        root_path = Path(root)
        for dirname in list(dirnames):
            child = root_path / dirname
            if child.is_symlink():
                die(f"Symlink directory in installed skill: {child}")
        for filename in filenames:
            child = root_path / filename
            if child.is_symlink():
                die(f"Symlink file in installed skill: {child}")
            if not child.is_file():
                die(f"Special file in installed skill: {child}")
            rel = child.relative_to(directory).as_posix()
            files[rel] = {
                "path": rel,
                "sha256": sha256_file(child),
                "executable": is_executable(child.stat().st_mode),
            }
    return files


def files_equal(left: list[dict[str, Any]], right: dict[str, dict[str, Any]]) -> bool:
    left_map = {entry["path"]: entry for entry in left}
    if set(left_map) != set(right):
        return False
    for path, meta in left_map.items():
        other = right[path]
        if meta["sha256"] != other["sha256"] or meta["executable"] != other["executable"]:
            return False
    return True


def ownership_path(paths: dict[str, Path], destination: str) -> Path:
    return paths["managed"] / f"{destination}.json"


def read_ownership(
    paths: dict[str, Path], destination: str, managed_kind: str
) -> dict[str, Any] | None:
    path = ownership_path(paths, destination)
    if path.is_symlink():
        die(f"Refusing symlinked ownership state: {path}")
    if not path.exists():
        return None
    if not path.is_file():
        die(f"Malformed ownership state: {path}")
    data = load_json(path)
    if not isinstance(data, dict):
        die(f"Malformed ownership state: {path}")
    if data.get("kind") != managed_kind or data.get("version") != OWNER_VERSION:
        die(f"Unrecognized ownership state: {path}")
    return data


def write_ownership(paths: dict[str, Path], record: dict[str, Any]) -> None:
    paths["managed"].mkdir(parents=True, exist_ok=True)
    os.chmod(paths["root"], 0o700)
    os.chmod(paths["managed"], 0o700)
    write_json_atomic(ownership_path(paths, record["destination"]), record, mode=0o600)


def list_owned_destinations(paths: dict[str, Path]) -> list[str]:
    managed = paths["managed"]
    if not managed.exists():
        return []
    ensure_no_symlink(managed, "managed state directory")
    names: list[str] = []
    for child in sorted(managed.iterdir()):
        if child.is_symlink():
            die(f"Refusing symlinked ownership state: {child}")
        if child.is_file() and child.suffix == ".json":
            names.append(child.stem)
    return names


def backup_skill(paths: dict[str, Path], destination: str, source: Path) -> Path:
    paths["backups"].mkdir(parents=True, exist_ok=True)
    os.chmod(paths["backups"], 0o700)
    stamp = tempfile.mkdtemp(prefix=f"{destination}.", dir=str(paths["backups"]))
    backup = Path(stamp)
    # mkdtemp already created; replace with a copy of the skill tree.
    backup.rmdir()
    shutil.copytree(source, backup, symlinks=False)
    return backup


def copy_skill_tree(src: Path, dest: Path, files: list[dict[str, Any]]) -> None:
    if dest.exists():
        die(f"Staging destination already exists: {dest}")
    dest.mkdir(parents=True)
    for entry in files:
        rel = entry["path"]
        source_file = src / rel
        target_file = dest / rel
        target_file.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source_file, target_file)
        mode = 0o755 if entry["executable"] else 0o644
        os.chmod(target_file, mode)


class Lock:
    def __init__(self, lock_dir: Path, dry_run: bool) -> None:
        self.lock_dir = lock_dir
        self.dry_run = dry_run
        self.held = False

    def acquire(self) -> None:
        if self.dry_run:
            if self.lock_dir.exists():
                die(f"An operation may be active: {self.lock_dir}")
            return
        self.lock_dir.parent.mkdir(parents=True, exist_ok=True)
        os.chmod(self.lock_dir.parent, 0o700)
        try:
            os.mkdir(self.lock_dir)
        except FileExistsError:
            die(
                "Another operation may be active; if it is not, remove the stale "
                f"lock directory: {self.lock_dir}"
            )
        os.chmod(self.lock_dir, 0o700)
        self.held = True

    def release(self) -> None:
        if self.held and self.lock_dir.exists():
            try:
                self.lock_dir.rmdir()
            except OSError:
                pass
            self.held = False


def plan_actions(
    manifest: dict[str, Any],
    paths: dict[str, Path],
    skills_root: Path,
    managed_kind: str,
) -> list[dict[str, Any]]:
    actions: list[dict[str, Any]] = []
    desired = {skill["destination"]: skill for skill in manifest["skills"]}

    for destination, skill in desired.items():
        dest_dir = skills_root / destination
        incomplete = dest_dir.with_name(f".{destination}.terrahash-incomplete")
        ownership = read_ownership(paths, destination, managed_kind)

        if incomplete.exists() or incomplete.is_symlink():
            actions.append(
                {
                    "destination": destination,
                    "action": "conflict",
                    "reason": (
                        f"Incomplete installation marker present: {incomplete}. "
                        "Remove the incomplete directory after inspection, then rerun."
                    ),
                }
            )
            continue

        if not dest_dir.exists() and not dest_dir.is_symlink():
            if ownership is not None:
                actions.append(
                    {
                        "destination": destination,
                        "action": "conflict",
                        "reason": (
                            "Ownership state exists but destination is missing; "
                            "resolve manually before installing."
                        ),
                    }
                )
            else:
                actions.append({"destination": destination, "action": "install", "skill": skill})
            continue

        ensure_no_symlink(dest_dir, "skill destination")
        if not dest_dir.is_dir():
            actions.append(
                {
                    "destination": destination,
                    "action": "conflict",
                    "reason": f"Destination exists and is not a directory: {dest_dir}",
                }
            )
            continue

        if ownership is None:
            actions.append(
                {
                    "destination": destination,
                    "action": "conflict",
                    "reason": (
                        "Destination exists without valid ownership state; "
                        "failing closed without adopting it."
                    ),
                }
            )
            continue

        actual = inventory_directory(dest_dir)
        recorded_files = ownership.get("files")
        if not isinstance(recorded_files, list):
            die(f"Malformed ownership inventory for {destination}")
        if not files_equal(recorded_files, actual):
            actions.append(
                {
                    "destination": destination,
                    "action": "conflict",
                    "reason": (
                        "Managed destination has local modifications, missing files, "
                        "extra files, or mode changes."
                    ),
                }
            )
            continue

        if files_equal(skill["files"], actual):
            actions.append({"destination": destination, "action": "unchanged", "skill": skill})
            continue

        # On-disk content matches recorded ownership, but the desired vendored
        # payload differs: permit an explicit installer-run update.
        actions.append({"destination": destination, "action": "update", "skill": skill})

    for destination in list_owned_destinations(paths):
        if destination in desired:
            continue
        actions.append(
            {
                "destination": destination,
                "action": "retained",
                "reason": (
                    "Previously managed skill is no longer in the manifest; "
                    "left installed and owned (no automatic prune)."
                ),
            }
        )

    return actions


def apply_action(
    action: dict[str, Any],
    manifest: dict[str, Any],
    paths: dict[str, Path],
    skills_root: Path,
    managed_kind: str,
) -> None:
    kind = action["action"]
    destination = action["destination"]
    if kind in ("unchanged", "retained", "conflict"):
        return
    skill = action["skill"]
    dest_dir = skills_root / destination
    incomplete = dest_dir.with_name(f".{destination}.terrahash-incomplete")
    staging_root = paths["staging"]
    paths["root"].mkdir(parents=True, exist_ok=True)
    staging_root.mkdir(parents=True, exist_ok=True)
    skills_root.mkdir(parents=True, exist_ok=True)
    os.chmod(paths["root"], 0o700)
    os.chmod(staging_root, 0o700)

    if incomplete.exists():
        die(f"Incomplete installation marker already present: {incomplete}")

    staging = staging_root / destination
    if staging.exists():
        shutil.rmtree(staging)
    copy_skill_tree(skill["vendor_dir"], staging, skill["files"])

    # Move staging into an incomplete marker beside the destination, then swap.
    if incomplete.exists():
        shutil.rmtree(incomplete)
    os.rename(staging, incomplete)

    if kind == "update":
        backup_skill(paths, destination, dest_dir)
        replaced = dest_dir.with_name(f".{destination}.terrahash-replaced")
        if replaced.exists():
            shutil.rmtree(replaced)
        os.rename(dest_dir, replaced)
        try:
            os.rename(incomplete, dest_dir)
        except OSError:
            # Attempt to restore previous directory.
            if not dest_dir.exists() and replaced.exists():
                os.rename(replaced, dest_dir)
            die(f"Failed to activate updated skill directory: {destination}")
        shutil.rmtree(replaced)
    else:
        skills_root.mkdir(parents=True, exist_ok=True)
        try:
            os.rename(incomplete, dest_dir)
        except OSError as exc:
            die(f"Failed to install skill directory {destination}: {exc}")

    record = {
        "kind": managed_kind,
        "version": OWNER_VERSION,
        "name": skill["name"],
        "destination": destination,
        "upstream": skill["upstream"],
        "upstream_repository": skill["upstream_repository"],
        "upstream_commit": skill["upstream_commit"],
        "vendor_path": skill["vendor_path"],
        "files": skill["files"],
    }
    write_ownership(paths, record)


def print_plan(actions: list[dict[str, Any]], label: str) -> None:
    if not actions:
        print(f"No managed {label} skills to install.")
        return
    for action in actions:
        destination = action["destination"]
        kind = action["action"]
        if kind == "install":
            print(f"Would install skill: {destination}")
        elif kind == "update":
            print(f"Would update managed skill: {destination}")
        elif kind == "unchanged":
            print(f"Would leave unchanged: {destination}")
        elif kind == "retained":
            print(f"Would retain obsolete managed skill: {destination}")
            print(f"  {action['reason']}")
        elif kind == "conflict":
            print(f"Conflict for skill: {destination}")
            print(f"  {action['reason']}")
        else:
            die(f"Unknown planned action: {kind}")


def print_result(actions: list[dict[str, Any]], label: str) -> None:
    if not actions:
        print(f"No managed {label} skills to install.")
        return
    for action in actions:
        destination = action["destination"]
        kind = action["action"]
        if kind == "install":
            print(f"Installed skill: {destination}")
        elif kind == "update":
            print(f"Updated managed skill: {destination}")
        elif kind == "unchanged":
            print(f"Unchanged: {destination}")
        elif kind == "retained":
            print(f"Retained obsolete managed skill: {destination}")
            print(f"  {action['reason']}")
        elif kind == "conflict":
            print(f"Conflict for skill: {destination}")
            print(f"  {action['reason']}")
        else:
            die(f"Unknown action: {kind}")


def run(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--repo-root", required=True)
    parser.add_argument("--manifest", required=True)
    parser.add_argument(
        "--target",
        choices=sorted(TARGETS),
        default="cursor",
        help="Host skills library to install into (default: cursor)",
    )
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--validate-only", action="store_true")
    args = parser.parse_args(argv)

    target = args.target
    if target not in TARGETS:
        die(f"Unsupported install target: {target}")
    target_config = TARGETS[target]
    label = target_config["label"]
    managed_kind = target_config["managed_kind"]

    repo_root = Path(args.repo_root)
    if not repo_root.is_absolute():
        die("--repo-root must be absolute.")
    ensure_no_symlink(repo_root, "repository root")
    repo_root = repo_root.resolve()

    home = validate_home(Path(os.environ.get("HOME", "")))
    state_home = validate_state_home(os.environ.get("XDG_STATE_HOME"), home)
    paths = state_paths(state_home, repo_root, target)

    for key in ("root", "managed", "backups", "lock", "staging"):
        ensure_no_symlink(paths[key], key)

    manifest_path = Path(args.manifest)
    if not manifest_path.is_absolute():
        die("--manifest must be absolute.")
    ensure_no_symlink(manifest_path, "manifest")
    manifest = validate_manifest(load_json(manifest_path), repo_root)

    if args.validate_only:
        print(f"Manifest OK: {len(manifest['skills'])} skill(s).")
        return 0

    skills_root, skills_parent = resolve_skills_root(target, home)
    ensure_no_symlink(skills_parent, target_config["skills_label"].split("/")[0])
    ensure_no_symlink(skills_root, target_config["skills_label"])
    ensure_safe_ancestors(skills_root, home)

    actions = plan_actions(manifest, paths, skills_root, managed_kind)
    conflicts = [action for action in actions if action["action"] == "conflict"]

    if args.dry_run:
        print_plan(actions, label)
        if conflicts:
            return 1
        return 0

    lock = Lock(paths["lock"], dry_run=False)
    try:
        lock.acquire()
        # Revalidate after lock.
        for key in ("root", "managed", "backups", "lock", "staging"):
            ensure_no_symlink(paths[key], key)
        ensure_no_symlink(skills_parent, target_config["skills_label"].split("/")[0])
        ensure_no_symlink(skills_root, target_config["skills_label"])
        actions = plan_actions(manifest, paths, skills_root, managed_kind)
        conflicts = [action for action in actions if action["action"] == "conflict"]
        if conflicts:
            print_result(actions, label)
            return 1
        for action in actions:
            if action["action"] in ("install", "update"):
                apply_action(action, manifest, paths, skills_root, managed_kind)
        print_result(actions, label)
        print(f"{label} skills installation complete.")
        return 0
    finally:
        lock.release()


def main() -> None:
    try:
        raise SystemExit(run())
    except InstallError as exc:
        eprint(f"terrahash-dotfiles agent-skills: {exc}")
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
