import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from scripts import c_drive_panel as scanner


class ScannerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.mkdtemp(prefix="cds-python-scan-")
        self.root = Path(self.temp) / "fixture"
        cache = self.root / "cache-a"
        documents = self.root / "documents"
        cache.mkdir(parents=True)
        documents.mkdir()
        (cache / "a.bin").write_bytes(bytes(2048))
        (documents / "report.txt").write_bytes(bytes(512))
        self.link = self.root / "link-to-documents"
        try:
            os.symlink(documents, self.link, target_is_directory=True)
        except OSError:
            subprocess.run(
                [
                    "pwsh",
                    "-NoProfile",
                    "-Command",
                    f"New-Item -ItemType Junction -Path '{self.link}' -Target '{documents}' | Out-Null",
                ],
                check=True,
            )

    def tearDown(self) -> None:
        if self.link.exists() or self.link.is_symlink():
            os.rmdir(self.link)
        shutil.rmtree(self.temp, ignore_errors=True)

    def test_stream_scan_skips_symlink_and_counts_each_path_once(self) -> None:
        report = scanner.scan_root(self.root, threshold=1, max_report_depth=8)
        paths = [row["path"].casefold() for row in report["rows"]]
        self.assertEqual(len(paths), len(set(paths)))
        self.assertTrue(report["skipped_reparse_points"])

    def test_contract_has_raw_bytes_and_engine_identity(self) -> None:
        report = scanner.scan_root(self.root, threshold=1, max_report_depth=8)
        self.assertEqual(report["schema_version"], 2)
        self.assertEqual(report["source_engine"], "python")
        self.assertIsInstance(report["drives"][0]["free_bytes"], int)

    def test_render_uses_the_shared_static_assets(self) -> None:
        report = scanner.scan_root(self.root, threshold=1, max_report_depth=8)
        rendered = scanner.render_html(report)
        shared_script = (scanner.ROOT / "assets" / "report_script.js").read_text(encoding="utf-8")
        self.assertIn(shared_script, rendered)
        self.assertNotIn("__REPORT_DATA__", rendered)
        self.assertNotIn("__REPORT_SCRIPT__", rendered)

    def test_catalog_cleanup_id_is_linked_to_the_scanned_path(self) -> None:
        target = self.root / "cache-a"
        with patch.dict(os.environ, {"LOCALAPPDATA": str(self.root), "TEMP": str(target)}):
            report = scanner.scan_root(self.root, threshold=100 * scanner.GB, max_report_depth=0)
        target_key = scanner.path_key(target)
        row = next(
            item
            for item in report["rows"]
            if scanner.path_key(item["path"]) == target_key
        )
        self.assertEqual(row["action_id"], "temp-user")


if __name__ == "__main__":
    unittest.main()
