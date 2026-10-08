"""Windows Known Folder Redirection via Shell32 and Registry APIs."""

from __future__ import annotations

import os
import sys
import subprocess
import winreg
from pathlib import Path
from typing import Optional, Dict

KNOWN_FOLDER_GUIDS = {
    "Documents": "{F42EE2D3-909F-4907-8871-4C22FC0BF756}",
    "Downloads": "{374DE290-123F-4565-9164-39C4925E467B}",
    "Desktop": "{B4BFCC3A-DB2C-424C-B029-7FE99A87C641}",
    "Pictures": "{33E28130-4E1E-4676-835A-98395C3BC3BB}",
    "Videos": "{18989B1D-99B5-455B-841C-AB7C74E4DDFC}",
    "Music": "{4BD8D570-5026-4CD8-8756-9957236F4476}",
}

USER_SHELL_FOLDERS_KEY = r"Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
SHELL_FOLDERS_KEY = r"Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders"


def get_current_known_folder_paths() -> Dict[str, str]:
    """Read current known folder paths from user shell folders registry."""
    results = {}
    if sys.platform != "win32":
        return results

    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, USER_SHELL_FOLDERS_KEY) as key:
            try:
                results["Documents"] = os.path.expandvars(winreg.QueryValueEx(key, "Personal")[0])
            except OSError:
                pass
            try:
                results["Downloads"] = os.path.expandvars(
                    winreg.QueryValueEx(key, "{374DE290-123F-4565-9164-39C4925E467B}")[0]
                )
            except OSError:
                pass
            try:
                results["Desktop"] = os.path.expandvars(winreg.QueryValueEx(key, "Desktop")[0])
            except OSError:
                pass
    except OSError:
        pass
    return results


def redirect_known_folder(name: str, new_path: str | Path, restart_explorer: bool = False) -> None:
    """
    Safely redirect a Windows Known Folder (Documents, Downloads) to a new destination.
    Updates registry and broadcasts system setting changes.
    """
    if sys.platform != "win32":
        raise OSError("Known folder redirection is only supported on Windows.")

    target = Path(new_path).resolve()
    target.mkdir(parents=True, exist_ok=True)
    target_str = str(target)

    # 1. Update User Shell Folders (authoritative)
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, USER_SHELL_FOLDERS_KEY, 0, winreg.KEY_SET_VALUE) as key:
        if name.lower() == "documents":
            winreg.SetValueEx(key, "Personal", 0, winreg.REG_SZ, target_str)
            winreg.SetValueEx(key, KNOWN_FOLDER_GUIDS["Documents"], 0, winreg.REG_SZ, target_str)
        elif name.lower() == "downloads":
            winreg.SetValueEx(key, KNOWN_FOLDER_GUIDS["Downloads"], 0, winreg.REG_SZ, target_str)
            winreg.SetValueEx(key, "{7D83EE9B-2244-4E70-B1F5-5393042AF1E4}", 0, winreg.REG_SZ, target_str)
        elif name.lower() == "desktop":
            winreg.SetValueEx(key, "Desktop", 0, winreg.REG_SZ, target_str)
            winreg.SetValueEx(key, KNOWN_FOLDER_GUIDS["Desktop"], 0, winreg.REG_SZ, target_str)

    # 2. Update legacy Shell Folders for compatibility with older apps
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, SHELL_FOLDERS_KEY, 0, winreg.KEY_SET_VALUE) as key:
            if name.lower() == "documents":
                winreg.SetValueEx(key, "Personal", 0, winreg.REG_SZ, target_str)
            elif name.lower() == "downloads":
                winreg.SetValueEx(key, KNOWN_FOLDER_GUIDS["Downloads"], 0, winreg.REG_SZ, target_str)
    except OSError:
        pass

    # 3. Broadcast shell notification
    try:
        import ctypes
        from ctypes import wintypes
        HWND_BROADCAST = 0xFFFF
        WM_SETTINGCHANGE = 0x001A
        SMTO_ABORTIFHUNG = 0x0002
        res = wintypes.DWORD()
        ctypes.windll.user32.SendMessageTimeoutW(
            HWND_BROADCAST, WM_SETTINGCHANGE, 0, "Environment", SMTO_ABORTIFHUNG, 3000, ctypes.byref(res)
        )
    except Exception:
        pass

    if restart_explorer:
        subprocess.run(["taskkill", "/f", "/im", "explorer.exe"], capture_output=True, check=False)
        subprocess.Popen(["explorer.exe"])
