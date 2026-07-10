#!/usr/bin/env python3
"""Read-only Python fallback scanner for C Drive Savior."""

from __future__ import annotations

import argparse
import ctypes
import datetime as dt
import hashlib
import html
import json
import os
import shutil
import subprocess
import sys
import uuid
from pathlib import Path
from typing import Any

GB = 1024**3
REPARSE_POINT = 0x400
FILE_ATTRIBUTE_OFFLINE = 0x1000
FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS = 0x400000
ROOT = Path(__file__).resolve().parents[1]
CLASSIFICATION = json.loads(
    (ROOT / "config" / "classification.json").read_text(encoding="utf-8")
)

GREEN_NAMES = {value.casefold() for value in CLASSIFICATION["green_names"]}
YELLOW_NAMES = {value.casefold() for value in CLASSIFICATION["yellow_names"]}
MOVE_NAMES = {value.casefold() for value in CLASSIFICATION["move_names"]}
SPECIAL_CASES = tuple(
    ({value.casefold() for value in case["names"]}, case["tier"], case["note"])
    for case in CLASSIFICATION["special_cases"]
)
SYSTEM_DRIVE = os.environ.get("SystemDrive", "C:")
RED_PREFIXES = tuple(
    str(Path(SYSTEM_DRIVE + "\\") / Path(value.replace("/", "\\"))).casefold()
    for value in CLASSIFICATION["protected_prefixes"]
)

if os.name == "nt":
    _KERNEL32 = ctypes.WinDLL("kernel32", use_last_error=True)
    _GET_COMPRESSED_FILE_SIZE = _KERNEL32.GetCompressedFileSizeW
    _GET_COMPRESSED_FILE_SIZE.argtypes = [ctypes.c_wchar_p, ctypes.POINTER(ctypes.c_ulong)]
    _GET_COMPRESSED_FILE_SIZE.restype = ctypes.c_ulong
else:
    _GET_COMPRESSED_FILE_SIZE = None


def long_path(path: Path) -> str:
    value = str(path)
    if value.startswith("\\\\?\\"):
        return value
    if os.name == "nt" and path.is_absolute() and len(value) >= 248:
        return "\\\\?\\" + value
    return value


def display_path(path: str | Path) -> str:
    return str(path).replace("\\\\?\\", "")


def stable_id(path: Path) -> str:
    return hashlib.sha256(str(path).casefold().encode("utf-8")).hexdigest()[:20]


def classify(path: Path) -> tuple[str, str]:
    lowered = str(path).casefold()
    name = path.name.casefold()
    for prefix in RED_PREFIXES:
        if lowered == prefix or lowered.startswith(prefix + "\\"):
            return "RED", "System/install area. Use official tools or an uninstaller; never hand-delete."
    for names, tier, note in SPECIAL_CASES:
        if name in names:
            return tier, note
    if name in MOVE_NAMES:
        return "MOVE", "User data candidate for confirmed migration."
    if name in GREEN_NAMES:
        return "GREEN", "Rebuildable cache or temporary data."
    if name in YELLOW_NAMES or name.startswith("$winreagent"):
        return "YELLOW", "Requires a user decision; may contain user, repair, rollback, or uninstall data."
    if "cache" in name or "temp" in name:
        return "GREEN", "Cache-like name; verify ownership before cleanup."
    return "YELLOW", "Large item requiring a human decision."


def stat_is_reparse(stat_result: os.stat_result) -> bool:
    return bool(getattr(stat_result, "st_file_attributes", 0) & REPARSE_POINT)


