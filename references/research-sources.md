# Research Sources

Distilled official guidance used by this skill. Prefer these sources when explaining risk to users.

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

## Additional Practical Knowledge

- App folders under `Program Files` should be removed through uninstallers.
- Package-manager caches are generally rebuildable, but package-manager stores or environments may not be disposable.
- WSL/Docker/game libraries should be moved with official export/import or app settings.
- Junctions and symlinks are advanced fallback tools, not the first option.
