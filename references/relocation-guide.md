# Relocation Guide: Moving Data from C: to D: Safely

Priority order for ANY relocation: **app-native setting > official export/import > known-folder redirection > robocopy + junction (last resort)**. A junction is invisible to most apps but breaks OneDrive sync, some updaters, and Store apps — use it only when nothing official exists, and record an undo path.

Preflight for every move (see pitfalls.md #23): D: free space > source × 1.1; D: is a fixed internal disk; source not OneDrive-managed; owning app closed.

## 1. User known folders (Desktop / Documents / Downloads / Pictures / Videos / Music)

Best method — Explorer GUI: right-click folder -> 属性 -> 位置 (Properties -> Location) -> Move to `D:\Users\<name>\<folder>` -> let Windows migrate files. Windows updates the registry and most apps follow.

Scripted equivalent (per folder, then restart Explorer):
```powershell
# Example: Downloads. GUID key {374DE290-123F-4565-9164-39C4925E467B} = Downloads
$dest = 'D:\Users\' + $env:USERNAME + '\Downloads'
New-Item -ItemType Directory -Path $dest -Force | Out-Null
robocopy "$env:USERPROFILE\Downloads" $dest /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /XJ /MT:8
Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' `
  -Name '{374DE290-123F-4565-9164-39C4925E467B}' -Value $dest
Stop-Process -Name explorer -Force   # Explorer restarts itself
```
Registry value names: Desktop=`Desktop`, Documents=`Personal`, Pictures=`My Pictures`, Music=`My Music`, Videos=`My Video`, Downloads=GUID above. Verify after: `[Environment]::GetFolderPath('MyDocuments')`. Delete the C: copy only after verification. **If OneDrive syncs the folder, do it through OneDrive settings instead** (pitfalls.md #12).

Moving Documents also carries WeChat 4.0 data (`xwechat_files`) — often the single biggest win on Chinese systems.

## 2. WeChat / QQ / DingTalk / WeCom / WPS (China apps)

| App | Native move | Notes |
|---|---|---|
| 微信 WeChat >= 4.0 | none (setting removed) | Data in `Documents\xwechat_files`. First run in-app 设置->账号与存储->存储管理->清理历史版本冗余数据 (dedupe legacy `WeChat Files`); then move the Documents known folder (#1). Never delete chat data. |
| 微信 WeChat 3.x | 设置->文件管理->更改 | App migrates `WeChat Files` itself. |
| QQ / QQNT | 设置->存储管理->更改目录 | App migrates. |
| 钉钉 DingTalk | 设置->文件->文件保存位置 | |
| 企业微信 WeCom | 设置->文件与录制->更改 | |
| WPS | 设置中心->备份中心->本地备份位置 | Cloud cache: WPS 设置->存储空间清理. |
| 百度网盘/夸克/迅雷 | 设置->传输->下载位置 | Also clear their cache dirs in-app. |

## 3. Browsers

Cache location is not worth junctioning (small, regenerates). Move the **download directory** in browser settings. Chrome/Edge profile folders must NOT be hand-moved; if a profile is huge, check PWA/`File System` data and clean via browser settings.

## 4. Game libraries

- Steam: 设置->存储 (Storage Manager) -> add `D:\SteamLibrary` -> select games -> 移动. Official, safe.
- Epic: move the install dir, then reinstall to the same D: path — launcher detects existing files and verifies. Newer launchers have a Move option.
- Xbox/Store games: 设置->应用->已安装的应用 -> 移动 (works for movable UWP packages).
- Riot/Blizzard/miHoYo launchers: each has an install-path setting; use repair after moving.

## 5. Dev tools and caches (config, not junction)

```powershell
npm config set cache D:\dev-cache\npm --global
pnpm config set store-dir D:\dev-cache\pnpm-store --global
yarn config set cache-folder D:\dev-cache\yarn
pip config set global.cache-dir D:\dev-cache\pip
setx UV_CACHE_DIR D:\dev-cache\uv
setx NUGET_PACKAGES D:\dev-cache\nuget
setx GRADLE_USER_HOME D:\dev-cache\gradle
setx CARGO_HOME D:\dev-cache\cargo        # move existing dir first; PATH note: cargo\bin
setx GOPATH D:\dev-cache\go
setx GOMODCACHE D:\dev-cache\go\pkg\mod
# Maven: <localRepository>D:\dev-cache\m2</localRepository> in %USERPROFILE%\.m2\settings.xml
# conda: conda config --add pkgs_dirs D:\dev-cache\conda-pkgs ; envs via --prefix or envs_dirs
# HuggingFace: setx HF_HOME D:\dev-cache\huggingface
# Ollama models: setx OLLAMA_MODELS D:\dev-cache\ollama
```
Move the existing cache content first (robocopy), then set the config, then delete the old dir. `setx` affects new shells only. Optionally format D: space as a Dev Drive (ReFS, faster for dev workloads) — see Microsoft "Set up a Dev Drive".

## 6. WSL2 distros

```powershell
wsl --shutdown
# Newer WSL (2.5+): official move
wsl --manage <DistroName> --move D:\WSL\<DistroName>
# Older WSL: export/import
wsl --export <DistroName> D:\WSL\<DistroName>.tar
wsl --unregister <DistroName>            # DESTROYS the C: copy - only after export verified
wsl --import <DistroName> D:\WSL\<DistroName> D:\WSL\<DistroName>.tar
# default user may reset after import: <distro> config --default-user <name>
```
Shrink a bloated ext4.vhdx without moving: `wsl --shutdown` then `Optimize-VHD -Path <path>\ext4.vhdx -Mode Full` (admin, Hyper-V module; fallback: diskpart `compact vdisk`).

## 7. Docker Desktop

WSL2 backend: Docker Desktop 设置 -> Resources -> Advanced -> Disk image location -> `D:\DockerDesktop` (it moves `docker_data.vhdx` itself). First reclaim inside: `docker system prune -a` + `docker builder prune`, then the disk-image move or Optimize-VHD. Never hand-move `%LOCALAPPDATA%\Docker`.

## 8. Cloud drives

- OneDrive: 设置->账户->取消链接 then re-link choosing a D: root; enable Files On-Demand for big folders (`attrib +U -P /s` frees local copies).
- iCloud/Dropbox/坚果云: each has a folder-location setting; use it, never junction.

## 9. System files

| Item | How to move/shrink | Caveat |
|---|---|---|
| pagefile.sys | 系统属性->高级->性能设置->高级->虚拟内存: set D: system-managed, C: none or 1–2GB minimum; reboot | Keep a small C: pagefile so kernel crash dumps still work. |
| hiberfil.sys | Not movable. `powercfg /h off` deletes it (= RAM × ~0.4–1) | Disables hibernate AND fast startup. `powercfg /h /type reduced` keeps fast startup at half size. |
| swapfile.sys | Follows pagefile settings | Small; usually ignore. |
| System Restore | 系统保护 -> 配置 -> reduce max usage; or `vssadmin resize shadowstorage /for=C: /on=C: /maxsize=5GB` (admin) | Keeps newest points that fit. |
| Search index | 索引选项->高级->索引位置 -> D: | Windows.edb can reach many GB. |
| iTunes/Apple iOS backups | `%APPDATA%\Apple Computer\MobileSync\Backup` -> move + junction (classic, works) | Close iTunes/Apple Devices first. |
| Outlook OST | Mail control panel -> data file settings, or new profile with D: path | Do not junction a live OST. |

## 10. CompactOS and NTFS compression (free space without moving)

```powershell
compact /compactos:query          # admin: is the OS compressed?
compact /compactos:always         # compress system binaries, typically frees 2-4 GB, safe on modern CPUs
compact /c /s /exe:LZX <dir>      # aggressive per-dir compression for rarely-used, non-hot data
```
Good compact targets: node_modules graveyards, SDKs, docs. Never compress databases or VM disks in active use (performance).

## 11. Installed apps

Movable without reinstall: Store/UWP apps via 设置->应用->移动. Win32 apps: uninstall -> reinstall picking a D: path (only for apps the user still wants; confirm licence/login re-setup cost). Dragging `Program Files\<app>` to D: never works (registry/service paths break) — see decision-model.md RED tier.