def windows_file_identity(path: str, stat_result: os.stat_result) -> tuple[str, int, str]:
    """Return identity key, allocated bytes, and allocation accuracy."""
    identity = f"{stat_result.st_dev}:{stat_result.st_ino}"
    attributes = getattr(stat_result, "st_file_attributes", 0)
    if attributes & (FILE_ATTRIBUTE_OFFLINE | FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS):
        return identity, stat_result.st_size, "logical"

    if os.name != "nt":
        blocks = getattr(stat_result, "st_blocks", None)
        return identity, blocks * 512 if blocks is not None else stat_result.st_size, (
            "allocated" if blocks is not None else "logical"
        )

    high = ctypes.c_ulong(0)
    ctypes.set_last_error(0)
    low = _GET_COMPRESSED_FILE_SIZE(path, ctypes.byref(high))
    error = ctypes.get_last_error()
    if low == 0xFFFFFFFF and error:
        return identity, stat_result.st_size, "logical"
    return identity, (high.value << 32) | low, "allocated"


def volume_filesystem(root: Path) -> str | None:
    if os.name != "nt":
        return None
    filesystem = ctypes.create_unicode_buffer(64)
    ok = ctypes.windll.kernel32.GetVolumeInformationW(
        ctypes.c_wchar_p(root.anchor), None, 0, None, None, None, filesystem, len(filesystem)
    )
    return filesystem.value if ok else None


def is_elevated() -> bool:
    return bool(os.name == "nt" and ctypes.windll.shell32.IsUserAnAdmin())


def collect_hidden_consumers(system_root: Path, elevated: bool) -> list[dict]:
    """Return root-level hidden consumers without double-counting them."""
    del elevated
    candidates = (
        ("pagefile", "pagefile.sys (virtual memory)", system_root / "pagefile.sys"),
        ("hiberfil", "hiberfil.sys (hibernation)", system_root / "hiberfil.sys"),
        ("swapfile", "swapfile.sys", system_root / "swapfile.sys"),
        ("memdump", "MEMORY.DMP (crash dump)", Path(os.environ.get("SystemRoot", "C:\\Windows")) / "MEMORY.DMP"),
    )
    hidden: list[dict] = []
    for item_id, label, path in candidates:
        if not path.is_file():
            continue
        try:
            size = path.stat().st_size
            hidden.append(
                {
                    "id": item_id,
                    "label": label,
                    "bytes": int(size),
                    "size_accuracy": "logical",
                    "requires_admin": False,
                    "overlaps_visible_scan": True,
                    "note": "Already included in the visible root total; shown separately for diagnosis.",
                    "error": None,
                }
            )
        except OSError as exc:
            hidden.append(
                {
                    "id": item_id,
                    "label": label,
                    "bytes": None,
                    "size_accuracy": "logical",
                    "requires_admin": True,
                    "overlaps_visible_scan": True,
                    "note": "Could not measure this protected file.",
                    "error": str(exc),
                }
            )
    return hidden


