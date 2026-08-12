#!/usr/bin/env python3
"""Unit tests for merge_live.py (apply-repo-settings export deep-merge).

Run: python3 merge_live_test.py   (requires ruamel.yaml)
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from merge_live import deep_merge  # noqa: E402

MERGE = os.path.join(HERE, "merge_live.py")


def merge_file(yaml_text, source_obj, write=True):
    """Run merge_live.py against yaml_text with source_obj; return (changed, new_text)."""
    with tempfile.NamedTemporaryFile("w", suffix=".yml", delete=False) as fh:
        fh.write(yaml_text)
        path = fh.name
    try:
        args = [sys.executable, MERGE, "--file", path]
        if write:
            args.append("--write")
        out = subprocess.run(
            args, input=json.dumps(source_obj), capture_output=True, text=True, check=True
        ).stdout
        changed = "changed=true" in out
        with open(path, encoding="utf-8") as fh:
            return changed, fh.read()
    finally:
        os.unlink(path)


class DeepMergeLogic(unittest.TestCase):
    def test_scalar_target_wins(self):
        # file (target) value is kept; live (source) never overwrites it.
        out = deep_merge({"has_issues": False}, {"has_issues": True})
        self.assertEqual(out["has_issues"], True)

    def test_adds_missing_key(self):
        out = deep_merge({"a": 1, "b": 2}, {"a": 9})
        self.assertEqual(out, {"a": 9, "b": 2})

    def test_nested_mapping_recurse(self):
        out = deep_merge(
            {"repository": {"has_issues": False, "default_branch": "main"}},
            {"repository": {"has_issues": True}},
        )
        self.assertEqual(out["repository"], {"has_issues": True, "default_branch": "main"})

    def test_rulesets_identity_merge_append_and_keep(self):
        source = {
            "rulesets": [
                {
                    "name": "protect",
                    "bypass_actors": [
                        {"actor_id": 5, "actor_type": "RepositoryRole"},
                        {"actor_id": 99, "actor_type": "Integration"},
                    ],
                    "rules": [{"type": "deletion"}, {"type": "non_fast_forward"}],
                },
                {"name": "new-from-ui", "target": "branch"},
            ]
        }
        target = {
            "rulesets": [
                {"name": "pending-only", "target": "branch"},  # file-only, must stay
                {
                    "name": "protect",
                    "bypass_actors": [{"actor_id": 5, "actor_type": "RepositoryRole"}],
                    "rules": [{"type": "deletion"}],
                },
            ]
        }
        out = deep_merge(source, target)
        names = [r["name"] for r in out["rulesets"]]
        # pending-only kept, protect kept in place, new-from-ui appended at end.
        self.assertEqual(names, ["pending-only", "protect", "new-from-ui"])
        protect = out["rulesets"][1]
        actor_ids = sorted(a["actor_id"] for a in protect["bypass_actors"])
        self.assertEqual(actor_ids, [5, 99])  # missing actor added
        rule_types = sorted(r["type"] for r in protect["rules"])
        self.assertEqual(rule_types, ["deletion", "non_fast_forward"])  # missing rule added

    def test_labels_collaborators_teams_identity(self):
        out = deep_merge(
            {
                "labels": [{"name": "bug", "color": "ff0000"}, {"name": "new", "color": "00ff00"}],
                "collaborators": [{"username": "alice", "permission": "admin"}],
                "teams": [{"name": "core", "permission": "push"}],
            },
            {
                "labels": [{"name": "bug", "color": "d73a4a"}],  # color kept (target wins)
                "collaborators": [{"username": "alice", "permission": "pull"}],
                "teams": [{"name": "core", "permission": "pull"}],
            },
        )
        labels = {label["name"]: label["color"] for label in out["labels"]}
        self.assertEqual(labels["bug"], "d73a4a")  # target wins
        self.assertEqual(labels["new"], "00ff00")  # appended
        self.assertEqual(out["collaborators"][0]["permission"], "pull")  # target wins
        self.assertEqual(out["teams"][0]["permission"], "pull")  # target wins

    def test_target_only_never_removed(self):
        out = deep_merge({"labels": []}, {"labels": [{"name": "keep", "color": "x"}]})
        self.assertEqual([label["name"] for label in out["labels"]], ["keep"])


class CliBehavior(unittest.TestCase):
    def test_changed_true_when_adding(self):
        changed, text = merge_file(
            "repository:\n  has_issues: true\n",
            {"repository": {"has_issues": False, "default_branch": "main"}},
        )
        self.assertTrue(changed)
        self.assertIn("default_branch: main", text)
        self.assertIn("has_issues: true", text)  # not overwritten to false

    def test_changed_false_and_idempotent(self):
        yaml_text = (
            "repository:\n  has_issues: true\n"
            "labels:\n  - name: bug\n    color: \"d73a4a\"\n"
        )
        changed, text = merge_file(
            yaml_text,
            {"repository": {"has_issues": True}, "labels": [{"name": "bug", "color": "d73a4a"}]},
        )
        self.assertFalse(changed)
        self.assertEqual(text, yaml_text)  # byte-for-byte untouched when nothing to add

    def test_dry_run_does_not_write(self):
        yaml_text = "repository:\n  has_issues: true\n"
        changed, text = merge_file(
            yaml_text, {"repository": {"default_branch": "main"}}, write=False
        )
        self.assertTrue(changed)  # would change
        self.assertEqual(text, yaml_text)  # but file untouched (no --write)

    def test_comments_preserved(self):
        yaml_text = (
            "# top-of-file comment\n"
            "rulesets:\n"
            "  # keep this ruleset comment\n"
            "  - name: protect  # inline\n"
            "    enforcement: active\n"
        )
        changed, text = merge_file(
            yaml_text,
            {"rulesets": [{"name": "protect", "enforcement": "active", "target": "branch"}]},
        )
        self.assertTrue(changed)  # added target: branch
        self.assertIn("# top-of-file comment", text)
        self.assertIn("# keep this ruleset comment", text)
        self.assertIn("# inline", text)
        self.assertIn("target: branch", text)


if __name__ == "__main__":
    unittest.main()
