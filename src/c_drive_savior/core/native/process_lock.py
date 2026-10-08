"""Process detection and lock verification on Windows."""

from __future__ import annotations

import subprocess
import sys
from typing import List, Set


def get_running_process_names() -> Set[str]:
    """Retrieve lowercase base names of all currently running processes."""
    running: Set[str] = set()
    if sys.platform != "win32":
        return running

    try:
        output = subprocess.check_output(
            ["tasklist", "/nh", "/fo", "csv"],
            text=True,
            encoding="utf-8",
            errors="ignore",
        )
        for line in output.splitlines():
            line = line.strip()
            if not line:
                continue
            parts = [p.strip(' "') for p in line.split(",")]
            if parts:
                image_name = parts[0].lower()
                running.add(image_name)
                if image_name.endswith(".exe"):
                    running.add(image_name[:-4])
    except Exception:
        pass
    return running


def check_conflicting_processes(expected_processes: List[str]) -> List[str]:
    """Check if any of the specified owning process names are actively running."""
    if not expected_processes:
        return []
    running = get_running_process_names()
    conflicts = []
    for proc in expected_processes:
        p_lower = proc.lower()
        if p_lower in running or f"{p_lower}.exe" in running:
            conflicts.append(proc)
    return conflicts
