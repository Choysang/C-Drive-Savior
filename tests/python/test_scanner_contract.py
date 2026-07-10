import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from jsonschema import Draft202012Validator

from scripts import c_drive_panel as scanner


ROOT = Path(__file__).resolve().parents[2]


class ScannerContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = Path(tempfile.mkdtemp(prefix="cds-contract-"))
        helper = ROOT / "tests" / "helpers" / "New-TestFixture.ps1"
        command = (
            f". '{helper}'; "
            f"New-TestFixture -Root '{self.temp / 'fixture'}' | ConvertTo-Json -Compress"
        )
        result = subprocess.run(
            ["pwsh", "-NoProfile", "-Command", command],
            check=True,
            capture_output=True,
            text=True,
        )
        self.fixture = json.loads(result.stdout)

    def tearDown(self) -> None:
        link = Path(self.fixture["LinkPath"])
        if link.exists():
            os_rmdir = subprocess.run(
                ["pwsh", "-NoProfile", "-Command", f"Remove-Item -LiteralPath '{link}' -Force"],
                check=False,
            )
            self.assertEqual(os_rmdir.returncode, 0)
        shutil.rmtree(self.temp, ignore_errors=True)

    def test_python_and_powershell_have_equivalent_scan_semantics(self) -> None:
        scan_script = ROOT / "scripts" / "scan.ps1"
        sessions = self.temp / "sessions"
        target = str(Path(self.fixture["Root"]) / "cache-a")
        environment = {**os.environ, "LOCALAPPDATA": self.fixture["Root"], "TEMP": target}
        subprocess.run(
            [
                "pwsh",
                "-NoProfile",
                "-File",
                str(scan_script),
                "-ScanRoot",
                self.fixture["Root"],
                "-ThresholdGB",
                "0",
                "-MaxReportDepth",
                "8",
                "-SessionRoot",
                str(sessions),
                "-NoHtml",
            ],
            check=True,
            capture_output=True,
            text=True,
            env=environment,
        )
        powershell_scan = json.loads(next(sessions.glob("*/scan.json")).read_text(encoding="utf-8-sig"))
        with patch.dict(os.environ, {"LOCALAPPDATA": self.fixture["Root"], "TEMP": target}):
            python_scan = scanner.scan_root(Path(self.fixture["Root"]), threshold=0, max_report_depth=8)

        schema = json.loads((ROOT / "schemas" / "scan-v2.schema.json").read_text(encoding="utf-8"))
        Draft202012Validator(schema).validate(powershell_scan)
        Draft202012Validator(schema).validate(python_scan)

        powershell_rows = {row["path"].casefold(): row for row in powershell_scan["rows"]}
        python_rows = {row["path"].casefold(): row for row in python_scan["rows"]}
        self.assertEqual(set(powershell_rows), set(python_rows))
        for path, expected in powershell_rows.items():
            actual = python_rows[path]
            for field in ("id", "parent_id", "action_id", "depth", "logical_bytes", "unique_bytes", "exclusive_bytes", "tier"):
                self.assertEqual(expected[field], actual[field], f"{path}: {field}")

        expected_reparse = {item["path"].casefold() for item in powershell_scan["skipped_reparse_points"]}
        actual_reparse = {item["path"].casefold() for item in python_scan["skipped_reparse_points"]}
        self.assertEqual(expected_reparse, actual_reparse)
        self.assertEqual(bool(powershell_scan["denied_paths"]), bool(python_scan["denied_paths"]))


if __name__ == "__main__":
    unittest.main()
