"""Modern Test Suite for C-Drive-Savior 2026+ Agent-Native Engine."""

import os
import sys
import tempfile
import unittest
from pathlib import Path

# Add src to sys.path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from c_drive_savior.core.native.junction import is_junction, get_junction_target
from c_drive_savior.core.rules.catalog import get_rule_catalog, get_rule_for_path
from c_drive_savior.domain.models import (
    Tier,
    DriveInfo,
    StorageNode,
    ScanOverview,
    ActionResult,
)
from c_drive_savior.domain.cognitive_guard import CognitiveGuard
from c_drive_savior.core.engine.cleaner import PrecisionCleaner


class CognitiveGuardTests(unittest.TestCase):
    def test_pagination_and_compression(self):
        nodes = []
        for i in range(25):
            nodes.append(
                StorageNode(
                    id=f"node-{i}",
                    path=f"C:\\mock\\path_{i}",
                    size_bytes=1024 * 1024 * (i + 1),
                    tier=Tier.GREEN,
                    label=f"Item {i}",
                )
            )

        paged = CognitiveGuard.paginate_nodes(nodes, cursor=0, page_size=10)
        self.assertEqual(len(paged["items"]), 10)
        self.assertEqual(paged["total_items"], 25)
        self.assertEqual(paged["next_cursor"], 10)
        self.assertTrue(paged["has_more"])

        paged_last = CognitiveGuard.paginate_nodes(nodes, cursor=20, page_size=10)
        self.assertEqual(len(paged_last["items"]), 5)
        self.assertIsNone(paged_last["next_cursor"])
        self.assertFalse(paged_last["has_more"])

    def test_overview_summarization(self):
        c_drive = DriveInfo(
            letter="C:",
            total_bytes=100 * (1024**3),
            free_bytes=30 * (1024**3),
            used_bytes=70 * (1024**3),
        )
        overview = ScanOverview(
            session_id="test-session-2026",
            timestamp="2026-10-08T12:00:00Z",
            drives=[c_drive],
            top_consumers=[
                StorageNode(
                    id="node-uv",
                    path="C:\\mock\\uv",
                    size_bytes=2 * (1024**3),
                    tier=Tier.GREEN,
                    label="uv Cache",
                ),
                StorageNode(
                    id="node-codex",
                    path="C:\\mock\\codex",
                    size_bytes=5 * (1024**3),
                    tier=Tier.MOVE,
                    label="Codex Workspace",
                ),
            ],
            cleanup_candidates=[
                StorageNode(
                    id="node-uv",
                    path="C:\\mock\\uv",
                    size_bytes=2 * (1024**3),
                    tier=Tier.GREEN,
                    label="uv Cache",
                )
            ],
            migration_candidates=[
                StorageNode(
                    id="node-codex",
                    path="C:\\mock\\codex",
                    size_bytes=5 * (1024**3),
                    tier=Tier.MOVE,
                    label="Codex Workspace",
                )
            ],
            protected_system_nodes=[],
            total_reclaimable_bytes=7 * (1024**3),
        )

        summary = CognitiveGuard.summarize_scan(overview)
        self.assertEqual(summary["session_id"], "test-session-2026")
        self.assertEqual(summary["recommended_cleanups_count"], 1)
        self.assertEqual(summary["recommended_moves_count"], 1)
        self.assertEqual(len(summary["top_consumers"]), 2)
        self.assertEqual(summary["c_drive"]["free_gb"], 30.0)


class RulesCatalogTests(unittest.TestCase):
    def test_catalog_rules_loaded(self):
        rules = get_rule_catalog()
        self.assertGreater(len(rules), 15)

    def test_catalog_matches_codex_and_ai(self):
        user_home = Path.home()
        codex_path = str(user_home / ".codex")
        rule = get_rule_for_path(codex_path)
        self.assertIsNotNone(rule)
        self.assertTrue(rule.can_junction)
        self.assertEqual(rule.tier, Tier.MOVE)

    def test_catalog_matches_uv_cache(self):
        appdata = os.environ.get("LOCALAPPDATA", "C:\\Users\\Mock\\AppData\\Local")
        uv_cache = str(Path(appdata) / "uv")
        rule = get_rule_for_path(uv_cache)
        self.assertIsNotNone(rule)
        self.assertFalse(rule.can_junction)
        self.assertEqual(rule.tier, Tier.GREEN)


class CleanerSafetyTests(unittest.TestCase):
    def test_cleaner_refuses_protected_system_paths(self):
        res = PrecisionCleaner.clean_target("C:\\Windows\\System32")
        self.assertEqual(res.status, "failed")
        self.assertIn("protected", res.message.lower())

    def test_cleaner_cleans_temporary_safe_directory(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            test_file = Path(temp_dir) / "dummy.tmp"
            test_file.write_text("temporary data")
            res = PrecisionCleaner.clean_target(temp_dir, is_temp_dir=True)
            self.assertEqual(res.status, "completed")
            self.assertFalse(test_file.exists())


if __name__ == "__main__":
    unittest.main()
