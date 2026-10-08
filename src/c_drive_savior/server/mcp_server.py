"""FastMCP 2026 Tool Server for Autonomous Agent System Control."""

from __future__ import annotations

import json
import sys
from typing import Any, Dict, List, Optional

from c_drive_savior.core.engine.scanner import FastScanner
from c_drive_savior.core.engine.relocator import TransactionalRelocator
from c_drive_savior.core.engine.cleaner import PrecisionCleaner
from c_drive_savior.core.native.known_folders import redirect_known_folder, get_current_known_folder_paths
from c_drive_savior.domain.cognitive_guard import CognitiveGuard

# Global Singletons
scanner = FastScanner()
relocator = TransactionalRelocator()
last_scan = None


def handle_tool_call(tool_name: str, arguments: Dict[str, Any]) -> Dict[str, Any]:
    global last_scan

    if tool_name == "get_c_drive_overview":
        last_scan = scanner.run_full_diagnosis()
        return CognitiveGuard.summarize_scan(last_scan)

    elif tool_name == "list_cleanup_candidates":
        if not last_scan:
            last_scan = scanner.run_full_diagnosis()
        cursor = arguments.get("cursor", 0)
        return CognitiveGuard.paginate_nodes(last_scan.cleanup_candidates, cursor=cursor)

    elif tool_name == "list_migration_candidates":
        if not last_scan:
            last_scan = scanner.run_full_diagnosis()
        cursor = arguments.get("cursor", 0)
        return CognitiveGuard.paginate_nodes(last_scan.migration_candidates, cursor=cursor)

    elif tool_name == "plan_relocation":
        source = arguments.get("source")
        dest = arguments.get("dest")
        return relocator.plan_relocation(source, dest)

    elif tool_name == "execute_relocation":
        source = arguments.get("source")
        dest = arguments.get("dest")
        procs = arguments.get("owning_processes", [])
        res = relocator.execute_relocation(source, dest, procs)
        return res.model_dump()

    elif tool_name == "clean_cache":
        target = arguments.get("target_path")
        procs = arguments.get("owning_processes", [])
        is_temp = "temp" in target.lower()
        res = PrecisionCleaner.clean_target(target, procs, is_temp)
        return res.model_dump()

    elif tool_name == "redirect_known_folder":
        folder = arguments.get("folder_name")  # "Documents" or "Downloads"
        new_path = arguments.get("new_path")
        redirect_known_folder(folder, new_path)
        return {"status": "success", "folder": folder, "new_path": new_path}

    elif tool_name == "get_known_folders":
        return get_current_known_folder_paths()

    raise ValueError(f"Unknown tool: {tool_name}")


def run_stdio_mcp_server() -> None:
    """Run an autonomous Model Context Protocol JSON-RPC 2.0 loop on stdin/stdout."""
    sys.stderr.write("C-Drive-Savior FastMCP Server 2026 initialized.\n")
    sys.stderr.flush()

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
            req_id = req.get("id")
            method = req.get("method")
            params = req.get("params", {})

            if method == "tools/list":
                resp = {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {
                        "tools": [
                            {"name": "get_c_drive_overview", "description": "Get high-signal compact summary of C drive space & top consumers"},
                            {"name": "list_cleanup_candidates", "description": "Paginated list of GREEN safe cache cleanups"},
                            {"name": "list_migration_candidates", "description": "Paginated list of MOVE candidate assets"},
                            {"name": "plan_relocation", "description": "Dry-run evaluate moving a directory to D: and creating Junction"},
                            {"name": "execute_relocation", "description": "Atomically relocate a directory to D: with NTFS Junction and rollback guard"},
                            {"name": "clean_cache", "description": "Safely prune a rebuildable cache directory"},
                            {"name": "redirect_known_folder", "description": "Redirect Windows Documents or Downloads to a secondary drive"},
                            {"name": "get_known_folders", "description": "Get current Windows Known Folder destinations"},
                        ]
                    },
                }
            elif method == "tools/call":
                tool_name = params.get("name")
                args = params.get("arguments", {})
                result = handle_tool_call(tool_name, args)
                resp = {"jsonrpc": "2.0", "id": req_id, "result": result}
            else:
                resp = {"jsonrpc": "2.0", "id": req_id, "error": {"code": -32601, "message": "Method not found"}}

            sys.stdout.write(json.dumps(resp) + "\n")
            sys.stdout.flush()
        except Exception as exc:
            err_resp = {"jsonrpc": "2.0", "id": None, "error": {"code": -32000, "message": str(exc)}}
            sys.stdout.write(json.dumps(err_resp) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    run_stdio_mcp_server()
