"""High-performance Concurrent Disk Scanner & Profiler."""

from __future__ import annotations

import os
import shutil
import uuid
import datetime as dt
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
from typing import List, Dict, Optional, Tuple

from c_drive_savior.domain.models import DriveInfo, StorageNode, ScanOverview, Tier
from c_drive_savior.core.rules.catalog import CATALOG_ITEMS, classify_path
from c_drive_savior.core.native.junction import is_junction


def get_drive_infos() -> List[DriveInfo]:
    """Retrieve all local NTFS/fixed filesystem drives and free capacities."""
    drives: List[DriveInfo] = []
    # On Windows, check available drive letters
    for letter in "CDEFGHIJKLMNOPQRSTUVWXYZ":
        root = f"{letter}:\\"
        if os.path.exists(root):
            try:
                usage = shutil.disk_usage(root)
                drives.append(
                    DriveInfo(
                        letter=f"{letter}:",
                        filesystem="NTFS",
                        total_bytes=usage.total,
                        used_bytes=usage.used,
                        free_bytes=usage.free,
                    )
                )
            except OSError:
                pass
    return drives


REPARSE_POINT_ATTR = 0x400


def measure_directory_shallow(path: Path | str, max_depth: int = 3) -> int:
    """Fast native size measurement using cached Win32 DirEntry stat attributes."""
    total = 0
    stack: List[Tuple[str, int]] = [(str(path), 0)]
    while stack:
        curr, depth = stack.pop()
        try:
            with os.scandir(curr) as it:
                for entry in it:
                    try:
                        st = entry.stat(follow_symlinks=False)
                        # Skip NTFS reparse points / junctions
                        if getattr(st, "st_file_attributes", 0) & REPARSE_POINT_ATTR:
                            continue
                        if entry.is_file(follow_symlinks=False):
                            total += st.st_size
                        elif entry.is_dir(follow_symlinks=False) and depth < max_depth:
                            stack.append((entry.path, depth + 1))
                    except (PermissionError, OSError):
                        pass
        except (PermissionError, OSError):
            pass
    return total




class FastScanner:
    """Engine for multi-threaded disk diagnostic scans."""

    def __init__(self, threshold_mb: float = 100.0, max_workers: int = 8):
        self.threshold_bytes = int(threshold_mb * 1024 * 1024)
        self.max_workers = max_workers

    def run_full_diagnosis(self, scan_root: str = "C:\\") -> ScanOverview:
        session_id = f"savior_{uuid.uuid4().hex[:12]}"
        now = dt.datetime.now(dt.timezone.utc).isoformat()
        drives = get_drive_infos()

        root_path = Path(scan_root)
        top_candidates: List[StorageNode] = []
        cleanup_candidates: List[StorageNode] = []
        move_candidates: List[StorageNode] = []
        protected_nodes: List[StorageNode] = []

        # 1. Scan catalog items first (high priority known patterns)
        for cat in CATALOG_ITEMS:
            for p in cat.resolve_paths():
                if not p.exists():
                    continue

                reparse = is_junction(p)
                if reparse:
                    continue  # Already junctioned, occupies 0 physical bytes on C:

                depth = 1 if cat.tier == Tier.RED else 4
                size = measure_directory_shallow(p, max_depth=depth)
                if size < 500 * 1024:  # Ignore tiny <500KB
                    continue

                node = StorageNode(
                    id=f"{cat.id}_{uuid.uuid4().hex[:6]}",
                    path=str(p),
                    size_bytes=size,
                    tier=cat.tier,
                    label=cat.label,
                    category=cat.category,
                    action_id=cat.id,
                    owning_processes=cat.owning_processes,
                    reparse_point=False,
                    note=cat.note,
                )

                if cat.tier == Tier.GREEN:
                    cleanup_candidates.append(node)
                elif cat.tier == Tier.MOVE:
                    move_candidates.append(node)
                elif cat.tier == Tier.RED:
                    protected_nodes.append(node)


        # 2. Parallel scan root subdirectories for Top Consumers
        root_subdirs: List[Path] = []
        try:
            with os.scandir(root_path) as it:
                for entry in it:
                    if entry.is_dir(follow_symlinks=False) and not is_junction(entry.path):
                        root_subdirs.append(Path(entry.path))
        except (PermissionError, OSError):
            pass

        def _measure(d: Path) -> Tuple[Path, int]:
            name = d.name.lower()
            depth = 1 if name in ("windows", "program files", "program files (x86)", "$recycle.bin") else 2
            return d, measure_directory_shallow(d, max_depth=depth)

        with ThreadPoolExecutor(max_workers=self.max_workers) as executor:
            results = list(executor.map(_measure, root_subdirs))



        for d, sz in results:
            if sz > self.threshold_bytes:
                tier, note, _ = classify_path(d)
                top_candidates.append(
                    StorageNode(
                        id=f"dir_{uuid.uuid4().hex[:6]}",
                        path=str(d),
                        size_bytes=sz,
                        tier=tier,
                        label=d.name,
                        category="filesystem",
                        note=note,
                    )
                )

        top_candidates.sort(key=lambda x: x.size_bytes, reverse=True)
        cleanup_candidates.sort(key=lambda x: x.size_bytes, reverse=True)
        move_candidates.sort(key=lambda x: x.size_bytes, reverse=True)

        total_reclaimable = sum(n.size_bytes for n in cleanup_candidates) + sum(
            n.size_bytes for n in move_candidates
        )

        return ScanOverview(
            session_id=session_id,
            timestamp=now,
            drives=drives,
            top_consumers=top_candidates,
            cleanup_candidates=cleanup_candidates,
            migration_candidates=move_candidates,
            protected_system_nodes=protected_nodes,
            total_reclaimable_bytes=total_reclaimable,
            scanned_complete=True,
        )
