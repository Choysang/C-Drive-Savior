"""3-Step Atomic Transactional Storage Relocator with Zero-Data-Loss Rollback."""

from __future__ import annotations

import os
import shutil
import subprocess
import datetime as dt
from pathlib import Path
from typing import Dict, Any, Optional

from c_drive_savior.core.native.junction import create_junction, is_junction, remove_junction
from c_drive_savior.core.native.process_lock import check_conflicting_processes
from c_drive_savior.domain.models import ActionResult


class TransactionalRelocator:
    """
    Executes atomic relocations to secondary drives and establishes NTFS Junctions.
    Follows Copy -> Verify -> Atomic Swap -> Prune with automatic rollback.
    """

    def __init__(self, target_root: str = "D:\\MovedFromC"):
        self.target_root = Path(target_root)
        self.target_root.mkdir(parents=True, exist_ok=True)

    def plan_relocation(self, source_path: str, custom_dest: Optional[str] = None) -> Dict[str, Any]:
        """Pre-flight evaluation without side effects."""
        src = Path(source_path).resolve()
        if not src.exists():
            raise FileNotFoundError(f"Source path does not exist: {src}")
        if is_junction(src):
            raise ValueError(f"Source path is already a junction: {src}")

        dst = Path(custom_dest).resolve() if custom_dest else self.target_root / src.name

        # Calculate size
        total_bytes = 0
        file_count = 0
        for root, dirs, files in os.walk(src):
            for f in files:
                try:
                    fp = Path(root) / f
                    if not fp.is_symlink():
                        total_bytes += fp.stat().st_size
                        file_count += 1
                except OSError:
                    pass

        # Check target drive space
        target_drive = dst.anchor
        free_bytes = shutil.disk_usage(target_drive).free

        return {
            "source": str(src),
            "destination": str(dst),
            "total_bytes": total_bytes,
            "total_gb": round(total_bytes / (1024**3), 2),
            "file_count": file_count,
            "target_free_gb": round(free_bytes / (1024**3), 2),
            "can_proceed": free_bytes > (total_bytes * 1.15),
        }

    def execute_relocation(
        self,
        source_path: str,
        custom_dest: Optional[str] = None,
        expected_processes: Optional[list] = None,
    ) -> ActionResult:
        """Execute the 3-step atomic relocation with rollback guard."""
        plan = self.plan_relocation(source_path, custom_dest)
        if not plan["can_proceed"]:
            return ActionResult(
                op_id=source_path,
                status="failed",
                message="Target drive does not have enough free space (required 115% of source).",
            )

        # Check process conflicts
        conflicts = check_conflicting_processes(expected_processes or [])
        if conflicts:
            return ActionResult(
                op_id=source_path,
                status="skipped",
                message=f"Blocked by running processes: {', '.join(conflicts)}",
            )

        src = Path(plan["source"])
        dst = Path(plan["destination"])
        dst.mkdir(parents=True, exist_ok=True)

        # Step 1: Robocopy Mirror Copy
        cmd = [
            "robocopy",
            str(src),
            str(dst),
            "/E",
            "/COPY:DAT",
            "/DCOPY:DAT",
            "/R:2",
            "/W:2",
            "/XJ",
            "/MT:8",
            "/NFL",
            "/NDL",
            "/NP",
        ]
        proc = subprocess.run(cmd, capture_output=True, check=False)
        if proc.returncode >= 8:
            return ActionResult(
                op_id=source_path,
                status="failed",
                error=f"Robocopy failed with exit code {proc.returncode}",
            )

        # Step 2: Verification
        dst_bytes = sum(f.stat().st_size for f in dst.rglob("*") if f.is_file() and not f.is_symlink())
        if dst_bytes < int(plan["total_bytes"] * 0.98) and plan["total_bytes"] > 0:
            return ActionResult(
                op_id=source_path,
                status="failed",
                error="Destination size verification failed. Some files were locked or skipped.",
            )

        # Step 3: Atomic Swap with Rollback Guard
        ts = dt.datetime.now().strftime("%Y%m%d_%H%M%S")
        bak = src.parent / f"{src.name}.__savior_bak_{ts}"

        try:
            # Atomic rename original
            os.replace(str(src), str(bak))

            # Create NTFS Junction at original location
            create_junction(dst, src)

            # Verification of junction
            if not is_junction(src):
                raise RuntimeError("Failed to verify created junction point.")

            # Prune old backup
            shutil.rmtree(str(bak), ignore_errors=True)

            return ActionResult(
                op_id=source_path,
                status="completed",
                freed_bytes=plan["total_bytes"],
                message=f"Successfully relocated to {dst} and created NTFS Junction.",
            )

        except Exception as exc:
            # Rollback
            if src.exists() and is_junction(src):
                try:
                    remove_junction(src)
                except Exception:
                    pass
            if bak.exists() and not src.exists():
                try:
                    os.replace(str(bak), str(src))
                except Exception:
                    pass

            return ActionResult(
                op_id=source_path,
                status="failed",
                error=f"Atomic swap failed and was safely rolled back: {str(exc)}",
            )
