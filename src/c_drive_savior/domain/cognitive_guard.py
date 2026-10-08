"""Cognitive Guard: Protects Agent context windows from payload flooding."""

from __future__ import annotations

from typing import List, Dict, Any, Optional
from c_drive_savior.domain.models import ScanOverview, StorageNode, MigrationPlan


class CognitiveGuard:
    """
    Ensures that data returned to LLM Agents conforms to high-signal,
    low-token standards with cursor pagination and executive summaries.
    """

    @staticmethod
    def summarize_scan(overview: ScanOverview, top_n: int = 8) -> Dict[str, Any]:
        """Generate a compact summary card that fits into < 500 tokens."""
        c_drive = next((d for d in overview.drives if d.letter.upper().startswith("C")), None)
        d_drive = next((d for d in overview.drives if d.letter.upper().startswith("D")), None)

        return {
            "session_id": overview.session_id,
            "c_drive": {
                "total_gb": c_drive.total_gb if c_drive else 0,
                "free_gb": c_drive.free_gb if c_drive else 0,
                "used_gb": round(c_drive.used_bytes / (1024**3), 2) if c_drive else 0,
            },
            "d_drive_free_gb": d_drive.free_gb if d_drive else None,
            "potential_reclaimable_gb": round(overview.total_reclaimable_bytes / (1024**3), 2),
            "top_consumers": [
                {
                    "id": node.id,
                    "label": node.label,
                    "size_gb": node.size_gb,
                    "tier": node.tier.value,
                    "path": node.path,
                }
                for node in overview.top_consumers[:top_n]
            ],
            "recommended_cleanups_count": len(overview.cleanup_candidates),
            "recommended_moves_count": len(overview.migration_candidates),
        }

    @staticmethod
    def paginate_nodes(
        nodes: List[StorageNode],
        cursor: Optional[int] = 0,
        page_size: int = 15,
    ) -> Dict[str, Any]:
        """Cursor-based pagination for large node listings."""
        offset = cursor or 0
        paged = nodes[offset : offset + page_size]
        next_cursor = offset + page_size if (offset + page_size) < len(nodes) else None

        return {
            "items": [node.model_dump() for node in paged],
            "total_items": len(nodes),
            "next_cursor": next_cursor,
            "has_more": next_cursor is not None,
        }
