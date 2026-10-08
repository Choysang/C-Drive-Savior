"""Unified Command Line Interface for C-Drive-Savior."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from c_drive_savior.core.engine.scanner import FastScanner
from c_drive_savior.core.engine.relocator import TransactionalRelocator
from c_drive_savior.core.engine.cleaner import PrecisionCleaner
from c_drive_savior.core.native.known_folders import redirect_known_folder, get_current_known_folder_paths
from c_drive_savior.domain.cognitive_guard import CognitiveGuard


def main():
    parser = argparse.ArgumentParser(
        prog="savior",
        description="C-Drive-Savior 2026+: Agent-Native Windows Storage Engine",
    )
    subparsers = parser.add_subparsers(dest="command")

    # scan
    scan_parser = subparsers.add_parser("scan", help="Run full disk diagnosis")
    scan_parser.add_argument("--root", default="C:\\", help="Root drive to scan")
    scan_parser.add_argument("--json", action="store_true", help="Output machine-readable JSON")

    # clean
    clean_parser = subparsers.add_parser("clean", help="Clean rebuildable cache")
    clean_parser.add_argument("path", help="Target cache directory to prune")

    # relocate
    reloc_parser = subparsers.add_parser("relocate", help="Atomically move a directory to D: with NTFS Junction")
    reloc_parser.add_argument("source", help="Source folder on C:")
    reloc_parser.add_argument("--dest", help="Destination folder on D:")

    # redirect
    redir_parser = subparsers.add_parser("redirect", help="Redirect Windows Known Folder (Documents/Downloads)")
    redir_parser.add_argument("folder", choices=["Documents", "Downloads", "Desktop"])
    redir_parser.add_argument("new_path", help="New target path on D:")

    # serve
    serve_parser = subparsers.add_parser("serve", help="Launch Web Console & REST API Server")
    serve_parser.add_argument("--port", type=int, default=8999, help="Port to bind (default: 8999)")

    # mcp
    subparsers.add_parser("mcp", help="Run Model Context Protocol (MCP) Stdio Server for Agents")

    args = parser.parse_args()

    if args.command == "scan":
        scanner = FastScanner()
        overview = scanner.run_full_diagnosis(args.root)
        if args.json:
            print(overview.model_dump_json(indent=2))
        else:
            summary = CognitiveGuard.summarize_scan(overview)
            print("\n=======================================================")
            print("          C-DRIVE-SAVIOR 2026+ DIAGNOSTIC REPORT       ")
            print("=======================================================")
            print(f"Session: {summary['session_id']}")
            print(f"C: Capacity: {summary['c_drive']['total_gb']} GB")
            print(f"C: Free Space: {summary['c_drive']['free_gb']} GB (Used: {summary['c_drive']['used_gb']} GB)")
            if summary["d_drive_free_gb"]:
                print(f"D: Free Space: {summary['d_drive_free_gb']} GB")
            print(f"Potential Reclaimable: {summary['potential_reclaimable_gb']} GB\n")

            print("--- Top Space Consumers ---")
            for c in summary["top_consumers"]:
                print(f"[{c['tier']}] {c['size_gb']:>6.2f} GB | {c['label']:<20} | {c['path']}")

            print(f"\nRecommended Cleanup Candidates: {summary['recommended_cleanups_count']}")
            print(f"Recommended Move Candidates: {summary['recommended_moves_count']}\n")

    elif args.command == "clean":
        res = PrecisionCleaner.clean_target(args.path, is_temp="temp" in args.path.lower())
        print(f"Status: {res.status} | {res.message}")

    elif args.command == "relocate":
        relocator = TransactionalRelocator()
        res = relocator.execute_relocation(args.source, args.dest)
        print(f"Status: {res.status} | {res.message}")

    elif args.command == "redirect":
        redirect_known_folder(args.folder, args.new_path)
        print(f"Successfully redirected {args.folder} to {args.new_path}")

    elif args.command == "serve":
        from c_drive_savior.server.api_server import start_server
        print(f"Launching C-Drive-Savior Web Console on http://127.0.0.1:{args.port} ...")
        start_server(port=args.port)

    elif args.command == "mcp":
        from c_drive_savior.server.mcp_server import run_stdio_mcp_server
        run_stdio_mcp_server()

    else:
        parser.print_help()


if __name__ == "__main__":
    main()
