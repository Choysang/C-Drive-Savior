---
name: c-drive-savior
description: C Drive Savior / C盘拯救者. Windows C drive diagnosis and safe cleanup workflow for Codex. Use this skill whenever the user says C盘满了, C盘快满了, 清理C盘, 电脑空间不够, 帮我清理电脑空间, analyze C drive, clean system drive, or asks what can be deleted or moved to D:. It scans first, builds a friendly local report, classifies large items by risk, cleans rebuildable caches only after confirmation, protects Windows/app data, and produces a before/after cleanup report.
---

# C Drive Savior / C盘拯救者

Use this skill for Chinese or English requests such as:

- "C盘满了", "清理C盘", "磁盘空间不够", "看看C盘哪些能删"
- "哪些可以移到D盘", "帮我清理缓存", "生成清理报告"
- "scan C drive", "clean Windows disk", "what can I delete from AppData/ProgramData/Windows"

## Core Principles

1. Start read-only.
   - First scan C: and show disk usage, large folders, risk levels, and candidate actions.
   - Do not delete, move, repair, uninstall, or change registry before explicit user confirmation.

2. Sort by same-level size.
   - For each inspected level, list direct children from largest to smallest.
   - Only investigate items above the threshold, default `1 GB`.

3. Clean in phases.
   - Phase A: safe rebuildable caches and temporary files.
   - Phase B: user-confirmed reinstall/repair caches and installer downloads.
   - Phase C: user-confirmed unused software through uninstallers.
   - Phase D: user data that can be moved to D: without breaking apps.
   - Phase E: Windows servicing cleanup through supported tools only.

4. Protect system integrity.
   - Never manually delete Windows core folders, app installation folders, installer cache, or recovery assets unless the specific item is classified and confirmed.
   - Prefer supported Windows tools, app uninstallers, and vendor installers over hand deletion.

5. Produce a report.
   - Always record before/after free space when possible.
   - List what was cleaned, skipped, needs confirmation, and any errors.

## Required Workflow

1. State assumptions and success criteria briefly.
   - Assumption example: "我会先只读扫描，不会删除。"
   - Success criteria example: "生成面板、列出 >1GB 项、只清理可重建缓存、输出清理报告。"

2. Run the read-only panel scan.
   - Prefer the bundled script:

```powershell
python "D:\MovedFromC\Users\CaiCaixin\.codex\skills\c-drive-savior\scripts\c_drive_panel.py" --threshold-gb 1 --open
```

   - If Python is unavailable, use PowerShell `Get-ChildItem`/`Measure-Object` read-only commands and create a concise Markdown table.

3. Classify candidates.
   - Use `references/decision-model.md`.
   - Mark each large item as:
     - `GREEN`: rebuildable cache/temp/log; can usually delete after closing related apps.
     - `YELLOW`: current app data, installer/repair cache, old update/recovery data, or user-owned data; needs confirmation.
     - `RED`: Windows core, package manager state, installed program files, active app data; do not delete manually.
     - `MOVE`: user-owned data that can move to D: with path updates or a clear restore plan.

4. Ask confirmation only for ambiguous items.
   - Do not ask about obvious safe cache batches unless the user requested strict confirmation.
   - Ask about software/user data/recovery packages with concrete consequences:
     - "删除后可能需要重新下载/重新安装"
     - "会影响卸载/修复"
     - "会影响恢复出厂/OEM恢复"
     - "移动后需要更新项目路径/软件路径"

5. Execute confirmed actions.
   - Use Administrator PowerShell for protected locations.
   - Close related apps before deleting locked caches.
   - Escape `$` paths correctly in PowerShell. Prefer single quotes:

```powershell
Remove-Item -LiteralPath 'C:\$WINDOWS.~BT' -Recurse -Force
Remove-Item -LiteralPath 'C:\$WinREAgent.bak-20260704-164228' -Recurse -Force
```

   - For long path deletion through `cmd`, escape `$` in PowerShell double-quoted strings:

```powershell
cmd /c rmdir /s /q "\\?\C:\`$WINDOWS.~BT"
```

6. Verify and report.
   - Re-read disk free space.
   - Generate a cleanup report with:
     - before/after C: usage
     - deleted paths and sizes
     - moved paths and destination
     - skipped/risky items
     - failed commands and likely cause
     - next manual uninstall/move suggestions

## Never Do

- Do not manually delete:
  - `C:\Windows\System32`
  - `C:\Windows\SysWOW64`
  - `C:\Windows\WinSxS`
  - `C:\Windows\Installer`
  - `C:\Windows\SystemApps`
  - `C:\Windows\servicing`
  - `C:\Program Files\Common Files` as a whole
  - `C:\Program Files` or `C:\Program Files (x86)` app folders unless the app is already uninstalled or the user explicitly accepts hand deletion of leftovers.

- Do not run `DISM /ResetBase` casually.
  - It prevents uninstalling superseded Windows updates.
  - If `DISM`, `SFC`, or `C:\Windows\WinSxS\Catalogs` is broken/missing, stop Windows component cleanup and recommend repair/in-place repair first.

- Do not delete `C:\ProgramData\Package Cache` wholesale without explaining:
  - Current apps usually keep running.
  - Repair/modify/uninstall may fail and require the original installer.

- Do not move installed apps by dragging folders to D:.
  - Use app settings, official migration, uninstall/reinstall to D:, or a clearly explained junction only for advanced cases.

## Useful References

- `references/decision-model.md`: classification, safe caches, D: move rules, protected paths, historical failure lessons.
- `references/research-sources.md`: official Windows/Microsoft guidance distilled for this skill.
- `scripts/c_drive_panel.py`: read-only scanner and HTML dashboard generator.
