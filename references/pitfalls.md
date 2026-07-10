# Pitfalls: Field-Tested Error Catalog

Every entry comes from a real failure in past cleanup sessions on this machine, or from an adversarial review of what naive cleaners get wrong. Read this BEFORE writing any cleanup command. Format: symptom -> root cause -> correct handling.

## 1. PowerShell expands `$` in double-quoted paths

Symptom: `Remove-Item "C:\$WINDOWS.~BT"` silently targets `C:\.~BT` (path not found), because `$WINDOWS` parses as a variable.

Rules:
- Always use single quotes + `-LiteralPath`: `Remove-Item -LiteralPath 'C:\$WINDOWS.~BT' -Recurse -Force`
- In double quotes escape with backtick: `` "\\?\C:\`$WINDOWS.~BT" ``
- Affected real paths: `C:\$WINDOWS.~BT`, `C:\$WinREAgent*`, `C:\$Recycle.Bin`, `C:\$GetCurrent`, `C:\$SysReset`.
- Brackets `[ ]` in paths break `-Path` wildcard parsing too — use `-LiteralPath` everywhere.

## 2. `foreach` statement cannot be piped (ParserError)

Symptom: `ParserError: ... } | Sort-Object` when writing `foreach ($x in $list) { ... } | Sort-Object`.

Root cause: `foreach (...) {}` is a statement, not an expression; it has no pipeline output position.

Fix: wrap in `$( )`, collect into an array (`$rows += ...` then `$rows | Sort-Object`), or use the `ForEach-Object` cmdlet inside a pipeline.

## 3. Target PowerShell 5.1 AND 7

- No `&&` / `||` in 5.1. No ternary. Chain with `;` or `if`.
- Non-ASCII string literals require the `.ps1` saved as **UTF-8 with BOM**, or 5.1 parses them as ANSI/GBK and produces mojibake or parse errors.
- Console output: Chinese text is fine, but avoid emoji and box-drawing characters in console output — they garble in conhost. Save rich formatting for the HTML report.
- Use `[math]::Round()` and invariant formatting for sizes; never parse localized number strings.

## 4. Locked files: "file in use" / "directory not empty"

Symptom: `Remove-Item : ... model.tflite 文件正由另一进程使用` (file is being used by another process); or a folder delete "fails" with *directory not empty* — that only means locked leftovers survived, not that the path was wrong.

Order of operations:
1. Identify and close the owning app first: `Get-Process chrome -ErrorAction SilentlyContinue` -> confirm with user -> `Stop-Process -Name chrome -Force`.
2. Retry the delete. Partial success is normal; report what remains.
3. Stubborn system leftovers (long paths, weird ACLs): the empty-mirror trick, run elevated:
   ```powershell
   New-Item -ItemType Directory -Path C:\empty-delete -Force
   robocopy C:\empty-delete "\\?\C:\`$WINDOWS.~BT" /MIR /R:0 /W:0
   cmd /c rmdir /s /q "\\?\C:\`$WINDOWS.~BT"
   Remove-Item -LiteralPath C:\empty-delete -Recurse -Force
   ```
4. Never kill processes the user did not approve; never kill system processes to force a delete.

Known lockers: Chrome/Edge background mode (`optimization_guide_model_store`), OneDrive, Docker Desktop, WeChat, antivirus scans.

## 5. Elevation failures

Symptoms seen live: DISM `Error: 740  Elevated permissions are required`; `Get-Service WaaSMedicSvc` -> `PermissionDenied`; agent sandbox error `SetNamedSecurityInfoW ... failed: 5`.

Rules:
- Detect first: `([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)`
- Agent shells are often sandboxed and CANNOT elevate. Correct pattern: write the commands to a `.ps1`, then either `Start-Process powershell -Verb RunAs -ArgumentList '-ExecutionPolicy','Bypass','-File',$path` (UAC prompt for the user) or ask the user to paste into an admin PowerShell. Scripts must log results to a file the agent can read afterwards.
- Needs elevation: DISM, `sfc`, `vssadmin`, `powercfg /h`, deleting under `C:\Windows`, `C:\ProgramData`, other users' profiles, `C:\$Recycle.Bin`, stopping services.

## 6. Component store health gate (the /ResetBase incident)

