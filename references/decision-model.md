# Decision Model

The practical model for Windows C: cleanup. Intentionally conservative: losing uninstall/repair ability, app state, or Windows servicing is more expensive than leaving a few GB untouched.

Core framing (from storage-analyzer, improved): the tier list is a **decision list, not an inventory**. Only items that carry a real "should I touch this?" decision get a tier. The OS itself, healthy installed apps in daily use, and scattered small files have no cleanup decision — they belong to "system & other" in the panel.

## Tier semantics

- `GREEN` — rebuildable cache/temp/log. Deletable after closing the owning app. Auto-clean candidates (Phase 2).
- `YELLOW` — needs a human decision: user data, installer/repair caches, rollback assets, or anything whose loss has a stated cost. Confirm-then-act (Phase 3).
- `RED` — do not hand-delete, ever. Official tools/uninstallers only.
- `MOVE` — user-owned data relocatable to D: without breaking apps (Phase 4, see relocation-guide.md).

## IDs and execution boundaries

Every reported directory has a path-hash `id`. Use that ID for a `MOVE` decision because migration must match one exact source row. A row may also have `action_id`; this comes only from `config/classification.json` and connects one or more measured paths to a constrained GREEN cleaner action. Use `action_id` for `-ApproveClean`.

An `action_id` is retained even when its path is below the normal size threshold or report depth, so known cache actions do not disappear from the confirmation list. It is not permission by itself: `decide.ps1` must record it in the current session, and `clean.ps1` checks each resolved target against every scanned baseline and protected path. Rows without `action_id` never become direct filesystem deletion commands.

## Hidden consumers (report separately — folder scans miss these)

