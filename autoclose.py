#!/usr/bin/env python3
"""
Timi Windows Autoclose Subsystem.
Scans terminal output tails for completion markers, integrates with finisher hooks,
manages visual countdowns, and triggers safe auto-closure with archiving.
"""

import re
import time
from typing import Optional, Callable, Dict, Any

COMPLETION_MARKERS = [
    re.compile(r"TASK\s+COMPLETE", re.I),
    re.compile(r"ORACLE:\s*rc=0\b", re.I),
    re.compile(r"WORKER\s+DONE\s+MARKER:", re.I),
]

class AutocloseState:
    def __init__(self, tab_id: str, countdown_seconds: int = 30):
        self.tab_id = tab_id
        self.countdown_seconds = countdown_seconds
        self.armed_at: Optional[float] = None
        self.cancelled = False
        self.completed = False

    @property
    def is_armed(self) -> bool:
        return self.armed_at is not None and not self.cancelled and not self.completed

    @property
    def remaining_seconds(self) -> float:
        if not self.armed_at or self.cancelled:
            return 0.0
        elapsed = time.monotonic() - self.armed_at
        return max(0.0, float(self.countdown_seconds) - elapsed)

    @property
    def is_due(self) -> bool:
        return self.is_armed and self.remaining_seconds <= 0.0


class AutocloseEngine:
    def __init__(self, countdown_seconds: int = 30, on_autoclose: Optional[Callable[[str], None]] = None):
        self.countdown_seconds = countdown_seconds
        self.on_autoclose = on_autoclose
        self.states: Dict[str, AutocloseState] = {}
        self.finisher_validator: Optional[Callable[[str], bool]] = None

    def scan_tail(self, text: str) -> bool:
        """Evaluate whether output tail contains explicit completion claims."""
        if not text:
            return False
        tail_lines = text.strip().splitlines()[-15:]
        tail_block = "\n".join(tail_lines)
        return any(pattern.search(tail_block) for pattern in COMPLETION_MARKERS)

    def evaluate_tab(self, tab_id: str, tail_text: str, is_busy: bool = False) -> Optional[AutocloseState]:
        state = self.states.setdefault(tab_id, AutocloseState(tab_id, self.countdown_seconds))
        if is_busy:
            # Never arm autoclose while child process is actively executing
            if state.is_armed:
                state.cancelled = True
            return None

        if not state.is_armed and not state.completed:
            if self.scan_tail(tail_text):
                # Pass through finisher gate if configured
                if self.finisher_validator and not self.finisher_validator(tab_id):
                    return None
                state.armed_at = time.monotonic()
                state.cancelled = False
                return state

        return state if state.is_armed else None

    def cancel(self, tab_id: str):
        state = self.states.get(tab_id)
        if state:
            state.cancelled = True

    def tick(self) -> list[str]:
        """Check all armed states; returns list of tab_ids that should be closed now."""
        to_close = []
        for tab_id, state in list(self.states.items()):
            if state.is_due:
                state.completed = True
                to_close.append(tab_id)
                if self.on_autoclose:
                    self.on_autoclose(tab_id)
        return to_close
