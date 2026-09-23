#!/usr/bin/env python3
"""
Timi Windows — Exact Replica Application.
Integrates the complete multi-lane sidebar, snooze subsystem, autoclose engine,
archived chats browser, and ConPTY terminal host for Windows.
"""

import sys
import os
import time
from pathlib import Path
from typing import Optional, Dict

from sidebar import SidebarModel, AgentSessionItem
from snooze import SnoozeManager
from autoclose import AutocloseEngine
from archive import ArchiveRepository
from terminal_backend import ConPTYProcess

class TimiWindowsApp:
    def __init__(self, data_dir: Optional[Path] = None):
        self.data_dir = data_dir or (Path.home() / ".config" / "timi")
        self.data_dir.mkdir(parents=True, exist_ok=True)
        
        # Subsystems
        self.sidebar = SidebarModel()
        self.snooze = SnoozeManager(audit_interval_seconds=900.0)  # 15m audit
        self.archive = ArchiveRepository(self.data_dir / "history.sqlite")
        self.autoclose = AutocloseEngine(countdown_seconds=30, on_autoclose=self._on_tab_autoclosed)
        self.active_processes: Dict[str, ConPTYProcess] = {}
        
        # Theme & Display settings
        self.theme = "dark"
        self.font_size = 11.0  # Supports Ctrl+wheel zoom 4.0 - 24.0
        
        # Start background services
        self.snooze.start_audit_loop()

    def create_tab(self, lane: str = "opus", title: Optional[str] = None, group: str = "Default") -> AgentSessionItem:
        tab_id = f"tab-{int(time.time()*1000)}"
        title = title or f"{lane.title()} Lane"
        item = AgentSessionItem(
            tab_id=tab_id,
            title=title,
            lane=lane,
            status="idle",
            group_name=group,
            created_at=time.time()
        )
        self.sidebar.add_or_update_session(item)
        if not self.sidebar.active_tab_id:
            self.sidebar.active_tab_id = tab_id
        return item

    def close_tab(self, tab_id: str, auto_archive: bool = True):
        item = self.sidebar.sessions.get(tab_id)
        if item:
            # Terminate active process if running
            proc = self.active_processes.pop(tab_id, None)
            if proc:
                proc.terminate()
            
            # Archive session
            if auto_archive:
                self.archive.archive_session(
                    session_id=item.tab_id,
                    title=item.title,
                    lane=item.lane,
                    created_at=item.created_at,
                    summary=f"Closed session in {item.lane}"
                )
            
            self.sidebar.remove_session(tab_id)
            self.snooze.unsnooze(tab_id, reason="tab closed")

    def _on_tab_autoclosed(self, tab_id: str):
        self.close_tab(tab_id, auto_archive=True)

    def snooze_active_tab(self, preset: str = "1h"):
        if not self.sidebar.active_tab_id:
            return
        tab_id = self.sidebar.active_tab_id
        duration = self.snooze.INTERVAL_PRESETS.get(preset, 3600.0)
        self.snooze.snooze(tab_id, duration, on_wake=lambda: self._on_tab_woken(tab_id))
        item = self.sidebar.sessions.get(tab_id)
        if item:
            item.status = "snoozed"
            item.snooze_text = self.snooze.get_badge_text(tab_id)

    def _on_tab_woken(self, tab_id: str):
        item = self.sidebar.sessions.get(tab_id)
        if item:
            item.status = "idle"
            item.snooze_text = None

    def zoom_font(self, delta: float):
        self.font_size = max(4.0, min(24.0, self.font_size + delta))

    def set_theme(self, theme_name: str):
        if theme_name in ("light", "dark"):
            self.theme = theme_name

    def restore_archived_session(self, session_id: str) -> Optional[AgentSessionItem]:
        record = self.archive.restore_session(session_id)
        if record:
            item = self.create_tab(lane=record["lane"], title=record["title"])
            return item
        return None

if __name__ == "__main__":
    app = TimiWindowsApp()
    t1 = app.create_tab("opus", "Primary Opus Session")
    t2 = app.create_tab("sonnet", "Reviewer Sonnet Session")
    print(f"Timi Windows initialized successfully with {len(app.sidebar.sessions)} tabs.")
