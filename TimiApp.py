import os
import sys
import time
import subprocess
import threading
import tkinter as tk
from tkinter import ttk, messagebox

BG_DARK = "#181825"
BG_SIDEBAR = "#1e1e2e"
BG_CARD = "#313244"
BG_CARD_ACTIVE = "#45475a"
TEXT_COLOR = "#cdd6f4"
TEXT_MUTED = "#a6adc8"
ACCENT_BLUE = "#89b4fa"
ACCENT_GREEN = "#a6e3a1"
ACCENT_YELLOW = "#f9e2af"
ACCENT_PURPLE = "#cba6f7"
BORDER_COLOR = "#313244"

class TimiWindowsDeck(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("(32) Linux To Windows Feature Migration — Timi")
        self.geometry("1400x850")
        self.state("zoomed")
        self.lift()
        self.focus_force()
        self.configure(bg=BG_DARK)

        # App state
        self.active_session_id = "s1"
        self.sessions = [
            {"id": "s1", "title": "Linux To Windows Feature Migration", "lane": "opus", "status": "active", "unread": 0, "group": "Active Rail"},
            {"id": "s2", "title": "VM Audio & Bridge Sync", "lane": "sonnet", "status": "idle", "unread": 1, "group": "Active Rail"},
            {"id": "s3", "title": "Copy Button & Clipboard Sharing", "lane": "sonnet", "status": "idle", "unread": 0, "group": "Active Rail"},
            {"id": "s4", "title": "New Tabs Auto-Select Lane", "lane": "codex", "status": "idle", "unread": 0, "group": "Active Rail"},
            {"id": "s5", "title": "Hogs Space & Debloat Pass", "lane": "glm", "status": "idle", "unread": 0, "group": "Active Rail"},
            {"id": "s6", "title": "Argus Multi-Monitor Watcher", "lane": "opus", "status": "busy", "unread": 3, "group": "Active Rail"},
            {"id": "s7", "title": "Timi Shard Router Matrix", "lane": "opus", "status": "snoozed", "snooze": "14m", "group": "Snoozed (14)"},
            {"id": "s8", "title": "ConPTY Terminal Zoom Clamp", "lane": "codex", "status": "snoozed", "snooze": "52m", "group": "Snoozed (14)"},
            {"id": "s9", "title": "Taskbar Pinning & AUMID Resolver", "lane": "sonnet", "status": "autoclose", "countdown": "24s", "group": "Autoclose (4)"},
            {"id": "s10", "title": "Initial Windows LTSC Repartition", "lane": "opus", "status": "archived", "group": "Archived (8)"},
        ]
        self.filter_text = ""

        self._create_header()
        self._create_layout()
        self._populate_sidebar()
        self._start_terminal()

    def _create_header(self):
        header = tk.Frame(self, bg=BG_SIDEBAR, height=42, bd=0, highlightthickness=1, highlightbackground=BORDER_COLOR)
        header.pack(side=tk.TOP, fill=tk.X)

        lbl_title = tk.Label(header, text="  TIMI  ", font=("Segoe UI", 11, "bold"), fg=ACCENT_BLUE, bg=BG_SIDEBAR)
        lbl_title.pack(side=tk.LEFT, padx=10, pady=8)

        # Quick action buttons
        btn_opus = tk.Button(header, text="+ Opus", font=("Segoe UI", 9, "bold"), fg="#11111b", bg=ACCENT_PURPLE,
                             relief=tk.FLAT, padx=8, pady=2, cursor="hand2", command=lambda: self._new_tab("opus"))
        btn_opus.pack(side=tk.LEFT, padx=4)

        btn_sonnet = tk.Button(header, text="+ Sonnet", font=("Segoe UI", 9, "bold"), fg="#11111b", bg=ACCENT_BLUE,
                               relief=tk.FLAT, padx=8, pady=2, cursor="hand2", command=lambda: self._new_tab("sonnet"))
        btn_sonnet.pack(side=tk.LEFT, padx=4)

        btn_codex = tk.Button(header, text="+ Codex", font=("Segoe UI", 9, "bold"), fg="#11111b", bg=ACCENT_GREEN,
                              relief=tk.FLAT, padx=8, pady=2, cursor="hand2", command=lambda: self._new_tab("codex"))
        btn_codex.pack(side=tk.LEFT, padx=4)

        # Shard indicator
        lbl_shard = tk.Label(header, text="Shard: geekzeino (Active) ", font=("Segoe UI", 9), fg=TEXT_MUTED, bg=BG_SIDEBAR)
        lbl_shard.pack(side=tk.RIGHT, padx=15)

    def _create_layout(self):
        self.main_container = tk.Frame(self, bg=BG_DARK)
        self.main_container.pack(fill=tk.BOTH, expand=True)

        # Sidebar Frame (Fixed width 360px)
        self.sidebar_frame = tk.Frame(self.main_container, bg=BG_SIDEBAR, width=360, bd=0, highlightthickness=1, highlightbackground=BORDER_COLOR)
        self.sidebar_frame.pack(side=tk.LEFT, fill=tk.Y)
        self.sidebar_frame.pack_propagate(False)

        # Filter Entry
        filter_box = tk.Frame(self.sidebar_frame, bg=BG_SIDEBAR, padx=12, pady=10)
        filter_box.pack(fill=tk.X)

        self.filter_entry = tk.Entry(filter_box, font=("Segoe UI", 10), bg=BG_CARD, fg=TEXT_COLOR,
                                     insertbackground=TEXT_COLOR, relief=tk.FLAT, bd=4)
        self.filter_entry.insert(0, "Filter sessions... (F3)")
        self.filter_entry.pack(fill=tk.X)
        self.filter_entry.bind("<FocusIn>", self._on_filter_focus_in)
        self.filter_entry.bind("<FocusOut>", self._on_filter_focus_out)
        self.filter_entry.bind("<KeyRelease>", self._on_filter_changed)

        # Scrollable sessions list
        self.canvas = tk.Canvas(self.sidebar_frame, bg=BG_SIDEBAR, bd=0, highlightthickness=0)
        self.scrollbar = tk.Scrollbar(self.sidebar_frame, orient=tk.VERTICAL, command=self.canvas.yview)
        self.scroll_content = tk.Frame(self.canvas, bg=BG_SIDEBAR)

        self.scroll_content.bind("<Configure>", lambda e: self.canvas.configure(scrollregion=self.canvas.bbox("all")))
        self.canvas.create_window((0, 0), window=self.scroll_content, anchor="nw", width=340)
        self.canvas.configure(yscrollcommand=self.scrollbar.set)

        self.canvas.pack(side=tk.LEFT, fill=tk.BOTH, expand=True, padx=(10, 0))
        self.scrollbar.pack(side=tk.RIGHT, fill=tk.Y)

        # Stage / Terminal Frame (Right side)
        self.stage_frame = tk.Frame(self.main_container, bg=BG_DARK)
        self.stage_frame.pack(side=tk.RIGHT, fill=tk.BOTH, expand=True)

        # Stage Header
        self.stage_header = tk.Frame(self.stage_frame, bg=BG_DARK, height=45)
        self.stage_header.pack(fill=tk.X, padx=16, pady=10)

        self.lbl_active_title = tk.Label(self.stage_header, text="Linux To Windows Feature Migration",
                                         font=("Segoe UI", 13, "bold"), fg=TEXT_COLOR, bg=BG_DARK)
        self.lbl_active_title.pack(side=tk.LEFT)

        self.lbl_lane_badge = tk.Label(self.stage_header, text=" OPUS XHIGH ", font=("Segoe UI", 9, "bold"),
                                       fg="#11111b", bg=ACCENT_PURPLE, padx=6, pady=2)
        self.lbl_lane_badge.pack(side=tk.LEFT, padx=10)

        # Terminal area
        self.terminal_box = tk.Frame(self.stage_frame, bg="#0d1117", highlightthickness=1, highlightbackground=BORDER_COLOR)
        self.terminal_box.pack(fill=tk.BOTH, expand=True, padx=16, pady=(0, 10))

        self.term_text = tk.Text(self.terminal_box, bg="#0d1117", fg="#c9d1d9", font=("Consolas", 11),
                                 bd=0, padx=12, pady=12, insertbackground="#58a6ff")
        self.term_text.pack(fill=tk.BOTH, expand=True)

        # Bottom Status Strip
        status_strip = tk.Frame(self.stage_frame, bg=BG_SIDEBAR, height=26, highlightthickness=1, highlightbackground=BORDER_COLOR)
        status_strip.pack(fill=tk.X, side=tk.BOTTOM)

        lbl_status = tk.Label(status_strip, text="● Connected | Provider: Opus-3.5 | Ctx: 200k (24k used) | Cost: $0.42 | Port: ConPTY Live",
                              font=("Segoe UI", 9), fg=TEXT_MUTED, bg=BG_SIDEBAR)
        lbl_status.pack(side=tk.LEFT, padx=12, pady=3)

    def _populate_sidebar(self):
        for widget in self.scroll_content.winfo_children():
            widget.destroy()

        # Group sessions
        groups = {}
        for s in self.sessions:
            if self.filter_text and self.filter_text.lower() not in s["title"].lower():
                continue
            groups.setdefault(s["group"], []).append(s)

        for group_name, items in groups.items():
            # Group Header
            grp_lbl = tk.Label(self.scroll_content, text=f"▾ {group_name.upper()}", font=("Segoe UI", 9, "bold"),
                               fg=TEXT_MUTED, bg=BG_SIDEBAR, anchor="w")
            grp_lbl.pack(fill=tk.X, pady=(12, 4), padx=4)

            for item in items:
                is_active = (item["id"] == self.active_session_id)
                card_bg = BG_CARD_ACTIVE if is_active else BG_CARD

                card = tk.Frame(self.scroll_content, bg=card_bg, cursor="hand2", padx=10, pady=8,
                                highlightthickness=1, highlightbackground=ACCENT_BLUE if is_active else BORDER_COLOR)
                card.pack(fill=tk.X, pady=3)
                card.bind("<Button-1>", lambda e, s_id=item["id"]: self._select_session(s_id))

                # Top row: Lane tag + Status indicator
                top_row = tk.Frame(card, bg=card_bg)
                top_row.pack(fill=tk.X)
                top_row.bind("<Button-1>", lambda e, s_id=item["id"]: self._select_session(s_id))

                lane_color = ACCENT_PURPLE if item["lane"] == "opus" else (ACCENT_BLUE if item["lane"] == "sonnet" else ACCENT_GREEN)
                lane_lbl = tk.Label(top_row, text=item["lane"].upper(), font=("Segoe UI", 7, "bold"),
                                    fg=lane_color, bg=card_bg)
                lane_lbl.pack(side=tk.LEFT)

                if "snooze" in item:
                    badge = tk.Label(top_row, text=f"⏳ {item['snooze']}", font=("Segoe UI", 7, "bold"),
                                     fg=ACCENT_YELLOW, bg=card_bg)
                    badge.pack(side=tk.RIGHT)
                elif "countdown" in item:
                    badge = tk.Label(top_row, text=f"⏱ {item['countdown']}", font=("Segoe UI", 7, "bold"),
                                     fg=ACCENT_GREEN, bg=card_bg)
                    badge.pack(side=tk.RIGHT)
                elif item["status"] == "busy":
                    badge = tk.Label(top_row, text="● BUSY", font=("Segoe UI", 7, "bold"), fg=ACCENT_YELLOW, bg=card_bg)
                    badge.pack(side=tk.RIGHT)

                # Title
                title_lbl = tk.Label(card, text=item["title"], font=("Segoe UI", 9, "bold" if is_active else "normal"),
                                     fg=TEXT_COLOR if is_active else TEXT_MUTED, bg=card_bg, anchor="w", wraplength=280, justify=tk.LEFT)
                title_lbl.pack(fill=tk.X, pady=(3, 0))
                title_lbl.bind("<Button-1>", lambda e, s_id=item["id"]: self._select_session(s_id))

    def _select_session(self, s_id):
        self.active_session_id = s_id
        session = next((s for s in self.sessions if s["id"] == s_id), None)
        if session:
            self.lbl_active_title.config(text=session["title"])
            lane_color = ACCENT_PURPLE if session["lane"] == "opus" else (ACCENT_BLUE if session["lane"] == "sonnet" else ACCENT_GREEN)
            self.lbl_lane_badge.config(text=f" {session['lane'].upper()} ", bg=lane_color)
            self.term_text.insert(tk.END, f"\r\n[Switching to lane: {session['lane']} | Session: {session['title']}]\r\nC:\\Users\\Ahmad> ")
            self.term_text.see(tk.END)
        self._populate_sidebar()

    def _new_tab(self, lane):
        new_id = f"s{len(self.sessions) + 1}"
        new_item = {
            "id": new_id,
            "title": f"New {lane.title()} Workspace",
            "lane": lane,
            "status": "idle",
            "unread": 0,
            "group": "Active Rail"
        }
        self.sessions.insert(0, new_item)
        self._select_session(new_id)

    def _on_filter_focus_in(self, event):
        if self.filter_entry.get().startswith("Filter"):
            self.filter_entry.delete(0, tk.END)

    def _on_filter_focus_out(self, event):
        if not self.filter_entry.get():
            self.filter_entry.insert(0, "Filter sessions... (F3)")

    def _on_filter_changed(self, event):
        val = self.filter_entry.get()
        self.filter_text = "" if val.startswith("Filter") else val
        self._populate_sidebar()

    def _start_terminal(self):
        banner = (
            "========================================================================================\n"
            " TIMI WINDOWS EXACT REPLICA — ConPTY AGENT HOST\n"
            " Native multi-lane sidebar, snooze countdowns, autoclose engine, and archived history\n"
            "========================================================================================\n\n"
            "Windows PowerShell\n"
            "Copyright (C) Microsoft Corporation. All rights reserved.\n\n"
            "C:\\Users\\Ahmad> claude --version\n"
            "claude 2.1.0 (shared hooks, memory, and skills active from \\\\192.168.122.1\\claude)\n\n"
            "C:\\Users\\Ahmad> "
        )
        self.term_text.insert(tk.END, banner)
        self.term_text.see(tk.END)

if __name__ == "__main__":
    app = TimiWindowsDeck()
    app.mainloop()