Real incident: `DISM /StartComponentCleanup /ResetBase` failed at 94.9% with `错误: 2 系统找不到指定的文件` (error 2, file not found); `sfc /scannow` -> `Windows 资源保护无法执行请求的操作`; root cause `C:\Windows\WinSxS\Catalogs` missing -> `STATUS_OBJECT_NAME_NOT_FOUND`, "Failed to load component store".

Iron rules:
1. BEFORE any servicing cleanup, run `Dism /Online /Cleanup-Image /AnalyzeComponentStore` (elevated). If it errors, or `Test-Path 'C:\Windows\WinSxS\Catalogs'` is false, or sfc refuses to run: **stop all WinSxS/servicing cleanup**. Recommend Windows Update repair / in-place upgrade repair first. Never create or delete anything inside WinSxS by hand.
2. `/StartComponentCleanup` only when the analyze step recommends cleanup and the store is healthy.
3. `/ResetBase` only with explicit user consent to the trade-off (cannot uninstall existing updates afterwards) and only on a healthy store. Never propose it as a routine step.
4. On failure read `C:\Windows\Logs\DISM\dism.log` and `C:\Windows\Logs\CBS\CBS.log` (Select-String, last entries).

## 7. Installer caches break repair/uninstall later (the PDF Editor incident)

Real incident: after `C:\ProgramData\Package Cache` entries were cleaned, an app's "Change/Repair" later failed with *Windows cannot find C:\ProgramData\Package Cache\...*. Fix required re-downloading the original installer.

- `C:\ProgramData\Package Cache` and `C:\Windows\Installer` (.msi/.msp) are NOT junk. Apps keep running without them, but modify/repair/update/uninstall breaks.
- Never bulk-delete. If the user accepts the trade-off for specific huge entries, name the app, state the consequence, and prefer moving the entry to D: as a backup over deleting.
- `C:\Windows\Installer` orphan analysis (PatchCleaner-style) is advanced/optional; whole-folder deletion is always wrong.

## 8. Slow scan anti-pattern

Symptom: per-folder `Get-ChildItem -Recurse | Measure-Object` loops took minutes and hit 120s shell timeouts repeatedly.

- Use the bundled single-pass scanner (`scripts/scan.ps1` or `scripts/c_drive_panel.py`), not dozens of ad-hoc recursive measurements.
- If ad-hoc sizing is unavoidable, set a generous timeout (>=300s for large trees) and size one tree at a time.

## 9. Reparse points: loops, double counting, WinSxS illusion

- Always skip reparse points (junctions/symlinks) when sizing, or sizes double-count and recursion can loop. Legacy junctions like `Application Data`, `My Documents` inside profiles are traps.
- `WinSxS` apparent size is inflated by hard links. True size ONLY via `Dism /Online /Cleanup-Image /AnalyzeComponentStore` ("Actual Size of Component Store"). Never quote folder-scan numbers for WinSxS.
- OneDrive Files On-Demand placeholders report full size but occupy little disk. Freeing them locally is `attrib +U -P /s` (free up space), not delete.

## 10. Hidden consumers: why folder totals never add up

A folder scan misses: `pagefile.sys` / `hiberfil.sys` / `swapfile.sys`, `System Volume Information` (VSS restore points — size via `vssadmin list shadowstorage`, elevated), Recycle Bin, Windows reserved storage (`Get-WindowsReservedStorageState`), search index (`Windows.edb`). The panel must list these separately and show `disk used − sum(scanned)` as "unaccounted", or users think the scan is broken.

## 11. Windows Update cache needs services stopped

Deleting `C:\Windows\SoftwareDistribution\Download` while `wuauserv`/`bits` run -> access denied or instant regrowth. Sequence (elevated): `Stop-Service wuauserv,bits` -> delete contents -> `Start-Service wuauserv,bits`. Never delete `SoftwareDistribution\DataStore` (update history DB) unless explicitly repairing Windows Update.

## 12. OneDrive-managed folders: never junction

Junctioning `OneDrive`, or Desktop/Documents that OneDrive syncs, corrupts sync state. Use OneDrive settings (move sync root) or Files On-Demand "free up space". If Desktop/Documents are under OneDrive control, folder redirection must go through OneDrive, not the Location tab.

## 13. WeChat 4.0 locked its data to C:

