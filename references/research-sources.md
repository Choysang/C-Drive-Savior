# Research Sources

Distilled official guidance used by this skill. Prefer these sources when explaining risk to users.

## Evidence policy

Microsoft Learn/Support and application-native documentation define supported system, uninstall, known-folder, and storage operations. Community sources may identify a product-specific workflow or failure mode, but they do not override the safety gates in the scripts. Performance statements require a saved local benchmark from `benchmarks/run-scanners.ps1`; reclaim estimates require the current session's raw bytes. When product behavior or Windows servicing guidance may have changed, verify the current official page before advising the user.

## Microsoft: Free Up Drive Space In Windows

Source: https://support.microsoft.com/en-us/windows/experience/storage-filemanagement/free-up-drive-space-in-windows

Relevant guidance:

- Use Windows storage settings and Disk Cleanup for system cleanup.
- Delete temporary files through Windows tools where possible.
- OneDrive Files On-Demand can reduce local disk use for cloud-backed files.
- Removing a previous Windows version removes rollback ability.

Skill implication:

- Prefer built-in Windows cleanup tools for Windows-managed content.
- Explain rollback loss before deleting previous update/version files.

## Microsoft: Manage Drive Space With Storage Sense

Source: https://support.microsoft.com/en-us/windows/experience/storage-filemanagement/manage-drive-space-with-storage-sense

Relevant guidance:

- Storage Sense removes temporary files and recycle bin contents automatically.
- It can be configured rather than hand-deleting every Windows-managed temp item.

Skill implication:

- Recommend Storage Sense for ongoing maintenance after manual cleanup.

## Microsoft Learn: Clean Up The WinSxS Folder

Source: https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/clean-up-the-winsxs-folder?view=windows-11

Relevant guidance:

- Use Task Scheduler or DISM component cleanup.
- `Dism.exe /online /Cleanup-Image /StartComponentCleanup` is the supported cleanup path.
- `/ResetBase` removes superseded component versions and prevents uninstalling existing service packs/updates.

Skill implication:

- Never hand-delete `C:\Windows\WinSxS`.
- Use DISM only when component store health is normal.
- Warn clearly before `/ResetBase`.

## Microsoft Learn: Restore Missing Windows Installer Cache Files

Source: https://learn.microsoft.com/en-us/troubleshoot/windows-client/application-management/missing-windows-installer-cache

Relevant guidance:

- Missing installer cache files can break repair, update, and uninstall operations.
- Recovery may require original vendor media/installer or reinstalling the application.

Skill implication:

- Treat `C:\Windows\Installer` as protected.
- Treat `C:\ProgramData\Package Cache` as yellow-risk, not green.

## Microsoft Learn: Redirect And Move Windows Known Folders

Source: https://learn.microsoft.com/en-us/sharepoint/redirect-known-folders

Relevant guidance:

- Known folders such as Desktop, Documents, and Pictures can be redirected/moved through supported mechanisms.

Skill implication:

- User files can be moved, but use supported folder-location settings or cloud-client settings where applicable.

## Microsoft Learn: Set Up A Dev Drive

Source: https://learn.microsoft.com/en-us/windows/dev-drive/

- A ReFS Dev Drive (VHDX or partition) is the recommended home for package caches (npm/NuGet/pip/Maven/Gradle) moved off C:.
- Each package manager relocates via its own env var / config (see relocation-guide.md #5).

## Community: WSL2 / Docker Desktop Relocation And Compaction

Sources: https://dev.to/raafe_asad/free-up-your-c-drive-move-wsl2-and-docker-desktop-to-another-drive-4plc , https://github.com/dbfx/wsl-cleaner , https://github.com/dazeb/move-packages-to-dev-drive-win11

- WSL: `wsl --shutdown` then `--manage --move` (new) or export/import (old); `Optimize-VHD -Mode Full` shrinks a bloated ext4.vhdx.
- Docker Desktop moves its data via Settings -> Resources -> Disk image location; prune before moving.

## Community: Hidden Windows Files Eating C:

Sources: https://www.cairosoftware.com/en/blog/post/c-drive-full-for-no-reason-hidden-files/ , https://windowsforum.com/threads/reclaim-disk-space-by-disabling-hibernation-and-removing-hiberfil-sys-in-windows.395605/ , https://windowsforum.com/threads/free-disk-space-in-windows-11-with-disk-cleanup-and-storage-sense.385530/

- pagefile/hiberfil/swapfile, VSS restore points, Recycle Bin, and the WinSxS hardlink illusion explain most "folders don't add up" complaints — the scan panel reports them separately.

## China Apps: WeChat 4.0 Storage Change (2024-10)

Sources: https://min.news/en/tech/b173dad972abba2023d64e01d4f7023f.html and WeChat in-app storage management

- WeChat >= 4.0 moved data to `Documents\xwechat_files`, removed the custom-location setting, and can double space by keeping legacy `WeChat Files`.
- In-app "清理历史版本冗余数据" dedupes; relocation only via Documents known-folder redirection.

## Prior Art: khazix-skills storage-analyzer

Source: https://github.com/KKKKhazix/khazix-skills/tree/main/storage-analyzer

Ideas adopted (and adapted for Windows): tier list as a decision list (not an inventory), segmented disk bar by tier, report reading flow "current state -> diagnosis -> prescription -> action -> prevention", one-line insight overview, reversible-only actions for user-data tiers. Ideas NOT adopted: local web server one-click deletion (our execution goes through the agent + confirmation instead).

## Additional Practical Knowledge

- App folders under `Program Files` should be removed through uninstallers.
- Package-manager caches are generally rebuildable, but package-manager stores or environments may not be disposable.
- WSL/Docker/game libraries should be moved with official export/import or app settings.
- Junctions and symlinks are advanced fallback tools, not the first option.
