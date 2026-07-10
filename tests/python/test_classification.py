import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


class ClassificationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.data = json.loads(
            (ROOT / "config" / "classification.json").read_text(encoding="utf-8")
        )

    def test_cleanup_ids_are_unique_and_complete(self) -> None:
        ids = [item["id"] for item in self.data["cleanup_items"]]
        self.assertEqual(len(ids), 27)
        self.assertEqual(len(ids), len(set(ids)))

    def test_no_cleanup_target_is_a_raw_absolute_path(self) -> None:
        for item in self.data["cleanup_items"]:
            for resolver in item["resolvers"]:
                self.assertNotRegex(resolver, r"^[A-Za-z]:\\")

    def test_protected_prefixes_include_windows_core(self) -> None:
        prefixes = {value.casefold() for value in self.data["protected_prefixes"]}
        self.assertIn("windows/system32", prefixes)
        self.assertIn("windows/winsxs", prefixes)
        self.assertIn("windows/installer", prefixes)


if __name__ == "__main__":
    unittest.main()
