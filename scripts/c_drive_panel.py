#!/usr/bin/env python3
"""Read-only C Drive Savior scanner that creates a compact HTML cleanup panel."""

from __future__ import annotations

import argparse
import datetime as dt
import html
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

GB = 1024 ** 3
REPARSE_POINT = 0x400


GREEN_NAMES = {
    "npm-cache",
    "pnpm-cache",
    "pip",
    "pypa",
    "uv",
    "node-gyp",
    "ms-playwright",
    "d3dscache",
    "crashdumps",
    "squirreltemp",
    "temp",
    "tmp",
    "fontconfig",
    "cef",
    "chrome-devtools-mcp",
    "tauri",
    "cmaketools",
    "obsidian-updater",
    "updfsetup",
    "winsparkle",
}

YELLOW_NAMES = {
    "package cache",
    "recovery",
    "customizations",
    "$windows.~bt",
    "$winreagent",
    "downloads",
    "desktop",
    "documents",
    "pictures",
    "videos",
    "music",
    "scoop",
    ".git",
}

RED_PREFIXES = (
    r"c:\windows\system32",
    r"c:\windows\syswow64",
    r"c:\windows\winsxs",
    r"c:\windows\installer",
    r"c:\windows\systemapps",
    r"c:\windows\servicing",
    r"c:\program files",
    r"c:\program files (x86)",
)

MOVE_NAMES = {"downloads", "desktop", "documents", "pictures", "videos", "music"}


def long_path(path: Path) -> str:
    text = str(path)
    if text.startswith("\\\\?\\"):
        return text
    if os.name == "nt" and path.is_absolute():
        return "\\\\?\\" + text
    return text


def display_path(path: Path) -> str:
    return str(path)


def bytes_to_gb(size: int) -> float:
    return round(size / GB, 2)


def classify(path: Path) -> tuple[str, str]:
    lowered = str(path).lower()
    name = path.name.lower()

    if any(lowered.startswith(prefix) for prefix in RED_PREFIXES):
        return "RED", "安装目录/Windows核心区域，优先用卸载器或系统工具，避免手删。"
    if name in GREEN_NAMES or any(part.lower() in GREEN_NAMES for part in path.parts):
        return "GREEN", "可重建缓存或临时文件；关闭相关程序后通常可删。"
    if name in MOVE_NAMES:
        return "MOVE", "用户文件夹；适合迁移到D盘，但需要用户确认。"
    if name in YELLOW_NAMES or any(name.startswith(item) for item in ("$winreagent",)):
        return "YELLOW", "需要确认；可能影响恢复、更新、修复、卸载或用户文件。"
    if "cache" in name or "temp" in name:
        return "GREEN", "名称显示为缓存/临时目录；仍建议先确认所属程序。"
    if "appdata" in lowered or "programdata" in lowered:
        return "YELLOW", "应用数据区域；需要继续看子目录，不能整目录删除。"
    return "YELLOW", "大文件夹；需要人工判断用途。"


def stat_is_reparse(stat_result: os.stat_result) -> bool:
    return bool(getattr(stat_result, "st_file_attributes", 0) & REPARSE_POINT)


def safe_scandir(path: Path):
    try:
        with os.scandir(long_path(path)) as iterator:
            return list(iterator), None
    except OSError as exc:
        return [], str(exc)


def entry_path(entry: os.DirEntry[str]) -> Path:
    return Path(entry.path.replace("\\\\?\\", ""))


def folder_size(path: Path, max_errors: int = 50) -> tuple[int, int]:
    total = 0
    errors = 0
    stack = [path]

    while stack:
        current = stack.pop()
        entries, error = safe_scandir(current)
        if error:
            errors += 1
            if errors > max_errors:
                continue
            continue

        for entry in entries:
            try:
                st = entry.stat(follow_symlinks=False)
            except OSError:
                errors += 1
                continue

            if entry.is_dir(follow_symlinks=False):
                if stat_is_reparse(st):
                    continue
                stack.append(entry_path(entry))
            else:
                total += st.st_size

    return total, errors


