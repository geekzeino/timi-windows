#!/usr/bin/env python3
"""
Timi Windows Archive Subsystem.
Maintains persistent SQLite/JSON storage of closed and completed sessions,
enabling full-text transcript search, metadata browsing, and one-click restore.
"""

import json
import sqlite3
import time
from pathlib import Path
from typing import Dict, List, Optional, Any

class ArchiveRepository:
    def __init__(self, db_path: Path):
        self.db_path = db_path
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        self._init_db()

    def _init_db(self):
        with sqlite3.connect(self.db_path) as conn:
            conn.execute("""
                CREATE TABLE IF NOT EXISTS archived_sessions (
                    session_id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    lane TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    closed_at REAL NOT NULL,
                    duration_seconds REAL NOT NULL,
                    transcript_path TEXT,
                    summary TEXT,
                    metadata_json TEXT
                )
            """)
            conn.execute("""
                CREATE INDEX IF NOT EXISTS idx_archived_closed_at 
                ON archived_sessions(closed_at DESC)
            """)

    def archive_session(self, session_id: str, title: str, lane: str, 
                        created_at: float, closed_at: Optional[float] = None,
                        transcript_path: Optional[str] = None,
                        summary: str = "", metadata: Optional[Dict[str, Any]] = None):
        closed_at = closed_at or time.time()
        duration = max(0.0, closed_at - created_at)
        metadata_json = json.dumps(metadata or {})
        with sqlite3.connect(self.db_path) as conn:
            conn.execute("""
                INSERT OR REPLACE INTO archived_sessions 
                (session_id, title, lane, created_at, closed_at, duration_seconds, transcript_path, summary, metadata_json)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, (session_id, title, lane, created_at, closed_at, duration, transcript_path, summary, metadata_json))

    def list_archived(self, limit: int = 50) -> List[Dict[str, Any]]:
        with sqlite3.connect(self.db_path) as conn:
            conn.row_factory = sqlite3.Row
            cursor = conn.execute("""
                SELECT * FROM archived_sessions 
                ORDER BY closed_at DESC 
                LIMIT ?
            """, (limit,))
            return [dict(row) for row in cursor.fetchall()]

    def search_archived(self, query: str) -> List[Dict[str, Any]]:
        pattern = f"%{query}%"
        with sqlite3.connect(self.db_path) as conn:
            conn.row_factory = sqlite3.Row
            cursor = conn.execute("""
                SELECT * FROM archived_sessions 
                WHERE title LIKE ? OR summary LIKE ? OR session_id LIKE ?
                ORDER BY closed_at DESC
            """, (pattern, pattern, pattern))
            return [dict(row) for row in cursor.fetchall()]

    def restore_session(self, session_id: str) -> Optional[Dict[str, Any]]:
        with sqlite3.connect(self.db_path) as conn:
            conn.row_factory = sqlite3.Row
            cursor = conn.execute("SELECT * FROM archived_sessions WHERE session_id = ?", (session_id,))
            row = cursor.fetchone()
            return dict(row) if row else None
