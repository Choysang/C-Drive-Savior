"""Strongly-typed Pydantic v2 Domain Models for Agent Contracts & Presentation."""

from __future__ import annotations

from enum import Enum
from typing import List, Optional, Dict, Any
from pydantic import BaseModel, Field


class Tier(str, Enum):
    GREEN = "GREEN"    # Safe to clean caches/logs/temps
    YELLOW = "YELLOW"  # Requires human or agent confirmation (workspaces, user configs)
    RED = "RED"        # Protected system/core install areas; never hand-delete
    MOVE = "MOVE"      # Relocatable user data / caches to D:


class DriveInfo(BaseModel):
    letter: str
    filesystem: str = "NTFS"
    total_bytes: int
    used_bytes: int
    free_bytes: int

    @property
    def free_gb(self) -> float:
        return round(self.free_bytes / (1024**3), 2)

    @property
    def total_gb(self) -> float:
        return round(self.total_bytes / (1024**3), 2)


class StorageNode(BaseModel):
    id: str
    path: str
    size_bytes: int
    tier: Tier
    label: str
    category: str = "general"
    action_id: Optional[str] = None
    owning_processes: List[str] = Field(default_factory=list)
    reparse_point: bool = False
    note: str = ""

    @property
    def size_mb(self) -> float:
        return round(self.size_bytes / (1024**2), 2)

    @property
    def size_gb(self) -> float:
        return round(self.size_bytes / (1024**3), 2)


class ScanOverview(BaseModel):
    session_id: str
    timestamp: str
    drives: List[DriveInfo]
    top_consumers: List[StorageNode]
    cleanup_candidates: List[StorageNode]
    migration_candidates: List[StorageNode]
    protected_system_nodes: List[StorageNode]
    total_reclaimable_bytes: int
    scanned_complete: bool = True
    unaccounted_gap_bytes: int = 0


class PlanOperation(BaseModel):
    op_id: str
    action_type: str  # "clean", "junction_move", "redirect"
    source_path: str
    target_path: Optional[str] = None
    size_bytes: int
    tier: Tier
    owning_processes: List[str] = Field(default_factory=list)
    description: str


class MigrationPlan(BaseModel):
    plan_id: str
    created_at: str
    operations: List[PlanOperation]
    estimated_freed_bytes: int
    blocked_processes: List[str] = Field(default_factory=list)
    approved: bool = False


class ActionResult(BaseModel):
    op_id: str
    status: str  # "completed", "partial", "skipped", "failed"
    freed_bytes: int = 0
    message: str = ""
    error: Optional[str] = None