def child_rows(parent: Path, threshold: int) -> list[dict]:
    rows = []
    entries, error = safe_scandir(parent)
    if error:
        return [
            {
                "path": display_path(parent),
                "parent": display_path(parent.parent),
                "size": 0,
                "gb": 0,
                "risk": "ERROR",
                "note": error,
                "errors": 1,
            }
        ]

    for entry in entries:
        path = entry_path(entry)
        try:
            st = entry.stat(follow_symlinks=False)
        except OSError:
            continue

        if entry.is_dir(follow_symlinks=False):
            if stat_is_reparse(st):
                continue
            size, errors = folder_size(path)
        else:
            size, errors = st.st_size, 0

        if size < threshold:
            continue

        risk, note = classify(path)
        rows.append(
            {
                "path": display_path(path),
                "parent": display_path(parent),
                "size": size,
                "gb": bytes_to_gb(size),
                "risk": risk,
                "note": note,
                "errors": errors,
            }
        )

    return sorted(rows, key=lambda item: item["size"], reverse=True)


def existing_scan_levels(user_profile: Path) -> list[Path]:
    candidates = [
        Path(r"C:\\"),
        user_profile,
        user_profile / "AppData" / "Local",
        user_profile / "AppData" / "Roaming",
        Path(r"C:\\ProgramData"),
        Path(r"C:\\Program Files"),
        Path(r"C:\\Program Files (x86)"),
        Path(r"C:\\Windows"),
        Path(r"C:\\Recovery"),
    ]
    return [path for path in candidates if path.exists()]


def disk_info(root: str = "C:\\") -> dict:
    usage = shutil.disk_usage(root)
    return {
        "total": usage.total,
        "used": usage.used,
        "free": usage.free,
        "total_gb": bytes_to_gb(usage.total),
        "used_gb": bytes_to_gb(usage.used),
        "free_gb": bytes_to_gb(usage.free),
        "used_percent": round((usage.used / usage.total) * 100, 1) if usage.total else 0,
    }


