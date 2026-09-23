#!/usr/bin/env python3
"""Comprehensive test suite for Timi Windows Exact Replica."""

import unittest
import time
import tempfile
import shutil
from pathlib import Path

from sidebar import SidebarModel, AgentSessionItem
from snooze import SnoozeManager, SnoozeEntry
from autoclose import AutocloseEngine
from archive import ArchiveRepository
from timi_app import TimiWindowsApp

class TestTimiWindowsReplica(unittest.TestCase):
    def setUp(self):
        self.temp_dir = Path(tempfile.mkdtemp())
        self.app = TimiWindowsApp(data_dir=self.temp_dir)

    def tearDown(self):
        self.app.snooze.stop_audit_loop()
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def test_sidebar_model_and_filtering(self):
        sb = self.app.sidebar
        item1 = AgentSessionItem(tab_id="t1", title="Opus Architecture", lane="opus", group_name="Core")
        item2 = AgentSessionItem(tab_id="t2", title="Sonnet Reviewer", lane="sonnet", group_name="Core")
        item3 = AgentSessionItem(tab_id="t3", title="Codex Hunter", lane="codex", group_name="QA")
        
        sb.add_or_update_session(item1)
        sb.add_or_update_session(item2)
        sb.add_or_update_session(item3)
        
        groups = sb.get_visible_sessions()
        self.assertIn("Core", groups)
        self.assertEqual(len(groups["Core"]), 2)
        self.assertEqual(len(groups["QA"]), 1)
        
        # Test search filter
        sb.set_filter("Architect")
        filtered = sb.get_visible_sessions()
        self.assertIn("Core", filtered)
        self.assertEqual(len(filtered["Core"]), 1)
        self.assertNotIn("QA", filtered)

    def test_snooze_lifecycle_and_auto_wake(self):
        t1 = self.app.create_tab("opus", "Snooze Test Tab")
        self.app.sidebar.active_tab_id = t1.tab_id
        
        # Snooze for 2 seconds
        self.app.snooze.snooze(t1.tab_id, duration_seconds=2.0)
        self.assertTrue(self.app.snooze.is_snoozed(t1.tab_id))
        self.assertIsNotNone(self.app.snooze.get_badge_text(t1.tab_id))
        
        # Incoming activity breaks snooze immediately
        self.app.snooze.on_activity(t1.tab_id)
        self.assertFalse(self.app.snooze.is_snoozed(t1.tab_id))

    def test_autoclose_detection_and_gating(self):
        engine = AutocloseEngine(countdown_seconds=1)
        
        # Completion token detection
        self.assertTrue(engine.scan_tail("Some logs\nTASK COMPLETE\nfinal line"))
        self.assertTrue(engine.scan_tail("Check passed\nORACLE: rc=0"))
        self.assertFalse(engine.scan_tail("Work in progress... still compiling"))
        
        # Busy suppression: never arm when child process is busy
        state = engine.evaluate_tab("t_busy", "ORACLE: rc=0", is_busy=True)
        self.assertIsNone(state)
        
        # Armed when idle
        state = engine.evaluate_tab("t_idle", "TASK COMPLETE", is_busy=False)
        self.assertIsNotNone(state)
        self.assertTrue(state.is_armed)

    def test_archive_persistence_and_restore(self):
        t1 = self.app.create_tab("opus", "Task to Archive")
        tab_id = t1.tab_id
        
        # Close and auto-archive
        self.app.close_tab(tab_id, auto_archive=True)
        self.assertNotIn(tab_id, self.app.sidebar.sessions)
        
        # Verify in archive
        archived = self.app.archive.list_archived()
        self.assertEqual(len(archived), 1)
        self.assertEqual(archived[0]["title"], "Task to Archive")
        
        # Restore session
        restored = self.app.restore_archived_session(tab_id)
        self.assertIsNotNone(restored)
        self.assertEqual(restored.title, "Task to Archive")

    def test_font_zoom_limits(self):
        self.app.font_size = 12.0
        self.app.zoom_font(5.0)
        self.assertEqual(self.app.font_size, 17.0)
        
        # Clamp to max 24.0
        self.app.zoom_font(20.0)
        self.assertEqual(self.app.font_size, 24.0)
        
        # Clamp to min 4.0
        self.app.zoom_font(-50.0)
        self.assertEqual(self.app.font_size, 4.0)

if __name__ == "__main__":
    unittest.main()
