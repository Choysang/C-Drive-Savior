---
name: c-drive-savior
description: C Drive Savior / C盘拯救者. Windows C drive diagnosis, safe cleanup, move-to-D migration, and cleanup reporting. Use whenever the user says C盘满了, C盘快满了, 清理C盘, 电脑空间不够, 磁盘空间不足, 帮我清理电脑空间, C盘瘦身, 把文件移到D盘, analyze C drive, clean system drive, disk full, or asks what can be deleted or moved to D:. Scans first with a disk-usage panel, classifies large items by risk, cleans rebuildable caches, migrates user data to D: with verification, and produces a before/after cleanup report.
---

# C Drive Savior / C盘拯救者

Five-phase pipeline: **Scan panel -> Confirm -> Safe clean -> Migrate to D: -> Report**. Read-only until the user approves. All scripts are PowerShell 5.1/7 compatible; paths below are relative to this skill's directory.

## Iron rules

1. **Read-only first.** No delete/move/uninstall/registry change before the panel is shown and the user confirms.
2. **Read `references/pitfalls.md` before writing any cleanup command.** Every entry is a real past failure ($-path expansion, locked files, the /ResetBase incident, Package Cache breakage, elevation, robocopy semantics...).
3. **One confirmation round, not twenty.** Collect ALL items needing a decision into one numbered list; the user answers once.
4. **Servicing health gate.** Never run DISM cleanup / touch WinSxS before `AnalyzeComponentStore` says the store is healthy (pitfalls.md #6). Never suggest `/ResetBase` casually.
5. **Report actuals.** Freed space is measured, failures are listed with their errors. Never fabricate results.

## Phase 1 — Scan + panel (read-only)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/scan.ps1 -ThresholdGB 1 -OpenReport
```
- Produces: console panel (disk bar + insight + hidden consumers + tier table), `scan-*.json` (the report baseline — keep it), HTML dashboard.
- Hidden consumers (pagefile/hiberfil/VSS/Recycle Bin/update cache) are listed separately — folder scans cannot see them; use them to explain "where did my disk go".
- Elevated shell gives more data (VSS size; `-AnalyzeWinSxS` adds true WinSxS size). Not required.
- Alternative scanner: `python scripts/c_drive_panel.py --threshold-gb 1 --open` (faster on huge trees if Python exists).
- Summarize in chat: one-line insight (top consumer + estimated reclaimable), then the top items. Don't paste the whole table.

## Phase 2 — One-round confirmation

Build ONE numbered decision list from scan rows + `references/decision-model.md` tiers:
1. GREEN batch (list ids + total GB) — approve auto-clean? Any folder to protect/keep?
2. Each YELLOW item — state the concrete consequence (use decision-model.md prompt patterns): repair-cache loss, rollback loss, chat data, orphaned apps, hiberfil/pagefile trade-offs.
3. Unused software candidates (by size + last-used evidence) — uninstall via official uninstaller only.
4. MOVE candidates + destination (default `D:\MovedFromC\...`).

Wait for the user's answers. Record decisions; do not re-ask later.

## Phase 3 — Safe clean (GREEN)

```powershell
# preview (default = dry-run, measures only)
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/clean.ps1
# execute user-level items (close flagged processes first; script skips locked apps)
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/clean.ps1 -Execute [-Exclude id,id]
# admin items (Windows temp, update cache, WER, dumps, recycle bin) - UAC prompt:
Start-Process powershell -Verb RunAs -ArgumentList '-ExecutionPolicy','Bypass','-File','<abs path>\scripts\clean.ps1','-Execute','-Include','temp-windows,wu-cache,delivery-opt,minidump,memdump,wer-system,recyclebin'
```
- Agent shells usually cannot elevate (pitfalls.md #5): hand the `Start-Process -Verb RunAs` line to the user, or have them paste into an admin PowerShell. Logs land in `%USERPROFILE%\c-drive-savior\actions-*.json` either way.
- Supported system cleanup on top (admin, optional): Storage Sense one-off; `Dism /Online /Cleanup-Image /StartComponentCleanup` ONLY behind the health gate.
- YELLOW items the user approved: execute individually with exact quoting from pitfalls.md #1 (`-LiteralPath`, single quotes for `$` paths).

## Phase 4 — Migrate to D:

Priority: **app-native setting > official export/import > known-folder redirection > junction** (`references/relocation-guide.md` has per-app steps: WeChat 4.0, QQ/钉钉/WPS, Steam, Docker, WSL, dev caches, OneDrive, pagefile, iTunes backups, CompactOS).

Generic folder mover (preflight + robocopy + verify + undo log):
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/migrate.ps1 -Source 'C:\path' [-Dest 'D:\...'] [-Junction | -DeleteSource] -Execute
```
- Known folders (Desktop/Documents/Downloads...): registry redirection per relocation-guide.md #1, NOT bare moves. Moving Documents also carries WeChat 4.0 data.
- The script refuses OneDrive paths, system dirs, and short-on-space targets by design.
- After each migration, verify the owning app still works before deleting any kept source copy.

## Phase 5 — Cleanup report

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/report.ps1 -Baseline <scan-*.json from Phase 1> -OpenReport
```
- HTML + console: net freed GB (disk-level, hero number), before/after bars, per-action table with undo notes, skipped/failed items, maintenance advice.
- In chat, lead with the outcome: "释放了 X GB（C: 可用 A -> B GB）", then top contributors, then failures/skips with reasons.

## Never do

- Hand-delete: `System32`, `SysWOW64`, `WinSxS`, `C:\Windows\Installer`, `SystemApps`, `servicing`, `WindowsApps`, whole `Program Files`/`Common Files`/`ProgramData`, whole browser `User Data`, `%LOCALAPPDATA%\Packages`.
- DISM `/ResetBase` without explicit consent AND a healthy store; any WinSxS surgery when `Catalogs` is missing or sfc fails — recommend in-place repair instead.
- Bulk-delete `Package Cache` / `Windows Installer` (breaks repair/uninstall — real incident, pitfalls.md #7).
- Junction OneDrive-managed folders; drag-move installed apps to D:.
- Delete chat data (`xwechat_files`, `WeChat Files`, QQ) or user files without an explicit per-item decision.
- Registry "cleaners".

## References

- `references/pitfalls.md` — 24 field-tested failures + fixes. **Read before any command.**
- `references/decision-model.md` — GREEN/YELLOW/RED/MOVE catalog, hidden consumers, execution order, prompt patterns.
- `references/relocation-guide.md` — per-app move-to-D playbook.
- `references/research-sources.md` — distilled official guidance (Microsoft Learn/Support).
- `scripts/` — `scan.ps1` (panel), `clean.ps1` (tier-1, dry-run default), `migrate.ps1` (move+verify+junction), `report.ps1` (before/after), `c_drive_panel.py` (alt scanner).
