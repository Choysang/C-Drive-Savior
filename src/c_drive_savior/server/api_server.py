"""FastAPI Asynchronous Backend & Embedded Web Console Host."""

from __future__ import annotations

import os
from pathlib import Path
from typing import Dict, Any, Optional, List
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, HTMLResponse
from pydantic import BaseModel

from c_drive_savior.core.engine.scanner import FastScanner
from c_drive_savior.core.engine.relocator import TransactionalRelocator
from c_drive_savior.core.engine.cleaner import PrecisionCleaner
from c_drive_savior.core.native.known_folders import redirect_known_folder, get_current_known_folder_paths
from c_drive_savior.domain.cognitive_guard import CognitiveGuard

app = FastAPI(
    title="C-Drive-Savior API",
    version="2.0.0",
    description="Agent-Native System Storage Engine & Real-time Console",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

scanner = FastScanner()
relocator = TransactionalRelocator()
current_scan = None

CONSOLE_DIR = Path(__file__).resolve().parent.parent / "console"


class CleanRequest(BaseModel):
    target_path: str
    owning_processes: List[str] = []


class RelocateRequest(BaseModel):
    source_path: str
    target_path: Optional[str] = None
    owning_processes: List[str] = []


class RedirectRequest(BaseModel):
    folder_name: str
    new_path: str


def format_overview_response(overview: Any) -> Dict[str, Any]:
    c_drive = next((d for d in overview.drives if d.letter.upper().startswith("C")), None)
    d_drive = next((d for d in overview.drives if d.letter.upper().startswith("D")), None)

    items = []
    seen_paths = set()

    for node in overview.cleanup_candidates:
        seen_paths.add(node.path.lower())
        items.append({
            "id": node.id,
            "name": node.label,
            "path": node.path,
            "category": node.category,
            "size_gb": node.size_gb,
            "is_junction": node.reparse_point,
            "recommended_action": "safe_to_delete",
            "owning_processes": node.owning_processes,
            "tier": node.tier.value,
        })

    for node in overview.migration_candidates:
        seen_paths.add(node.path.lower())
        items.append({
            "id": node.id,
            "name": node.label,
            "path": node.path,
            "category": node.category,
            "size_gb": node.size_gb,
            "is_junction": node.reparse_point,
            "recommended_action": "relocate_with_junction",
            "owning_processes": node.owning_processes,
            "tier": node.tier.value,
        })

    for node in overview.top_consumers:
        if node.path.lower() not in seen_paths:
            seen_paths.add(node.path.lower())
            items.append({
                "id": node.id,
                "name": node.label,
                "path": node.path,
                "category": node.category,
                "size_gb": node.size_gb,
                "is_junction": node.reparse_point,
                "recommended_action": "do_not_move" if node.tier.value == "RED" else "review",
                "owning_processes": node.owning_processes,
                "tier": node.tier.value,
            })

    def drive_dict(d):
        if not d:
            return None
        return {
            "letter": d.letter,
            "fs": d.filesystem,
            "total_gb": d.total_gb,
            "free_gb": d.free_gb,
            "used_gb": round(d.used_bytes / (1024**3), 2),
            "used_percent": round((d.used_bytes / d.total_bytes) * 100, 1) if d.total_bytes else 0,
        }

    return {
        "session_id": overview.session_id,
        "timestamp": overview.timestamp,
        "c_drive": drive_dict(c_drive),
        "d_drive": drive_dict(d_drive),
        "discovered_items": items,
        "total_reclaimable_gb": round(overview.total_reclaimable_bytes / (1024**3), 2),
        "raw_overview": overview.model_dump(),
    }


@app.get("/api/overview")
def get_overview():
    global current_scan
    if not current_scan:
        current_scan = scanner.run_full_diagnosis()
    return format_overview_response(current_scan)


@app.post("/api/scan")
def trigger_scan():
    global current_scan
    current_scan = scanner.run_full_diagnosis()
    return format_overview_response(current_scan)



@app.post("/api/clean")
def clean_path(req: CleanRequest):
    is_temp = "temp" in req.target_path.lower()
    res = PrecisionCleaner.clean_target(req.target_path, req.owning_processes, is_temp)
    return res


@app.post("/api/relocate")
def relocate_path(req: RelocateRequest):
    res = relocator.execute_relocation(req.source_path, req.target_path, req.owning_processes)
    return res


@app.get("/api/known-folders")
def get_folders():
    return get_current_known_folder_paths()


@app.post("/api/redirect")
def redirect_folder(req: RedirectRequest):
    try:
        redirect_known_folder(req.folder_name, req.new_path)
        return {"status": "success", "folder": req.folder_name, "new_path": req.new_path}
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))


@app.get("/{path:path}")
def serve_console(path: str):
    file_path = CONSOLE_DIR / path
    if path and file_path.exists() and file_path.is_file():
        return FileResponse(file_path)
    index_file = CONSOLE_DIR / "index.html"
    if index_file.exists():
        return FileResponse(index_file)
    return HTMLResponse("<h1>C-Drive-Savior Console Loading...</h1>")


def start_server(host: str = "127.0.0.1", port: int = 8999):
    import uvicorn
    uvicorn.run(app, host=host, port=port, log_level="info")
