"""Precision Cache & Log Cleaner with Reparse-Point Guards."""

from __future__ import annotations

import os
import shutil
from pathlib import Path
from typing import List, Optional

from c_drive_savior.core.native.junction import is_junction
from c_drive_savior.core.native.process_lock import check_conflicting_processes
from c_drive_savior.domain.models import ActionResult


class PrecisionCleaner:
    """Safely cleans rebuildable GREEN caches and temporary files."""

    @staticmethod
    def clean_target(
        target_path: str,
        owning_processes: Optional[List[str]] = None,
        is_temp_dir: bool = False,
    ) -> ActionResult:
        p = Path(target_path).resolve()
        if not p.exists():
            return ActionResult(op_id=target_path, status="skipped", message="Path does not exist.")

        # Guard protected system directories
        p_str = str(p).lower()
        for red in [r"c:\windows", r"c:\program files", r"c:\program files (x86)", r"c:\programdata\package cache"]:
            if p_str == red or p_str.startswith(red + "\\"):
                return ActionResult(op_id=target_path, status="failed", message="Refusing to clean protected system path.")

        # Check process conflicts
        conflicts = check_conflicting_processes(owning_processes or [])
        if conflicts:
            return ActionResult(
                op_id=target_path,
                status="skipped",
                message=f"Process is currently running: {', '.join(conflicts)}",
            )

        freed = 0
        try:
            if is_temp_dir:
                # Inside Temp, prune files and subdirs individually, SKIPPING any junctions!
                for entry in os.scandir(p):
                    try:
                        ep = Path(entry.path)
                        if is_junction(ep):
                            continue  # NEVER touch junctions inside Temp
                        if entry.is_file(follow_symlinks=False):
                            sz = entry.stat(follow_symlinks=False).st_size
                            os.remove(entry.path)
                            freed += sz
                        elif entry.is_dir(follow_symlinks=False):
                            sz = sum(
                                f.stat().st_size
                                for f in ep.rglob("*")
                                if f.is_file() and not is_junction(f)
                            )
                            shutil.rmtree(entry.path, ignore_errors=True)
                            freed += sz
                    except OSError:
                        pass
            else:
                # Regular cache directory
                if is_junction(p):
                    return ActionResult(
                        op_id=target_path,
                        status="skipped",
                        message="Path is a junction/symlink. Refusing to delete.",
                    )
                freed = sum(
                    f.stat().st_size for f in p.rglob("*") if f.is_file() and not is_junction(f)
                )
                shutil.rmtree(str(p), ignore_errors=True)
                p.mkdir(parents=True, exist_ok=True)

            return ActionResult(
                op_id=target_path,
                status="completed",
                freed_bytes=freed,
                message=f"Freed {round(freed / (1024**2), 2)} MB.",
            )

        except Exception as exc:
            return ActionResult(
                op_id=target_path,
                status="failed",
                error=str(exc),
            )
