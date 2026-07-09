# Decision Model

This file captures the practical model for Windows C: cleanup. It is intentionally conservative: losing uninstall/repair ability, app state, or Windows servicing is more expensive than leaving a few GB untouched.

## Risk Levels

### GREEN: Usually Safe To Delete

Delete after closing related apps. These are rebuildable or disposable:

- `%LOCALAPPDATA%\npm-cache`
- `%LOCALAPPDATA%\pnpm-cache`
- `%LOCALAPPDATA%\uv`
- `%LOCALAPPDATA%\pip`
- `%LOCALAPPDATA%\pypa`
- `%LOCALAPPDATA%\node-gyp`
- `%LOCALAPPDATA%\ms-playwright`
- `%LOCALAPPDATA%\D3DSCache`
- `%LOCALAPPDATA%\CrashDumps`
- `%LOCALAPPDATA%\SquirrelTemp`
- `%LOCALAPPDATA%\Temp`
- `%LOCALAPPDATA%\fontconfig`
- `%LOCALAPPDATA%\CEF`
- `%LOCALAPPDATA%\chrome-devtools-mcp`
- `%LOCALAPPDATA%\tauri`
- `%LOCALAPPDATA%\CMakeTools`
- App updater residue such as `obsidian-updater`, `UPDFSetup`, `WinSparkle`
- Browser caches under known cache directories
- Old Windows update temporary folders such as `C:\$WINDOWS.~BT` only when no update/repair is in progress and the user accepts losing update rollback/download files
- `C:\$WinREAgent*` backup folders only after the user accepts losing recent recovery/update rollback leftovers

Common commands:

```powershell
Remove-Item -LiteralPath "$env:LOCALAPPDATA\npm-cache" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath "$env:LOCALAPPDATA\pnpm-cache" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath "$env:LOCALAPPDATA\uv" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath "$env:LOCALAPPDATA\pip" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath "$env:LOCALAPPDATA\ms-playwright" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath "$env:LOCALAPPDATA\Temp" -Recurse -Force -ErrorAction SilentlyContinue
```

### YELLOW: Needs Explicit Confirmation

Explain the consequence before deletion/move:

- `C:\ProgramData\Package Cache`
  - Current apps usually keep running.
  - Repair/modify/uninstall may fail.
  - The user may need to redownload the original installer.
  - Prefer deleting only the biggest known packages rather than the whole folder.

- `C:\Recovery\Customizations`
  - May contain OEM provisioning/recovery packages.
  - Usually not downloadable from Microsoft.
  - Prefer backup to D: before deletion.

- `C:\Users\<user>\.git` when it is the user's home directory repo
  - Safe only if it is accidental and has no needed history.
  - Check `git -C C:\Users\<user> status`, commit count, and remotes first.

- `C:\Users\<user>\scoop`
  - Cache can be deleted.
  - Whole folder can be deleted only if Scoop apps are unused or Scoop is broken/uninstalled.

- Large app data folders under `%LOCALAPPDATA%`, `%APPDATA%`, `%PROGRAMDATA%`
  - Inspect subfolders. Delete caches, not account data or databases.

- `Downloads`, archives, videos, installers, ISO files, project folders
  - Move to D: or delete only after user confirmation.

### RED: Do Not Manually Delete

Use official cleanup/uninstall/repair tools instead:

- `C:\Windows\System32`
- `C:\Windows\SysWOW64`
- `C:\Windows\WinSxS`
- `C:\Windows\Installer`
- `C:\Windows\SystemApps`
- `C:\Windows\servicing`
- `C:\Program Files\Microsoft Office`
- `C:\Program Files (x86)\Microsoft`
- `C:\Program Files (x86)\Windows Kits`
- Visual Studio folders, unless removed through Visual Studio Installer
- Adobe/Huawei/Docker/Office app folders unless already uninstalled and only leftovers remain
- Package manager roots such as `pnpm` store, Conda envs, Scoop apps, Docker data, WSL VHDX, unless the specific environment is confirmed disposable

