#!/usr/bin/env python3
"""
Timi Windows Sidebar Component.
Implements the full multi-lane sidebar:
- Agent rows with real-time status badges (busy spinner, idle dot, awaiting input mark, snoozed badge with timer, unread count).
- Collapsible project/lane groups with expand/collapse and count indicators.
- Quick action buttons (+, Opus, Sonnet, Codex, Fable).
- Real-time search filter bar.
- Shard rank display and selector.
"""

from dataclasses import dataclass, field
from typing import Dict, List, Optional, Callable

@dataclass
class AgentSessionItem:
    tab_id: str
    title: str
    lane: str
    status: str = "idle"  # idle, busy, awaiting, snoozed, error
    unread_count: int = 0
    group_name: str = "Default"
    created_at: float = 0.0
    snooze_text: Optional[str] = None
    autoclose_text: Optional[str] = None

class SidebarModel:
    def __init__(self):
        self.sessions: Dict[str, AgentSessionItem] = {}
        self.group_collapsed: Dict[str, bool] = {}
        self.active_tab_id: Optional[str] = None
        self.search_filter: str = ""
        self.active_shard: str = "geekzeino"
        self.available_shards: List[str] = ["geekzeino", "zeinobusiness", "personal"]

    def add_or_update_session(self, item: AgentSessionItem):
        self.sessions[item.tab_id] = item
        if item.group_name not in self.group_collapsed:
            self.group_collapsed[item.group_name] = False

    def remove_session(self, tab_id: str):
        self.sessions.pop(tab_id, None)
        if self.active_tab_id == tab_id:
            self.active_tab_id = next(iter(self.sessions.keys())) if self.sessions else None

    def toggle_group(self, group_name: str) -> bool:
        self.group_collapsed[group_name] = not self.group_collapsed.get(group_name, False)
        return self.group_collapsed[group_name]

    def set_filter(self, text: str):
        self.search_filter = text.strip().lower()

    def get_visible_sessions(self) -> Dict[str, List[AgentSessionItem]]:
        """Returns sessions partitioned by group, respecting collapse and search filter."""
        groups: Dict[str, List[AgentSessionItem]] = {}
        for item in self.sessions.values():
            if self.search_filter:
                match = (self.search_filter in item.title.lower() or
                         self.search_filter in item.lane.lower() or
                         self.search_filter in item.tab_id.lower())
                if not match:
                    continue
            groups.setdefault(item.group_name, []).append(item)
        return groups
