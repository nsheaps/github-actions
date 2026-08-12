#!/usr/bin/env python3
"""Merge live repo state (JSON on stdin) INTO an existing settings YAML file.

Used by apply-repo-settings *export* mode. The file is the merge TARGET and the
live state is the SOURCE; semantics are deliberately additive and lossless:

  - mappings:                   recurse
  - scalars:                    TARGET wins (the file's value is kept; export
                                never overwrites a value already in the file)
  - identity-keyed lists:       match items by identity key, recurse into matches
                                (so missing sub-keys / list entries — e.g. a new
                                bypass actor or collaborator — are added), append
                                source-only items to the END, and KEEP every
                                target-only item (things in the file not yet on
                                the repo are never removed)
  - other lists:                concat + dedupe

Comments and formatting are preserved via ruamel.yaml round-trip. The file is
rewritten ONLY when the merge actually changes content (and only with --write),
so an up-to-date file is left byte-for-byte untouched.

Prints `changed=true` or `changed=false`.
"""
from __future__ import annotations

import argparse
import io
import json
import sys

from ruamel.yaml import YAML
from ruamel.yaml.comments import CommentedMap

# (path-tuple-pattern, identity-key) — "*" matches any single segment.
IDENTITY_KEYS: list[tuple[tuple[str, ...], object]] = [
    (("rulesets",), "name"),
    (("rulesets", "*", "rules"), "type"),
    (("rulesets", "*", "bypass_actors"), ("actor_id", "actor_type")),
    (("labels",), "name"),
    (("collaborators",), "username"),
    (("teams",), "name"),
]


def _path_match(pattern: tuple[str, ...], path: tuple[str, ...]) -> bool:
    return len(pattern) == len(path) and all(
        p == "*" or p == q for p, q in zip(pattern, path)
    )


def _lookup_identity(path: tuple[str, ...]):
    for pattern, key in IDENTITY_KEYS:
        if _path_match(pattern, path):
            return key
    return None


def _ident(item, key) -> tuple:
    if isinstance(key, str):
        return (item.get(key),)
    return tuple(item.get(k) for k in key)


def deep_merge(source, target, path: tuple[str, ...] = ()):
    """Merge source into target (target wins on scalars). Mutates target."""
    if source is None:
        return target
    if target is None:
        return source

    if isinstance(source, dict) and isinstance(target, dict):
        for k, sv in source.items():
            if k in target:
                target[k] = deep_merge(sv, target[k], path + (k,))
            else:
                target[k] = sv
        return target

    if isinstance(source, list) and isinstance(target, list):
        key = _lookup_identity(path)
        if key is None:
            for item in source:
                if item not in target:
                    target.append(item)
            return target
        index_by_id = {
            _ident(item, key): i
            for i, item in enumerate(target)
            if isinstance(item, dict)
        }
        for s_item in source:
            if not isinstance(s_item, dict):
                if s_item not in target:
                    target.append(s_item)
                continue
            sid = _ident(s_item, key)
            if sid in index_by_id:
                idx = index_by_id[sid]
                target[idx] = deep_merge(s_item, target[idx], path + ("*",))
            else:
                target.append(s_item)
        return target

    # scalar / mismatched types: target wins (never overwrite the file's value).
    return target


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", required=True, help="settings YAML file (merge target)")
    ap.add_argument("--write", action="store_true", help="write the merged result back")
    args = ap.parse_args()

    source = json.load(sys.stdin)

    yaml = YAML()
    yaml.preserve_quotes = True
    yaml.width = 4096  # don't wrap long descriptions
    # Match the org_settings_merge.py canonical style so re-serializing a file
    # produced by that merger doesn't reindent (which would be spurious drift).
    yaml.indent(mapping=2, sequence=4, offset=2)

    try:
        with open(args.file, encoding="utf-8") as fh:
            target = yaml.load(fh)
    except FileNotFoundError:
        target = None
    if target is None:
        target = CommentedMap()

    def dump(obj) -> str:
        buf = io.StringIO()
        yaml.dump(obj, buf)
        return buf.getvalue()

    before = dump(target)  # round-tripped original (formatting-neutral baseline)
    merged = deep_merge(source, target)
    after = dump(merged)

    changed = before != after
    if changed and args.write:
        with open(args.file, "w", encoding="utf-8") as fh:
            fh.write(after)

    print("changed=true" if changed else "changed=false")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
