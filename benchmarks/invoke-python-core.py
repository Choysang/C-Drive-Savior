#!/usr/bin/env python3
"""Run one scanner core against an explicit root for benchmark parity."""

from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path


def load_module(path: Path):
    spec = importlib.util.spec_from_file_location("cds_benchmark_scanner", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load scanner: {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--scanner", type=Path, required=True)
    parser.add_argument("--mode", choices=("legacy", "current"), required=True)
    parser.add_argument("--scan-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    scanner = load_module(args.scanner)
    if args.mode == "current":
        report = scanner.scan_root(args.scan_root, threshold=0, max_report_depth=8)
    else:
        rows = scanner.child_rows(args.scan_root, 0)
        errors = sum(int(row.get("errors", 0)) for row in rows)
        report = {
            "schema_version": 1,
            "scan_complete": errors == 0,
            "walk_errors": errors,
            "rows": rows,
        }

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
