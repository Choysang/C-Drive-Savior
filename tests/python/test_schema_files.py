import json
import unittest
from pathlib import Path

from jsonschema import Draft202012Validator

ROOT = Path(__file__).resolve().parents[2]
SCHEMAS = ROOT / "schemas"


class SchemaFileTests(unittest.TestCase):
    def load_schema(self, name: str) -> dict:
        path = SCHEMAS / name
        self.assertTrue(path.is_file(), f"missing schema: {path}")
        schema = json.loads(path.read_text(encoding="utf-8"))
        Draft202012Validator.check_schema(schema)
        return schema

    def test_all_v2_schemas_exist_and_are_valid(self) -> None:
        for name in (
            "session-v2.schema.json",
            "scan-v2.schema.json",
            "decisions-v2.schema.json",
            "action-v2.schema.json",
        ):
            with self.subTest(name=name):
                self.load_schema(name)

    def test_action_status_is_closed_enum(self) -> None:
        schema = self.load_schema("action-v2.schema.json")
        status = schema["properties"]["status"]["enum"]
        self.assertEqual(
            status,
            ["planned", "completed", "partial", "failed", "skipped", "not-found"],
        )


if __name__ == "__main__":
    unittest.main()