- WeChat >= 4.0 stores data in `%USERPROFILE%\Documents\xwechat_files`; the in-app custom-location setting is gone; legacy `WeChat Files` may coexist -> space doubles after upgrade.
- In-app dedupe first: 设置 -> 账号与存储 -> 存储管理 -> 清理历史版本冗余数据 (clean legacy-version redundant data). Often frees tens of GB.
- To move to D:: redirect the whole **Documents** known folder (Properties -> Location tab), which WeChat follows. Junctioning only `xwechat_files` is untested against WeChat updates; last resort with explicit consent.
- Never delete `xwechat_files` / `WeChat Files` content: chat history and received files are unrecoverable user data.

## 14. Verify "orphaned" before treating as junk

- Empty shells (e.g. a 0 MB `Visual Studio\2019` folder) are safe deletes — verify size ~0 first.
- A package-manager folder whose command is missing from PATH (e.g. `scoop` dir but `scoop` not found) is *probably* residue, but confirm with the user; binaries inside may still be invoked by absolute path.

## 15. Vendor suites with live services

OEM suites (Huawei PC Manager, Lenovo Vantage, ...) run services (`Get-Service '*Huawei*'`); hand-deleting `C:\Program Files\Huawei` breaks hotkeys/audio/OSD/battery management. Only path: their uninstallers, app by app.

## 16. UWP / Store apps are not folders

`WindowsApps`, `SystemApps`, `%LOCALAPPDATA%\Packages` back the Start menu, Search, Store, Security Center. Hand-deleting bricks shell features. Removal only via Settings or `Get-AppxPackage | Remove-AppxPackage` for a specific app; per-app data via the app's own storage settings.

## 17. "cache" in the name is not proof

Most `*cache*` dirs are green, but consequence decides the tier: Outlook OST is a mailbox cache (delete = full resync, offline mail loss); Steam `shadercache`/`depotcache` regenerate but cause re-downloads/stutter; JetBrains `system` index regenerates at the cost of long re-indexing. State the rebuild cost, then let size decide priority.

## 18. Recycle Bin mechanics

- `Remove-Item` bypasses the bin — space frees immediately, nothing is recoverable. Say so before running.
- Emptying: `Clear-RecycleBin -Force -ErrorAction SilentlyContinue` (errors when already empty are normal). Measure `C:\$Recycle.Bin` size first so the report can credit it.

## 19. robocopy semantics

- Exit codes 0–7 = success family; >= 8 = real failure. A plain nonzero check misclassifies successful copies.
- Migration flags: `/E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /XJ /MT:8`. `/COPYALL` needs SeBackupPrivilege — elevated only, and only when ACLs must survive.
- After copy, verify file count + total bytes BEFORE deleting the source. Keep the source until verification passes.

## 20. Moving user folders: registry, not Move-Item

Bare `Move-Item` on Desktop/Documents/Downloads leaves every app pointing at the old path. Proper: known-folder redirection (Explorer Properties -> Location tab, or `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders`) then restart Explorer, then verify `[Environment]::GetFolderPath('MyDocuments')`. If OneDrive owns the folder, see #12.

## 21. Temp deletion realities

Active apps hold temp files; delete with `-ErrorAction SilentlyContinue` and accept partial. Never touch another logged-in user's Temp. `C:\Windows\Temp` needs elevation.

## 22. Update rollback windows

`Windows.old`, `$WINDOWS.~BT`, `$WinREAgent`: deleting kills OS rollback (typically a 10-day window after upgrade). Check folder dates; if within the window, get explicit consent. Prefer Disk Cleanup's "Previous Windows installation(s)" category.

## 23. Migration preflight

Before any move to D:: check `(Get-PSDrive D).Free` > source size × 1.1; confirm D: is an internal fixed disk (not removable/network) for junction targets; note BitLocker parity (moving from encrypted C: to unencrypted D: changes data-at-rest exposure).

## 24. Measure honestly, report honestly

- Capture `(Get-PSDrive C).Free` before and after every phase; per-item freed = size measured immediately before delete.
- Freed space may differ from estimates (hardlinks, compression, in-use files). Report actuals, list failures with the exact error, never fabricate a success.
- One cleanup session at a time — two agents deleting concurrently produce corrupt logs and races.
