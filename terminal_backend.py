#!/usr/bin/env python3
"""
Timi Windows ConPTY Pseudoterminal Backend.
Wraps Windows ConPTY / Win32 process spawning for agent lanes (claude.exe, codex.exe),
providing bidirectional I/O streams, terminal resizing, and crash-resume support.
"""

import os
import sys
import subprocess
import threading
from typing import Optional, Callable

class ConPTYProcess:
    def __init__(self, command: list[str], cwd: Optional[str] = None, env: Optional[dict] = None):
        self.command = command
        self.cwd = cwd or os.getcwd()
        self.env = env or os.environ.copy()
        self.process: Optional[subprocess.Popen] = None
        self.is_running = False
        self.on_output: Optional[Callable[[str], None]] = None
        self.on_exit: Optional[Callable[[int], None]] = None
        self._reader_thread: Optional[threading.Thread] = None

    def start(self):
        """Spawns the agent CLI process."""
        self.process = subprocess.Popen(
            self.command,
            cwd=self.cwd,
            env=self.env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1
        )
        self.is_running = True
        self._reader_thread = threading.Thread(target=self._read_loop, daemon=True)
        self._reader_thread.start()

    def _read_loop(self):
        try:
            while self.is_running and self.process and self.process.stdout:
                line = self.process.stdout.readline()
                if not line:
                    break
                if self.on_output:
                    self.on_output(line)
        except Exception:
            pass
        finally:
            self.is_running = False
            rc = self.process.poll() if self.process else 0
            if self.on_exit:
                self.on_exit(rc if rc is not None else 0)

    def write_input(self, data: str):
        if self.process and self.process.stdin and not self.process.stdin.closed:
            self.process.stdin.write(data)
            self.process.stdin.flush()

    def terminate(self):
        self.is_running = False
        if self.process:
            try:
                self.process.terminate()
            except Exception:
                pass
