#!/usr/bin/env python3
"""
Timi Windows Snooze Subsystem.
Implements snooze intervals, countdown indicators, auto-wakeup on activity,
and the durable 15-minute operator-only idleness audit.
"""

import time
import threading
from typing import Dict, Optional, Callable, List

class SnoozeEntry:
    def __init__(self, tab_id: str, duration_seconds: float, on_wake: Optional[Callable] = None):
        self.tab_id = tab_id
        self.start_time = time.monotonic()
        self.duration_seconds = duration_seconds
        self.deadline = self.start_time + duration_seconds
        self.on_wake = on_wake
        self.awakened = False

    @property
    def remaining_seconds(self) -> float:
        return max(0.0, self.deadline - time.monotonic())

    @property
    def is_expired(self) -> bool:
        return time.monotonic() >= self.deadline

    def remaining_formatted(self) -> str:
        rem = int(self.remaining_seconds)
        if rem <= 0:
            return "0s"
        hours, rem = divmod(rem, 3600)
        minutes, seconds = divmod(rem, 60)
        if hours > 0:
            return f"{hours}h {minutes}m"
        if minutes > 0:
            return f"{minutes}m {seconds}s"
        return f"{seconds}s"


class SnoozeManager:
    INTERVAL_PRESETS = {
        "15m": 15 * 60,
        "1h": 60 * 60,
        "3h": 3 * 60 * 60,
        "tomorrow": 12 * 60 * 60,
    }

    def __init__(self, audit_interval_seconds: float = 900.0):  # 15 minutes default
        self.entries: Dict[str, SnoozeEntry] = {}
        self.lock = threading.Lock()
        self.audit_interval = audit_interval_seconds
        self._audit_thread: Optional[threading.Thread] = None
        self._running = False
        self.audit_log: List[str] = []

    def snooze(self, tab_id: str, duration_seconds: float, on_wake: Optional[Callable] = None) -> SnoozeEntry:
        with self.lock:
            entry = SnoozeEntry(tab_id, duration_seconds, on_wake)
            self.entries[tab_id] = entry
            self._log_audit(f"Tab {tab_id} snoozed for {duration_seconds}s (until {entry.deadline})")
            return entry

    def unsnooze(self, tab_id: str, reason: str = "manual") -> bool:
        with self.lock:
            entry = self.entries.pop(tab_id, None)
            if entry and not entry.awakened:
                entry.awakened = True
                self._log_audit(f"Tab {tab_id} unsnoozed ({reason})")
                if entry.on_wake:
                    entry.on_wake()
                return True
            return False

    def is_snoozed(self, tab_id: str) -> bool:
        with self.lock:
            entry = self.entries.get(tab_id)
            if entry:
                if entry.is_expired:
                    self.entries.pop(tab_id)
                    entry.awakened = True
                    if entry.on_wake:
                        entry.on_wake()
                    return False
                return True
            return False

    def get_badge_text(self, tab_id: str) -> Optional[str]:
        with self.lock:
            entry = self.entries.get(tab_id)
            if entry and not entry.is_expired:
                return f"💤 {entry.remaining_formatted()}"
            return None

    def on_activity(self, tab_id: str):
        """Wake a snoozed tab when new output or user interaction occurs."""
        self.unsnooze(tab_id, reason="incoming activity")

    def _log_audit(self, message: str):
        entry = f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {message}"
        self.audit_log.append(entry)

    def start_audit_loop(self):
        self._running = True
        self._audit_thread = threading.Thread(target=self._audit_worker, daemon=True)
        self._audit_thread.start()

    def stop_audit_loop(self):
        self._running = False

    def _audit_worker(self):
        while self._running:
            time.sleep(min(self.audit_interval, 5.0))
            with self.lock:
                now = time.monotonic()
                expired = [tid for tid, entry in self.entries.items() if entry.is_expired]
                for tid in expired:
                    entry = self.entries.pop(tid)
                    entry.awakened = True
                    self._log_audit(f"Audit: Tab {tid} snooze expired at {now}")
                    if entry.on_wake:
                        entry.on_wake()