def scan_root(root: Path, threshold: int, max_report_depth: int) -> dict:
    """Walk one root once without following reparse points."""
    started = dt.datetime.now(dt.timezone.utc)
    root = root.resolve(strict=True)
    if not root.is_dir():
        raise NotADirectoryError(root)

    states: dict[str, dict[str, Any]] = {}
    rows: list[dict] = []
    denied: list[dict] = []
    reparse_points: list[dict] = []
    identities: set[str] = set()
    root_key = str(root)
    states[root_key] = {
        "path": root,
        "id": stable_id(root),
        "parent": None,
        "parent_id": None,
        "depth": 0,
        "logical": 0,
        "unique": 0,
        "direct_unique": 0,
    }
    stack: list[tuple[str, bool]] = [(root_key, False)]
    scan_complete = True
    allocation_accurate = True

    while stack:
        current_key, visited = stack.pop()
        state = states[current_key]
        current = state["path"]
        if visited:
            if state["parent"] is not None:
                parent = states[state["parent"]]
                parent["logical"] += state["logical"]
                parent["unique"] += state["unique"]
            if state["depth"] <= max_report_depth and (
                current_key == root_key or state["unique"] >= threshold
            ):
                tier, note = classify(current)
                rows.append(
                    {
                        "id": state["id"],
                        "parent_id": state["parent_id"],
                        "path": display_path(current),
                        "depth": int(state["depth"]),
                        "logical_bytes": int(state["logical"]),
                        "unique_bytes": int(state["unique"]),
                        "exclusive_bytes": int(state["direct_unique"]),
                        "size_accuracy": "file-id-deduplicated" if allocation_accurate else "logical",
                        "tier": tier,
                        "note": note,
                    }
                )
            continue

        stack.append((current_key, True))
        try:
            with os.scandir(long_path(current)) as entries:
                for entry in entries:
                    path = Path(display_path(entry.path))
                    try:
                        stat_result = entry.stat(follow_symlinks=False)
                        if os.name == "nt" and stat_result.st_ino == 0:
                            stat_result = os.stat(path, follow_symlinks=False)
                        if entry.is_symlink() or stat_is_reparse(stat_result):
                            reparse_points.append(
                                {"path": str(path), "kind": "reparse-point", "target": None}
                            )
                            continue
                        if entry.is_dir(follow_symlinks=False):
                            child_key = str(path)
                            child_id = stable_id(path)
                            states[child_key] = {
                                "path": path,
                                "id": child_id,
                                "parent": current_key,
                                "parent_id": state["id"],
                                "depth": state["depth"] + 1,
                                "logical": 0,
                                "unique": 0,
                                "direct_unique": 0,
                            }
                            stack.append((child_key, False))
                            continue

                        identity, _, accuracy = windows_file_identity(entry.path, stat_result)
                        size = int(stat_result.st_size)
                        state["logical"] += size
                        if identity not in identities:
                            identities.add(identity)
                            state["unique"] += size
                            state["direct_unique"] += size
                        if accuracy == "logical":
                            allocation_accurate = False
                    except OSError as exc:
                        scan_complete = False
                        denied.append(
                            {
                                "path": str(path),
                                "error_code": type(exc).__name__,
                                "error_message": str(exc),
                            }
                        )
        except OSError as exc:
            scan_complete = False
            denied.append(
                {
                    "path": str(current),
                    "error_code": type(exc).__name__,
                    "error_message": str(exc),
                }
            )

    usage = shutil.disk_usage(root)
    drive_root = Path(root.anchor)
    is_drive_root = os.path.normcase(os.path.normpath(root)) == os.path.normcase(os.path.normpath(drive_root))
    hidden = collect_hidden_consumers(drive_root, is_elevated()) if is_drive_root else []
    duplicate_hidden = sum(item["bytes"] or 0 for item in hidden if item["overlaps_visible_scan"])
    visible_unique = int(states[root_key]["unique"])
    elapsed = (dt.datetime.now(dt.timezone.utc) - started).total_seconds()
    return {
        "schema_version": 2,
        "session_id": f"python-{uuid.uuid4().hex[:12]}",
        "generated_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "source_engine": "python",
        "engine_version": sys.version.split()[0],
        "scan_complete": scan_complete,
        "scan_seconds": round(elapsed, 3),
        "drives": [
            {
                "letter": root.drive or SYSTEM_DRIVE,
                "filesystem": volume_filesystem(drive_root),
                "total_bytes": int(usage.total),
                "used_bytes": int(usage.used),
                "free_bytes": int(usage.free),
            }
        ],
        "rows": sorted(rows, key=lambda item: item["path"].casefold()),
        "hidden": hidden,
        "denied_paths": denied,
        "skipped_reparse_points": reparse_points,
        "accounting": {
            "visible_unique_bytes": visible_unique,
            "hidden_unique_bytes": 0,
            "duplicate_hidden_bytes": int(duplicate_hidden),
            "reconciliation_is_estimate": not allocation_accurate,
        },
        "system_and_other_bytes": max(0, int(usage.used) - visible_unique),
    }


