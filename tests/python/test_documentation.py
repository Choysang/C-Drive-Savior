import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class DocumentationTests(unittest.TestCase):
    def test_guarded_session_flow_is_documented(self) -> None:
        skill = (ROOT / "SKILL.md").read_text(encoding="utf-8")
        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        relocation = (ROOT / "references" / "relocation-guide.md").read_text(
            encoding="utf-8"
        )
        self.assertIn("scripts/decide.ps1", skill)
        self.assertIn("-SessionId", skill)
        self.assertNotIn("faster on huge trees", skill.casefold())
        self.assertIn("stage", relocation.casefold())
        self.assertIn("finalize", relocation.casefold())
        self.assertIn("PowerShell 5.1", readme)
        self.assertIn("Python", readme)

    def test_skill_forbids_ad_hoc_destructive_commands(self) -> None:
        skill = (ROOT / "SKILL.md").read_text(encoding="utf-8")
        self.assertIn("bundled scripts", skill)
        self.assertIn("never construct direct deletion commands", skill.casefold())
        self.assertIn("repeat every concrete denied path", skill.casefold())
        self.assertIn("do not demand a rescan", skill.casefold())


if __name__ == "__main__":
    unittest.main()