def render_html(report: dict) -> str:
    rows_html = []
    risk_order = {"GREEN": 0, "MOVE": 1, "YELLOW": 2, "RED": 3, "ERROR": 4}
    rows = sorted(report["rows"], key=lambda row: (risk_order.get(row["risk"], 9), -row["size"]))

    for row in rows:
        risk = html.escape(row["risk"])
        rows_html.append(
            "<tr>"
            f"<td><span class='pill {risk.lower()}'>{risk}</span></td>"
            f"<td class='size'>{row['gb']:.2f} GB</td>"
            f"<td><code>{html.escape(row['path'])}</code></td>"
            f"<td>{html.escape(row['note'])}</td>"
            f"<td>{row['errors']}</td>"
            "</tr>"
        )

    c = report["c_drive"]
    d = report.get("d_drive")
    d_html = ""
    if d:
        d_html = f"<div class='metric'><b>D:</b><span>{d['free_gb']:.2f} GB free / {d['total_gb']:.2f} GB</span></div>"

    return f"""<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>C Drive Savior / C盘拯救者</title>
<style>
:root {{
  color-scheme: light;
  --bg: #f7f8fb;
  --fg: #18202b;
  --muted: #667085;
  --line: #d9dee8;
  --green: #0f766e;
  --yellow: #a16207;
  --red: #b42318;
  --move: #2563eb;
}}
body {{
  margin: 0;
  font-family: "Microsoft YaHei", "Segoe UI", Arial, sans-serif;
  background: var(--bg);
  color: var(--fg);
}}
main {{
  max-width: 1180px;
  margin: 0 auto;
  padding: 28px;
}}
h1 {{
  margin: 0 0 8px;
  font-size: 28px;
}}
.sub {{
  color: var(--muted);
  margin-bottom: 20px;
}}
.panel {{
  border: 1px solid var(--line);
  border-radius: 8px;
  background: white;
  padding: 18px;
  margin-bottom: 18px;
}}
.metrics {{
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(210px, 1fr));
  gap: 12px;
}}
.metric {{
  border: 1px solid var(--line);
  border-radius: 8px;
  padding: 14px;
  display: flex;
  flex-direction: column;
  gap: 6px;
}}
.bar {{
  height: 16px;
  border-radius: 999px;
  background: #e8edf5;
  overflow: hidden;
  margin-top: 12px;
}}
.bar span {{
  display: block;
  height: 100%;
  width: {c['used_percent']}%;
  background: linear-gradient(90deg, #2563eb, #b42318);
}}
table {{
  width: 100%;
  border-collapse: collapse;
  font-size: 14px;
}}
th, td {{
  border-bottom: 1px solid var(--line);
  padding: 10px 8px;
  text-align: left;
  vertical-align: top;
}}
th {{
  color: var(--muted);
  font-weight: 600;
}}
code {{
  word-break: break-all;
}}
.size {{
  white-space: nowrap;
  font-variant-numeric: tabular-nums;
}}
.pill {{
  display: inline-block;
  min-width: 64px;
  text-align: center;
  border-radius: 999px;
  padding: 3px 8px;
  color: white;
  font-size: 12px;
  font-weight: 700;
}}
.green {{ background: var(--green); }}
.yellow {{ background: var(--yellow); }}
.red {{ background: var(--red); }}
.move {{ background: var(--move); }}
.error {{ background: #475467; }}
.legend {{
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(230px, 1fr));
  gap: 10px;
  color: var(--muted);
  font-size: 14px;
}}
</style>
</head>
<body>
<main>
  <h1>C Drive Savior / C盘拯救者</h1>
  <div class="sub">只读扫描。生成时间：{html.escape(report['generated_at'])}。阈值：{report['threshold_gb']} GB。</div>
  <section class="panel">
    <div class="metrics">
      <div class="metric"><b>C:</b><span>{c['free_gb']:.2f} GB free / {c['total_gb']:.2f} GB</span></div>
      <div class="metric"><b>已用</b><span>{c['used_gb']:.2f} GB ({c['used_percent']:.1f}%)</span></div>
      <div class="metric"><b>候选项</b><span>{len(report['rows'])} 个超过阈值</span></div>
      {d_html}
    </div>
    <div class="bar"><span></span></div>
  </section>
  <section class="panel legend">
    <div><b>GREEN</b>：缓存/临时文件，通常可重建。</div>
    <div><b>MOVE</b>：用户文件，适合迁移到D盘。</div>
    <div><b>YELLOW</b>：需要确认，可能影响修复/卸载/恢复。</div>
    <div><b>RED</b>：系统或安装目录，不建议手动删除。</div>
  </section>
  <section class="panel">
    <table>
      <thead>
        <tr><th>级别</th><th>大小</th><th>路径</th><th>建议</th><th>扫描错误</th></tr>
      </thead>
      <tbody>
        {''.join(rows_html)}
      </tbody>
    </table>
  </section>
</main>
</body>
</html>
"""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="C Drive Savior read-only C: drive cleanup panel generator.")
    parser.add_argument("--threshold-gb", type=float, default=1.0, help="Only include items at or above this size.")
    parser.add_argument("--user-profile", default=str(Path.home()), help="User profile path to inspect.")
    parser.add_argument("--output-dir", default=str(Path.cwd()), help="Where to write JSON and HTML reports.")
    parser.add_argument("--open", action="store_true", help="Open the generated HTML report.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    threshold = int(args.threshold_gb * GB)
    user_profile = Path(args.user_profile)
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    rows = []
    for level in existing_scan_levels(user_profile):
        rows.extend(child_rows(level, threshold))

    seen = set()
    unique_rows = []
    for row in rows:
        key = row["path"].lower()
        if key in seen:
            continue
        seen.add(key)
        unique_rows.append(row)

    report = {
        "generated_at": dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "threshold_gb": args.threshold_gb,
        "c_drive": disk_info("C:\\"),
        "d_drive": disk_info("D:\\") if Path("D:\\").exists() else None,
        "rows": sorted(unique_rows, key=lambda item: item["size"], reverse=True),
    }

    timestamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    json_path = output_dir / f"c-drive-scan-{timestamp}.json"
    html_path = output_dir / f"c-drive-panel-{timestamp}.html"
    json_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    html_path.write_text(render_html(report), encoding="utf-8")

    print(f"JSON: {json_path}")
    print(f"HTML: {html_path}")
    print(f"C: free {report['c_drive']['free_gb']:.2f} GB / total {report['c_drive']['total_gb']:.2f} GB")
    print(f"Rows >= {args.threshold_gb} GB: {len(report['rows'])}")

    if args.open:
        if os.name == "nt":
            os.startfile(str(html_path))  # type: ignore[attr-defined]
        else:
            subprocess.run(["xdg-open", str(html_path)], check=False)

    return 0


if __name__ == "__main__":
    sys.exit(main())
