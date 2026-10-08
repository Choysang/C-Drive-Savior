"""Native NTFS Junction lifecycle management using Windows APIs."""

from __future__ import annotations

import os
import sys
from pathlib import Path
from typing import Optional

if sys.platform == "win32":
    import _winapi
else:
    _winapi = None

REPARSE_POINT_ATTR = 0x400


def is_junction(path: str | Path) -> bool:
    """Check if the given path is an NTFS reparse point (Junction/Mount Point)."""
    p = Path(path)
    if not p.exists():
        return False
    try:
        stat = p.lstat()
        is_reparse = bool(getattr(stat, "st_file_attributes", 0) & REPARSE_POINT_ATTR)
        return is_reparse or p.is_symlink()
    except OSError:
        return False


def get_junction_target(path: str | Path) -> Optional[str]:
    """Retrieve the physical destination target of a junction or symlink."""
    p = Path(path)
    if not is_junction(p):
        return None
    try:
        return str(p.resolve())
    except OSError:
        return None


def create_junction(target_dir: str | Path, link_path: str | Path) -> None:
    """
    Atomically create an NTFS Directory Junction from link_path to target_dir.
    No elevated Administrator privileges required for Junctions on NTFS.
    """
    target = Path(target_dir).resolve()
    link = Path(link_path).resolve()

    if not target.is_dir():
        raise NotADirectoryError(f"Target directory does not exist: {target}")
    if link.exists():
        raise FileExistsError(f"Link path already exists: {link}")

    if _winapi is None:
        raise OSError("NTFS Junctions are only supported on Windows.")

    _winapi.CreateJunction(str(target), str(link))


def remove_junction(link_path: str | Path) -> None:
    """
    Safely unbind an NTFS Junction without deleting the physical target data.
    Uses os.rmdir which removes the reparse point header only.
    """
    link = Path(link_path)
    if not is_junction(link):
        raise ValueError(f"Path is not a junction or reparse point: {link}")

    os.rmdir(str(link))