| Item | How to measure | How to shrink |
|---|---|---|
| `pagefile.sys` / `swapfile.sys` | `Get-CimInstance Win32_PageFileUsage` or file size | Move to D: / cap size (relocation-guide.md #9) |
| `hiberfil.sys` | file size (hidden, root) | `powercfg /h off` or `/type reduced` — state the fast-startup trade-off |
| System Restore / VSS | `vssadmin list shadowstorage` (admin) | `vssadmin resize shadowstorage` or 系统保护 GUI |
| Recycle Bin | size of `C:\$Recycle.Bin` | `Clear-RecycleBin -Force` after confirmation |
| WinSxS true size | `Dism /Online /Cleanup-Image /AnalyzeComponentStore` (admin) | `/StartComponentCleanup` ONLY if healthy — pitfalls.md #6 gate |
| Windows Update cache | `C:\Windows\SoftwareDistribution\Download` | stop `wuauserv`+`bits` first — pitfalls.md #11 |
| Delivery Optimization | cache under `C:\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization` | `Delete-DeliveryOptimizationCache` (admin) or Disk Cleanup |
| Search index | `C:\ProgramData\Microsoft\Search\Data` (`Windows.edb`) | rebuild smaller / move index location |
| Reserved storage | `Get-WindowsReservedStorageState` | usually leave on; informational |
| Memory dumps | `C:\Windows\MEMORY.DMP`, `C:\Windows\Minidump` | delete after confirmation (debug value only) |

Panel must show `disk used − sum(visible scan)` as "unaccounted / hidden" so numbers reconcile.

## GREEN: usually safe to delete (close owning apps first)

User-level (no elevation):
- `%TEMP%` contents; `%LOCALAPPDATA%\Temp`
- `%LOCALAPPDATA%\CrashDumps`, `%LOCALAPPDATA%\D3DSCache` (DirectX shader), `%LOCALAPPDATA%\fontconfig`, `%LOCALAPPDATA%\SquirrelTemp`, thumbnail caches `%LOCALAPPDATA%\Microsoft\Windows\Explorer\thumbcache_*` (Explorer rebuilds)
- Browser caches (close browser first): Chrome/Edge `User Data\<Profile>\Cache*`, `Code Cache`, `GPUCache`, `optimization_guide_model_store`, `Service Worker\CacheStorage`; Firefox `cache2`. NEVER the whole `User Data` (logins/bookmarks — RED as a whole).
- Dev caches: `%LOCALAPPDATA%\npm-cache`, `pnpm-cache`, `pip\Cache`, `pypa`, `uv`, `Yarn`, `node-gyp`, `ms-playwright`, `puppeteer`, `go-build`, `%USERPROFILE%\.nuget\packages` (restores on build), `.gradle\caches`, `.m2\repository` (re-downloads; slow rebuild — mention), `.cargo\registry`, `%LOCALAPPDATA%\Microsoft\vscode-cpptools\ipch`, JetBrains `system\caches` (re-index cost — mention)
- App updater residue: `*-updater`, `SquirrelTemp`, old installers in Downloads (confirm if the user hoards installers)
- `docker system prune` / `docker builder prune` (commands, not folder deletion)

Admin-level:
- `C:\Windows\Temp` contents
- `C:\Windows\SoftwareDistribution\Download` (service stop/start wrap)
- `C:\Windows\Minidump`, `C:\Windows\MEMORY.DMP`
- Old `C:\Windows\Logs\CBS`/`DISM` logs; WER: `C:\ProgramData\Microsoft\Windows\WER\ReportQueue|ReportArchive`
- `C:\Windows\Prefetch` (marginal; Windows repopulates — low priority)
- Delivery Optimization cache (cmdlet above)
- Recycle Bin (`Clear-RecycleBin -Force`)
- Supported system cleanup: Storage Sense one-off (设置->系统->存储->临时文件), `cleanmgr /sageset:1` + `/sagerun:1`, `Dism /StartComponentCleanup` behind the health gate (pitfalls.md #6)
- `C:\$WINDOWS.~BT`, `C:\$WinREAgent*` — YELLOW-gated in practice: only outside the rollback window and with consent (pitfalls.md #22)

## YELLOW: needs explicit confirmation (state the concrete consequence)

- `C:\ProgramData\Package Cache` — apps keep running; repair/modify/uninstall may fail; per-entry with named app; prefer backup-to-D: over delete (pitfalls.md #7)
- `Windows.old`, `$WINDOWS.~BT`, `$WinREAgent` — kills OS rollback; check dates
- `C:\Recovery\Customizations` (OEM `USMT.ppkg`) — factory-reset customization; back up to D: first, not re-downloadable
- Chat data: `Documents\xwechat_files`, `WeChat Files`, QQ/DingTalk dirs — user data; in-app cleanup or MOVE only (pitfalls.md #13)
- Outlook `.ost` — resync cost; via Mail settings only
- Game caches: Steam `shadercache`/`depotcache` — regenerate with re-download/stutter cost
- Old restore points — keep newest; resize, don't disable
- `Downloads`, Desktop archives/ISOs/installers, project folders, datasets — user judgment; usually MOVE
- Big `%LOCALAPPDATA%`/`%APPDATA%`/`%PROGRAMDATA%` app dirs — inspect subfolders; delete caches, not account data/databases. Caution names: `Packages` (UWP state), `Microsoft`, `Google`, `OpenAI`, `Programs` (user-level installs), Steam/Riot/Netease/Tencent/LGHUB/OneDrive state dirs
- Orphan-looking manager roots (`scoop` off PATH, unused conda) — verify with the user (pitfalls.md #14)
- Hibernation off, pagefile changes — functional trade-offs; confirm

## RED: never hand-delete (official tools only)

- `C:\Windows\System32`, `SysWOW64`, `WinSxS`, `Installer`, `SystemApps`, `servicing`, `WindowsApps`, `System Volume Information`
- `C:\Program Files*` app folders while the app is installed (uninstaller only); `Common Files`; vendor suites with live services (Huawei/Lenovo/... — pitfalls.md #15)
- Whole `C:\ProgramData`, whole browser `User Data`, `%LOCALAPPDATA%\Packages` wholesale (per-app via Settings only — pitfalls.md #16)
- Active Docker/WSL VHDX, pnpm store / conda envs / package-manager roots in active use — official commands/config only
- `SoftwareDistribution\DataStore`
- Registry "cleaners": out of scope, permanently

## MOVE: relocate to D:

Full per-target playbook: **relocation-guide.md** (known folders, WeChat 4.0, QQ/钉钉/WPS, Steam/Epic, dev caches via config, WSL, Docker, OneDrive, pagefile, iTunes backups, CompactOS). Transfer pattern: preflight (D: space × 1.1) -> robocopy -> verify count+bytes -> switch path (app setting/registry/junction) -> keep source until verified -> record undo.

## Suggested execution order (maximizes freed GB per unit of risk)

1. GREEN user-level caches (browsers, dev, temp, thumbnails).
2. GREEN admin-level (Windows temp, update cache, WER, dumps, recycle bin).
3. Supported system cleanup: Storage Sense / cleanmgr; DISM StartComponentCleanup behind the health gate.
4. YELLOW confirmations in ONE numbered batch (no drip-feed questioning).
5. MOVE migrations (biggest wins usually: Documents+WeChat, Downloads, WSL/Docker, dev caches, game libraries).
6. System knobs with consent: hiberfil, pagefile, restore-point cap, CompactOS.
7. Uninstalls of unused apps (Settings/uninstaller; list candidates by size + last-used evidence).

## Historical error lessons

Moved to **pitfalls.md** (24 field-tested entries: `$` path expansion, locked files, component-store gate, Package Cache incident, elevation, robocopy semantics, hidden consumers, WeChat 4.0, ...). Read it before writing any command.

## Confirmation prompt patterns

- "删除后软件仍可运行，但以后修复/卸载可能失败，需要重新下载安装包。接受吗？"
- "这是 OEM 恢复包，日常不影响，恢复出厂可能缺内容。先备份到 D: 再删？"
- "这是用户文件/聊天记录，删除不可恢复。移动到 D:、保留，还是删除？"
- "这是安装目录，建议走卸载器。确认这个软件已经不用了吗？"
- "关闭休眠可释放 N GB，但会失去休眠和快速启动。接受吗？"
