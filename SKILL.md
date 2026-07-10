---
name: c-drive-savior
description: C Drive Savior / C盘拯救者. Windows C drive diagnosis, safe cleanup, move-to-D migration, and measured reporting. Use whenever the user says C盘满了, C盘快满了, 清理C盘, 电脑空间不足, 帮我清理电脑空间, C盘瘦身, 把文件移到D盘, analyze C drive, clean system drive, disk full, or asks what can be deleted or moved to D:. Scan first, collect one confirmation, execute only approved catalog actions in one guarded session, stage verified migrations, and report measured results.
---

# C Drive Savior / C盘拯救者

Use one guarded session through five phases: **Scan -> Confirm -> Clean -> Migrate -> Report**. Runtime scripts support Windows PowerShell 5.1 and PowerShell 7. Python is an optional alternative scanner, not a requirement.

## Non-negotiable rules

1. Start read-only. Do not delete, move, uninstall, change registry values, stop services, or run servicing cleanup before showing the scan panel and receiving approval.
2. Read `references/pitfalls.md` before generating any action. It records real failures involving `$` paths, Package Cache, DISM, reparse points, elevation, encoding, sessions, and verification.
3. Run exactly one scanner for the operational session. Keep the printed Session ID and pass the same `-SessionId` and `-SessionRoot` through every later phase.
4. Ask once. Present every GREEN action ID, YELLOW consequence, RED refusal, MOVE row ID/destination, protected path, and unused-app candidate in one numbered decision list.
5. Use the bundled scripts for filesystem actions. Never construct direct deletion commands. YELLOW and RED rows are explanations or official-tool/manual workflows, not inputs to `clean.ps1`.
6. Never claim a complete scan when `scan_complete` is false. Name denied paths and skipped reparse points.
7. Report raw measured bytes. Keep disk-level net change separate from action-attributable released bytes; show failures and partial results.

Set one root for the whole session:

```powershell
$sessionRoot = "$env:USERPROFILE\c-drive-savior\sessions"
```

## Phase 1: Scan and panel

Choose exactly one scanner.

```powershell
# Canonical, zero third-party runtime dependencies
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/scan.ps1 `
  -ThresholdGB 1 -SessionRoot $sessionRoot -OpenReport

# Optional alternative when Python is already installed
python scripts/c_drive_panel.py --threshold-gb 1 --session-root "$sessionRoot" --open
```

Capture the printed Session ID. Read that session's `scan.json` and `panel.html`. Summarize the disk state, one-line insight, Top 5, cleanup rows with `action_id`, MOVE rows with `id`, hidden/system gap, denied paths, and whether the scan completed. Do not combine output from both scanners.

## Phase 2: One-round decision

Read `references/decision-model.md`, then present one numbered list:

1. GREEN cleanup actions: `action_id`, path, measured bytes, rebuild effect, owning process, and whether admin is needed.
2. YELLOW rows: exact consequence and recommendation to keep, use an official UI, back up, uninstall, or migrate.
3. RED rows: explain why hand deletion is refused and name the supported tool or uninstaller.
4. MOVE rows: row `id`, source, proposed fixed non-system destination, and migration method.
5. Protected paths and software the user confirms they no longer need.

After the user answers, record the entire immutable decision:

```powershell
& scripts/decide.ps1 -SessionId $sid -SessionRoot $sessionRoot `
  -ApproveClean @('temp-user','npm') `
  -ApproveMove @('<move-row-id>') `
  -Protect @('C:\Users\name\Documents\keep')
```

Use only IDs present in that scan. If the answer changes later, create a new scan session; do not overwrite the existing decision.

## Phase 3: Approved GREEN cleanup

Preview selected catalog items first:

```powershell
& scripts/clean.ps1 -Include @('temp-user','npm')
```

Execute user-level items only after the decision exists:

```powershell
& scripts/clean.ps1 -Execute -SessionId $sid -SessionRoot $sessionRoot `
  -Include @('temp-user','npm')
```

For admin items, preserve the same session ID and root. Ask the user to run the equivalent bundled `clean.ps1` command in an administrator PowerShell, or use `Start-Process powershell -Verb RunAs` with those exact values. Never omit `-SessionId`; never replace the script with ad hoc `Remove-Item` commands. Read `actions.jsonl` afterward and report locked, skipped, partial, or service-restoration failures.

Windows servicing is outside routine GREEN cleanup. Only discuss `DISM /StartComponentCleanup` after the health gate in `pitfalls.md` #6 passes. Do not suggest `/ResetBase` as routine cleanup.

## Phase 4: Verified migration

Prefer application settings, official export/import, and Windows known-folder redirection. Use the generic mover only for an approved MOVE row and after reading `references/relocation-guide.md`.

```powershell
# Stage copies and verifies; source remains untouched
& scripts/migrate.ps1 -Stage -Source 'C:\path' -Dest 'D:\MovedFromC\path' `
  -SessionId $sid -SessionRoot $sessionRoot
```

Stop and ask the user to reopen the owning application and exercise normal read/write behavior. Do not Finalize until the user confirms that smoke test.

```powershell
# Choose one only after user verification
& scripts/migrate.ps1 -Finalize -Source 'C:\path' -Dest 'D:\MovedFromC\path' `
  -DeleteSource -SessionId $sid -SessionRoot $sessionRoot

& scripts/migrate.ps1 -Finalize -Source 'C:\path' -Dest 'D:\MovedFromC\path' `
  -Junction -SessionId $sid -SessionRoot $sessionRoot
```

The script refuses OneDrive paths, system/install locations, overlapping targets, unsafe file semantics, removable/system destinations, insufficient space, manifest drift, and hash mismatches. Prefer `-DeleteSource`; use a junction only when an application cannot change its path and OneDrive is not involved.

## Phase 5: Session report

```powershell
& scripts/report.ps1 -SessionId $sid -SessionRoot $sessionRoot -OpenReport
```

Lead with: disk-level net released bytes and C: free space before/after. Then show action-attributable bytes, the difference, top completed actions, partial/failed/skipped entries, undo information, denied scan paths, and maintenance advice. Never merge historical action logs or convert a malformed action into success.

## Never do

- Hand-delete `System32`, `SysWOW64`, `WinSxS`, `Windows\Installer`, `SystemApps`, `servicing`, `WindowsApps`, whole `Program Files`, `Common Files`, whole `ProgramData`, whole browser `User Data`, or whole `%LOCALAPPDATA%\Packages`.
- Bulk-delete `Package Cache` or installer caches. Prefer named-app uninstall/reinstall or backup-to-D after explicit acceptance of repair loss.
- Delete chat history, cloud sync roots, project data, Downloads, Desktop, or Documents without an item-specific decision.
- Junction a OneDrive-managed path, drag-move an installed app, use registry cleaners, follow reparse points, or delete a migration source before fresh verification.

## References

- `references/pitfalls.md`: mandatory failure catalog before any action.
- `references/decision-model.md`: tier meanings, action IDs, and one-round prompt structure.
- `references/relocation-guide.md`: app-native moves and Stage/Finalize migration.
- `references/research-sources.md`: evidence and source policy.
- `benchmarks/README.md`: reproducible scanner benchmark method; do not invent performance claims.