def normalize_for_contract(report: dict) -> dict:
    """Remove volatile engine fields and sort arrays for parity checks."""
    normalized = json.loads(json.dumps(report))
    for key in ("session_id", "generated_at", "scan_seconds", "source_engine", "engine_version"):
        normalized.pop(key, None)
    normalized["rows"] = sorted(normalized["rows"], key=lambda item: item["id"])
    normalized["hidden"] = sorted(normalized["hidden"], key=lambda item: item["id"])
    normalized["denied_paths"] = sorted(normalized["denied_paths"], key=lambda item: item["path"].casefold())
    normalized["skipped_reparse_points"] = sorted(
        normalized["skipped_reparse_points"], key=lambda item: item["path"].casefold()
    )
    return normalized


def render_html(report: dict) -> str:
    rows = "".join(
        "<tr>"
        f"<td>{html.escape(row['tier'])}</td>"
        f"<td>{row['unique_bytes'] / GB:.2f} GB</td>"
        f"<td><code>{html.escape(row['path'])}</code></td>"
        f"<td>{html.escape(row['note'])}</td>"
        "</tr>"
        for row in report["rows"]
    )
    drive = report["drives"][0]
    return f"""<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>C Drive Savior</title>
<style>body{{font:14px/1.5 "Segoe UI","Microsoft YaHei",sans-serif;margin:24px;color:#1f2328}}
main{{max-width:1100px;margin:auto}}table{{width:100%;border-collapse:collapse}}th,td{{padding:8px;border-bottom:1px solid #d0d7de;text-align:left}}
code{{word-break:break-all}}.summary{{display:flex;gap:24px;padding:14px 0}}</style></head><body><main>
<h1>C Drive Savior / C盘拯救者</h1><div class="summary"><span>已用 {drive['used_bytes']/GB:.2f} GB</span>
<span>可用 {drive['free_bytes']/GB:.2f} GB</span><span>候选 {len(report['rows'])}</span></div>
<table><thead><tr><th>级别</th><th>大小</th><th>路径</th><th>建议</th></tr></thead><tbody>{rows}</tbody></table>
</main></body></html>"""


def write_json_atomic(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")
    os.replace(temporary, path)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="C Drive Savior read-only fallback scanner.")
    parser.add_argument("--threshold-gb", type=float, default=1.0)
    parser.add_argument("--scan-root", default=SYSTEM_DRIVE + "\\")
    parser.add_argument("--session-root", default=str(Path.home() / "c-drive-savior" / "sessions"))
    parser.add_argument("--max-report-depth", type=int, default=4)
    parser.add_argument("--output-dir", help="Legacy alias for --session-root.")
    parser.add_argument("--user-profile", default=str(Path.home()), help=argparse.SUPPRESS)
    parser.add_argument("--open", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    report = scan_root(
        Path(args.scan_root),
        threshold=int(args.threshold_gb * GB),
        max_report_depth=args.max_report_depth,
    )
    session_root = Path(args.output_dir or args.session_root)
    session_dir = session_root / report["session_id"]
    session_dir.mkdir(parents=True, exist_ok=False)
    scan_path = session_dir / "scan.json"
    panel_path = session_dir / "panel.html"
    artifacts = {
        "scan": str(scan_path),
        "decisions": str(session_dir / "decisions.json"),
        "actions": str(session_dir / "actions.jsonl"),
        "panel": str(panel_path),
        "report": str(session_dir / "report.html"),
    }
    now = dt.datetime.now(dt.timezone.utc).isoformat()
    session = {
        "schema_version": 2,
        "session_id": report["session_id"],
        "state": "awaiting-decision",
        "created_at": now,
        "updated_at": now,
        "root": str(session_dir),
        "artifacts": artifacts,
    }
    write_json_atomic(scan_path, report)
    write_json_atomic(session_dir / "session.json", session)
    panel_path.write_text(render_html(report), encoding="utf-8")
    print(f"Session: {report['session_id']}")
    print(f"Scan: {scan_path}")
    print(f"Panel: {panel_path}")
    if args.open:
        if os.name == "nt":
            os.startfile(panel_path)  # type: ignore[attr-defined]
        else:
            subprocess.run(["xdg-open", str(panel_path)], check=False)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
