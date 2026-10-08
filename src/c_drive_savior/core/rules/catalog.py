"""Declarative 2026 Knowledge Graph Catalog for Windows & Developer Asset Classification."""

from __future__ import annotations

import os
from pathlib import Path
from typing import List, Dict, Any, Optional, Tuple
from c_drive_savior.domain.models import Tier


class CatalogItem:
    def __init__(
        self,
        id: str,
        label: str,
        tier: Tier,
        category: str,
        path_pattern: str,
        owning_processes: Optional[List[str]] = None,
        note: str = "",
        can_junction: bool = False,
    ):
        self.id = id
        self.label = label
        self.tier = tier
        self.category = category
        self.path_pattern = path_pattern
        self.owning_processes = owning_processes or []
        self.note = note
        self.can_junction = can_junction

    def resolve_paths(self) -> List[Path]:
        """Resolve environment variables and expand pattern."""
        expanded = os.path.expandvars(self.path_pattern)
        if "*" in expanded:
            parent = Path(expanded.split("*")[0])
            suffix = expanded.split("*")[1].lstrip("\\/")
            if parent.exists():
                return [p / suffix for p in parent.iterdir() if (p / suffix).exists()]
            return []
        p = Path(expanded)
        return [p] if p.exists() else []


# 2026 Catalog Definitions
CATALOG_ITEMS: List[CatalogItem] = [
    # 1. Dev Caches (GREEN - safe to prune, rebuildable)
    CatalogItem("uv-cache", "Python uv Cache", Tier.GREEN, "developer", r"%LOCALAPPDATA%\uv", note="Rebuilds automatically"),
    CatalogItem("pip-cache", "Python pip Cache", Tier.GREEN, "developer", r"%LOCALAPPDATA%\pip\cache", note="Re-downloads on install"),
    CatalogItem("npm-cache", "Node npm Cache", Tier.GREEN, "developer", r"%LOCALAPPDATA%\npm-cache", ["node"], "Rebuilds on install"),
    CatalogItem("pnpm-cache", "Node pnpm Cache", Tier.GREEN, "developer", r"%LOCALAPPDATA%\pnpm-cache", ["node"]),
    CatalogItem("playwright", "Playwright Browsers", Tier.GREEN, "developer", r"%LOCALAPPDATA%\ms-playwright", ["chrome", "msedge"]),
    CatalogItem("crashdumps", "App Crash Dumps", Tier.GREEN, "system", r"%LOCALAPPDATA%\CrashDumps", note="Historical dump logs"),
    CatalogItem("dxcache", "DirectX Shader Cache", Tier.GREEN, "system", r"%LOCALAPPDATA%\D3DSCache"),
    CatalogItem("temp-user", "User Temp Directory", Tier.GREEN, "system", r"%LOCALAPPDATA%\Temp"),

    # 2. Browser Caches (GREEN)
    CatalogItem("chrome-cache", "Chrome Browser Cache", Tier.GREEN, "browser", r"%LOCALAPPDATA%\Google\Chrome\User Data\*\Cache", ["chrome"]),
    CatalogItem("chrome-code-cache", "Chrome Code Cache", Tier.GREEN, "browser", r"%LOCALAPPDATA%\Google\Chrome\User Data\*\Code Cache", ["chrome"]),
    CatalogItem("edge-cache", "Edge Browser Cache", Tier.GREEN, "browser", r"%LOCALAPPDATA%\Microsoft\Edge\User Data\Default\Cache", ["msedge"]),

    # 3. AI Runtimes & Workspaces (MOVE / YELLOW - ideal for NTFS Junction)
    CatalogItem("codex-data", "Codex AI Assistant Data", Tier.MOVE, "ai", r"%USERPROFILE%\.codex", ["codex", "codex-code-mode-host"], "Relocate via Junction", can_junction=True),
    CatalogItem("workbuddy-data", "WorkBuddy AI Workspace", Tier.MOVE, "ai", r"%USERPROFILE%\.workbuddy-ai", ["workbuddy"], "Relocate via Junction", can_junction=True),
    CatalogItem("codex-runtimes", "Codex Runtimes Cache", Tier.MOVE, "ai", r"%USERPROFILE%\.cache\codex-runtimes", ["codex"], "Relocate via Junction", can_junction=True),
    CatalogItem("claude-data", "Claude Desktop Data", Tier.MOVE, "ai", r"%USERPROFILE%\.claude", ["claude"], "Relocate via Junction", can_junction=True),
    CatalogItem("openai-data", "ChatGPT Desktop Data", Tier.MOVE, "ai", r"%LOCALAPPDATA%\OpenAI", ["ChatGPT"], "Relocate via Junction", can_junction=True),
    CatalogItem("ollama-models", "Ollama LLM Weights", Tier.MOVE, "ai", r"%USERPROFILE%\.ollama", ["ollama_app"], "Relocate via Junction", can_junction=True),
    CatalogItem("huggingface-cache", "HuggingFace Hub Weights", Tier.MOVE, "ai", r"%USERPROFILE%\.cache\huggingface", can_junction=True),
    CatalogItem("uv-roaming", "uv Global Environment", Tier.MOVE, "developer", r"%APPDATA%\uv", can_junction=True),

    # 4. User Known Folders (MOVE - Known Folder Redirection)
    CatalogItem("documents", "User Documents", Tier.MOVE, "user", r"%USERPROFILE%\Documents", note="Migrate via Shell32 Redirection"),
    CatalogItem("downloads", "User Downloads", Tier.MOVE, "user", r"%USERPROFILE%\Downloads", note="Migrate via Shell32 Redirection"),

    # 5. Protected System Areas (RED - never hand delete)
    CatalogItem("winsxs", "Windows Component Store", Tier.RED, "system", r"%SystemRoot%\WinSxS", note="WinSxS hardlinks; use DISM only"),
    CatalogItem("system32", "Windows System32", Tier.RED, "system", r"%SystemRoot%\System32", note="Core OS binaries"),
    CatalogItem("package-cache", "Installer Package Cache", Tier.RED, "installer", r"%ProgramData%\Package Cache", note="MSI repair cache"),
]


def classify_path(path: str | Path) -> Tuple[Tier, str, Optional[CatalogItem]]:
    """Determine the tier, reason, and catalog match for an arbitrary filesystem path."""
    p_str = str(Path(path).resolve()).lower()

    # Red zone prefixes
    for red in [r"c:\windows", r"c:\program files", r"c:\program files (x86)"]:
        if p_str == red or p_str.startswith(red + "\\"):
            return Tier.RED, "System or installed program binaries. Never hand delete.", None

    for item in CATALOG_ITEMS:
        for resolved in item.resolve_paths():
            if p_str == str(resolved).lower():
                return item.tier, item.note or item.label, item

    return Tier.YELLOW, "Custom user or application path requiring confirmation.", None


def get_rule_catalog() -> List[CatalogItem]:
    """Return all defined catalog items in knowledge graph."""
    return CATALOG_ITEMS


def get_rule_for_path(path: str | Path) -> Optional[CatalogItem]:
    """Retrieve catalog item if path matches a known rule."""
    _, _, item = classify_path(path)
    return item