## D: Move Rules

Move only things whose path is user-controlled or whose application supports relocation.

Good move candidates:

- User files: Desktop, Documents, Downloads, Pictures, Videos, Music.
- Large archives, installers, ISO files, exported backups.
- Development project folders if IDE paths, scripts, and environment variables can be updated.
- Dataset/model folders that are referenced by configurable paths.
- Backups of risky delete candidates such as `C:\Recovery\Customizations\USMT.ppkg`.

Move with care:

- OneDrive/Dropbox/iCloud folders: use the app's location settings.
- Game libraries: use Steam/Epic/Xbox app move feature.
- Docker/WSL data: export/import or official data-root settings, not manual move while services run.
- Package manager stores: use official config, for example pnpm store path, npm cache path, pip cache dir, conda env location.

Do not move:

- `C:\Windows`
- `C:\Program Files`
- `C:\Program Files (x86)`
- `C:\ProgramData` wholesale
- Active AppData databases
- Windows Installer cache

Safer transfer pattern:

1. Create a destination under `D:\MovedFromC\...`.
2. Copy or move with `robocopy`.
3. Verify file count and size.
4. Update the app/user path.
5. Keep a rollback window before deleting the source.

Example for user files:

```powershell
robocopy "$env:USERPROFILE\Downloads" "D:\MovedFromC\Users\$env:USERNAME\Downloads" /E /COPY:DAT /DCOPY:DAT /R:1 /W:1
```

## Historical Error Lessons

### PowerShell `$` Expansion

Paths like `C:\$WINDOWS.~BT` and `C:\$WinREAgent...` contain `$`. In PowerShell double quotes, `$WINDOWS` is treated as a variable, producing the wrong path such as `C:\.~BT`.

Correct:

```powershell
Remove-Item -LiteralPath 'C:\$WINDOWS.~BT' -Recurse -Force
cmd /c rmdir /s /q "\\?\C:\`$WINDOWS.~BT"
```

### Locked Browser Model Files

Chrome may keep model/cache files open, such as optimization guide model files. If deletion fails:

1. Close Chrome windows.
2. Disable background Chrome processes or stop them:

```powershell
Stop-Process -Name chrome -Force -ErrorAction SilentlyContinue
```

3. Retry deleting the specific cache directory.

### Broken WinSxS / DISM / SFC

If these fail with "system cannot find the file specified" and `C:\Windows\WinSxS\Catalogs` is missing:

- Stop Windows component cleanup.
- Do not create or delete WinSxS folders manually.
- Recommend Windows Update repair, DISM with a matching source image, or in-place repair.

### Package Cache Error Pattern

If a program tries to modify/repair and reports a missing file in `C:\ProgramData\Package Cache`, the cache was deleted or missing. The fix is usually to redownload the same installer/version or reinstall the application.

Use this as a warning before deleting package cache entries.

## Suggested Cleaning Order

1. `%LOCALAPPDATA%` rebuildable caches.
2. Browser caches and model caches after closing browsers.
3. Package-manager caches: npm/pnpm/pip/uv/playwright.
4. Old update temporary folders: `$WINDOWS.~BT`, `$WinREAgent*`, only after confirmation.
5. User downloads/installers/media, preferably move to D:.
6. App-specific cleanup through settings/uninstallers.
7. Windows supported cleanup: Storage Sense, Disk Cleanup, DISM StartComponentCleanup when component store is healthy.

## Confirmation Prompts

Use short concrete prompts:

- "这个删除后软件仍可运行，但修复/卸载可能要重新下载安装包，可以接受吗？"
- "这个是 OEM 恢复包，日常使用不影响，但恢复出厂可能缺东西。要先备份到 D: 吗？"
- "这是用户文件/项目，不建议我判断删除。要移动到 D:、保留，还是删除？"
- "这是安装目录。建议卸载，不建议手删。你确定这个软件已经不用了吗？"
