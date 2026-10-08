"""Install C-Drive-Savior into Agent Skill Directories (Codex, Claude, Antigravity)."""

import os
import sys
from pathlib import Path

# Add src to path
sys.path.insert(0, str(Path(__file__).resolve().parent / "src"))
from c_drive_savior.core.native.junction import create_junction, is_junction

REPO_ROOT = Path(__file__).resolve().parent

CANDIDATE_SKILL_DIRS = [
    Path.home() / ".codex" / "skills",
    Path.home() / ".claude" / "skills",
    Path.home() / ".gemini" / "antigravity" / "skills",
]


def install_skills():
    print("=" * 60)
    print("  C-DRIVE-SAVIOR 2026+ | AGENT SKILL REGISTRATION")
    print("=" * 60)
    print(f"Source Repository: {REPO_ROOT}\n")

    registered = 0
    for base_dir in CANDIDATE_SKILL_DIRS:
        if not base_dir.exists():
            try:
                base_dir.mkdir(parents=True, exist_ok=True)
            except OSError:
                continue

        target_link = base_dir / "c-drive-savior"
        print(f"[*] Checking {base_dir} ...")

        if target_link.exists():
            if is_junction(target_link):
                print(f"    [+] Already linked via Junction: {target_link}")
                registered += 1
                continue
            else:
                print(f"    [!] Folder already exists: {target_link} (skipping)")
                continue

        try:
            create_junction(REPO_ROOT, target_link)
            print(f"    [OK] Successfully created NTFS Junction: {target_link}")
            registered += 1
        except Exception as exc:
            print(f"    [-] Failed to link to {target_link}: {exc}")


    print("\n" + "=" * 60)
    print(f"Skill Registration Complete! Linked to {registered} Agent environments.")
    print("Now any Agent in Codex, Claude Code, or Antigravity can immediately")
    print("discover and trigger the `c-drive-savior` skill via natural language.")
    print("=" * 60)


if __name__ == "__main__":
    install_skills()
