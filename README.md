# Timi (Windows)

The Windows port of `/home/zeino/.local/bin/timi`. On Linux, Timi is a GTK window
that is itself the terminal host, one tab per agent lane. Windows Terminal is
already a good multi-tab terminal host, so this port does not reimplement that —
it runs **its own private copy** of Windows Terminal, plus the four things
Windows Terminal has no opinion about:

| | |
|---|---|
| **Tabs survive a crash or a reboot** | the tab set, and the conversation inside each one |
| **Follows the Windows light/dark switch** | window chrome, terminal palette, and Claude Code's own theme |
| **Runs elevated, with no UAC prompt** | so the agent never hits a permission wall |
| **Ctrl + mouse wheel zooms the text** | which the Terminal alone cannot do inside Claude Code |

Inside a Timi window the `+` button and `Ctrl+Shift+T` open an **Opus xhigh**
lane — `defaultProfile` points at it, because a shell was the wrong thing for
the most-used button in an agent window to hand back. The Windows Terminal in
the Start menu is *not* affected by any of that: see
[Its own Terminal](#its-own-terminal).

Install or repair everything with:

```powershell
powershell -ExecutionPolicy Bypass -File C:\Users\Ahmad\Timi\Install-Timi.ps1
```

It is idempotent, asks for administrator once, and `Uninstall-Timi.ps1` reverses
every change it makes outside this folder.

---

## Files

| File | What it is |
|---|---|
| `Timi.exe` / `Timi.cs` | the launcher that gets pinned and clicked. A WinExe so there is no console flash, carrying `Timi.ico` as its own icon. `/install`, `/shortcut` and `/pin` are its internal modes |
| `Launch-Timi.ps1` | what actually opens Timi: elevation, drive maps, single-window, restore-or-seed |
| `TimiLane.exe` / `TimiLane.cs` | the process behind one agent tab: session identity, crash-resume, theme sync. A console exe, so it inherits the tab and hands it straight to `claude.exe` |
| `timi-lane.ps1` | the previous, shell version of the same thing. Kept as the readable reference — see [Why the lane is an exe](#why-the-lane-is-an-exe) |
| `Install-Timi.ps1` | provisioning. Scheduled task, shortcuts, taskbar entry, registry, hotkey hook |
| `Uninstall-Timi.ps1` | undoes all of it |
| `Patch-WtSettings.py` | writes Timi's settings into **Timi's own** Terminal `settings.json`; `--unpatch` takes them back out of the user's |
| `wt\` | Timi's private Windows Terminal — the unpackaged build plus an empty `.portable` marker, which is what makes it keep its settings and layouts in `wt\settings` |
| `Make-TimiIcon.ps1` | draws `Timi.ico` (9 sizes, native-drawn per size) |
| `Patch-WtIcon.ps1` | stamps that icon *into* `wt\WindowsTerminal.exe`, so the window stops wearing the Microsoft Terminal glyph. `-Restore` puts the stock binaries back |
| `wt-settings.json` | a mirror of the live Terminal settings, refreshed on every patch. Not the source of truth — the Terminal rewrites its own file |
| `map-drives.cmd` | H:/Y: from the Linux host |
| `Refresh Claude setup.cmd` | pulls rules/memory/skills from `\\192.168.122.1\claude` |
| `taskband-backup-*.reg`, `taskbar-layout-backup-*.xml`, `taskbar-policy-backup-*.txt` | safety copies taken before anything touched the taskbar |

Outside this folder: `C:\Users\Ahmad\Scripts\timi-zoom.ahk` (the wheel hook,
kept resident by the existing *ShareX Hotkey Keepalive* task) and
`%LOCALAPPDATA%\Timi\` (lane markers, `launch.log`, `install.log`, `pin.log`).

---

## How each piece works

### Its own Terminal

Timi used to share the Windows Terminal in the Start menu, and sharing a
terminal means sharing its `settings.json`. Everything Timi needed landed in the
window the user opens for ordinary work: nine `Timi - …` profiles in the profile
list, `defaultProfile` on an agent so the `+` button handed back Opus instead of
PowerShell, three font bindings, and `firstWindowPreference:
persistedWindowLayout`, which made a plain `wt` reopen yesterday's tabs. One
button on the taskbar collected both. There is no per-window setting that undoes
any of that — the file is the unit.

So Timi ships its own Terminal: the **unpackaged** (ZIP) build in `Timi\wt`,
with an empty file named `.portable` next to `WindowsTerminal.exe`. That marker
is the whole mechanism — in portable mode the Terminal keeps its settings *and*
its saved window layouts in a `settings` folder beside the exe instead of the
Store app's `LocalState`. It only works on the unpackaged build; the packaged
one ignores the marker, which is why this is a second copy of the Terminal
rather than a flag.

| | user's Terminal | Timi |
|---|---|---|
| binary | `…\WindowsApps\Microsoft.WindowsTerminal_…\wt.exe` | `Timi\wt\wt.exe` |
| settings | `…\Packages\Microsoft.WindowsTerminal_…\LocalState` | `Timi\wt\settings` |
| profiles | its own, unchanged | the nine lanes |
| `+` opens | PowerShell | an Opus xhigh lane |
| tab restore | off, as it was before Timi | on |
| updates | the Store | `Install-Timi.ps1`, by hand |

Two consequences worth knowing. The unpackaged build **does not auto-update** —
re-unzip a newer release over `Timi\wt` and keep the `.portable` file. And
`Launch-Timi.ps1` deliberately has **no fallback** to the `wt.exe` on `PATH`: it
would read the user's settings, find no lanes, and open a window that looks like
Timi but is not.

`Patch-WtSettings.py --unpatch` is the other half. It removes the Timi profiles,
schemes, bindings, `defaultProfile` and layout preference from a settings file —
that is what handed the Store Terminal back — and it is a no-op on a file that
never had them.

### Its own icon

Splitting the install fixed the settings but not the identity. The window is
drawn by `Timi\wt\WindowsTerminal.exe`; an unpackaged Windows Terminal takes its
window icon from its own `RT_GROUP_ICON` resource, and that resource is
Microsoft's. `Timi.ico` only ever reached the *shortcut*, so Timi opened wearing
the exact glyph of the Terminal in the Start menu — same mark in the taskbar,
same mark in Alt+Tab, nothing to tell the two apart.

`Patch-WtIcon.ps1` rewrites that resource — every icon group the build carries,
under the language it is stored in, read rather than hard-coded — and
`Install-Timi.ps1` runs it, so a freshly unzipped Terminal gets re-stamped
instead of silently reverting. The pristine binary is kept beside it as
`WindowsTerminal.exe.msorig` and every run patches from that copy, which is what
makes it idempotent and `-Restore` a single step.

Three things follow:

* It applies from the **next Timi launch**. A running process keeps the image it
  started from, so the taskbar button holds the old glyph until Timi restarts,
  and that old image is parked as `WindowsTerminal.exe.inuse-<stamp>` until a
  later run can delete it.
* Editing resources **invalidates the Authenticode signature**. Nothing here
  enforces it — `CiTool --list-policies` shows Smart App Control's enforcing
  policy (`VerifiedAndReputableDesktop`) *not* enforced and only its Evaluation
  twin active, which audits and never blocks — and the binary already sits in a
  user-writable folder. Measured rather than assumed: a patched copy launches.
* The user's Store Terminal is a different install and is never touched. It
  keeps the Microsoft glyph, which is the whole point.

### Tabs that survive

Two layers, because one is not enough.

**Windows Terminal** restores the tab set: `firstWindowPreference:
persistedWindowLayout`. It writes the layout of every open window to disk
*while they are running* — verified here, not assumed — which is what makes it
survive a kill rather than only a clean exit. It records each tab's profile,
position and working directory, but explicitly **not the contents of the panes**.

**`TimiLane.exe`** restores the conversations. Each tab owns a Claude session id
(`--session-id` going in, `--resume <id>` coming back) and writes a marker under
`%LOCALAPPDATA%\Timi\lanes\` naming the `WindowsTerminal.exe` that hosts it —
PID *and* process start time, because Windows recycles PIDs.

That marker is what tells a crash apart from an ordinary close:

| marker's host process | meaning | that conversation is |
|---|---|---|
| gone | the terminal crashed, the box rebooted, or the window was closed | recoverable |
| still running | you closed that tab yourself | not offered again |

That says which conversations are *recoverable*. A second rule says which tabs
may take one, and it exists because without it **Ctrl+T opened somebody's old
chat**. Closing a Timi window on purpose kills the host too, so every tab that
window held leaves a marker reading exactly like a crash, and the next tab to
start — restored or not — walked off with one. Measured 2026-08-31: all four
markers in `lanes\` named conversations last written *ten days earlier*, one
resurrected into each new tab of that day, none of which the user had asked to
reopen.

So a tab may claim a conversation **only while the window it lives in is still
coming up** — the layout restore, or the seeding below, and nothing else. Time
is the discriminator because the command line is not: the persisted layout
stores each tab's command line verbatim, so a restored tab and a Ctrl+T tab both
arrive as `TimiLane.exe opus` with nothing in argv, in the environment or on the
parent chain to tell them apart. What does separate them is when they start
relative to their window — the restored tab wrote its marker **1.118 s** after
its `WindowsTerminal.exe` began, while the three opened by hand in that same
window came 18, 27 and 29 minutes later — so the window is five seconds
(`RestoreWindowSeconds` in `TimiLane.cs`). A tab you opened yourself always
starts a new chat, however many orphaned conversations are lying around.

Per-lane session ids matter because `claude --continue` resumes *the most recent
conversation in the directory*, and all three lanes run in `%USERPROFILE%` — after
a crash it would hand the Sonnet tab whichever lane happened to speak last.

**One marker per TAB, not per lane** — `lane.pid.ticks.json`. Sharing one
`opus.json` between two Opus tabs quietly destroyed work: the tab that started
second wrote its session id over the first one's, and that conversation could
never be resumed. Found live on 2026-08-20, where `opus.json` named a session
opened a minute *after* the tab holding the actual work — and named one with no
transcript on disk at all, because that tab had been closed before it said
anything, which then made the next start find nothing to resume and open fresh.

So a starting tab **claims** one orphaned marker instead of reading "its own":
oldest first, only if the transcript actually exists, and taken by *renaming*
the file, which is atomic on NTFS — two tabs starting in the same instant cannot
walk off with the same conversation. Markers naming a transcript that was never
written are deleted rather than claimed.

**Transcripts hang off the account, not the home folder.** A lane billing a Timi
account runs claude with `CLAUDE_CONFIG_DIR` set to `~\.claude-cfg\<account>`,
and every transcript it writes lands under *that*. The lane and
`Launch-Timi.ps1` both resolve the account before they go looking, because
reading `~\.claude` regardless found only the conversations from before the
account was added: the lane announced one as restored and then watched
`--resume` refuse it, because the account's claude cannot see the default
login's folder, while the launcher deleted the markers of the ones that were
real. A resume that does fail now **repoints the marker** at the session that
actually started, so a transcript that refuses to open is not announced and
dropped again on every later start.

**The trust prompt is answered once per account, not once per tab.** Claude Code
keeps "yes, I trust this folder" per config dir, so every account added to Timi
arrives distrusting the one directory every lane runs in — and a tab still
parked on the unanswered question writes the flag back to `false` when it saves,
which is how it came back after it had been answered. The lane copies that
answer across before starting claude, but only an answer you already gave **for
the same directory under one of your own logins**; with none to copy, nothing is
written and the prompt appears exactly as it did before.

The markers are also the fallback: if the Terminal's saved layout is missing,
`Launch-Timi.ps1` seeds exactly the tabs those markers say were open — two Opus
tabs come back as two. And "missing" is the normal case, not the rare one: the
Terminal does **not** write a layout when you close the window deliberately, so
after an ordinary close these markers are the only thing that brings a
conversation back.

### Why the lane is an exe

Everything the lane wrapper does happens between Ctrl+T and the agent's first
frame, so it is pure waiting. As a PowerShell script that wait was 2.8–3.5 s
measured end to end, and almost none of it was work:

| | cost |
|---|---|
| `powershell.exe` 5.1 starting, before the first statement runs | ~1.0 s |
| `Get-HostTerminal` — the first `Get-CimInstance` stands the whole WMI/CIM stack up | ~0.8 s |
| marker write, theme read | ~0.3 s |
| the rest | memory pressure on an 8 GB box |

The parent walk is four integers deep and WMI was only ever asked for one of
them; `NtQueryInformationProcess` returns the same field in microseconds.
Rewritten as a console exe the same path takes **0.08–0.09 s warm, 0.36 s from
a cold start** — verified against `timi-lane.ps1` on a redirected
`USERPROFILE`/`LOCALAPPDATA` with a stub `claude`, checking that both write the
same marker (same keys, identical `wtPid`/`wtStart`) and make the same
resume-vs-fresh call for a dead host, a live host and no marker at all.

Two details that are easy to lose in the port: `Console.OutputEncoding` has to
be set to BOM-less UTF-8 or the lane glyph opens the tab as mojibake, and
`Console.CancelKeyPress` has to be swallowed so Ctrl+C reaches the agent
without killing the wrapper and running the marker cleanup early. The `-NoExit`
the profile used to carry now lives inside the exe: it opens a plain shell
*after* the agent finishes, so that ~1 s of PowerShell is paid on the way out
where nobody is waiting on it.

The old script still works and still reads the exe's markers, so swapping
`Patch-WtSettings.py`'s `lane_cmd` back is a one-line rollback.

### Light and dark

`theme: system` swings the window chrome and the profiles share a colour-scheme
*pair* — `{"light": "Timi Light", "dark": "Timi Dark"}` — so the text palette
follows the OS with it. A single scheme name would leave a dark terminal sitting
inside a light window.

Claude Code paints its own TUI, so `TimiLane.exe` also writes `theme` in
`~/.claude.json` to match the OS at lane start. That one is read at startup, so
a lane already running keeps its palette until it is restarted; the terminal
itself switches live.

In `Timi Light`, ANSI `white` and `brightWhite` are deliberately **dark**. Most
light schemes keep them near-white, which is correct in theory and invisible in
practice.

### Elevation without a prompt

The `Timi` scheduled task carries `RunLevel Highest`, and `schtasks /Run` needs
no consent — so `Timi.exe` asks the task to launch, and the window comes up
elevated every time. A shortcut with the "run as administrator" bit would put a
UAC dialog in front of every single launch instead.

Two consequences worth knowing:

* An elevated session does not inherit drive letters mapped by the unelevated
  one. `EnableLinkedConnections=1` fixes that from the next sign-in, and
  `Launch-Timi.ps1` re-runs `map-drives.cmd` at every launch so today works too.
  That step is wrapped in a `try`: `$ErrorActionPreference` is `Stop` and the
  trap exits, so **any** stderr out of the drive maps used to kill the launcher
  before a window existed, and the task just recorded result 1.
* The Terminal keeps elevated and unelevated windows strictly apart, including
  their saved layouts: `elevated-state.json` vs `state.json`. Timi only ever
  reads the one matching its own elevation.

### Why `elevate` is **not** set on the lane profiles

`"elevate": true` looks like the obvious belt-and-braces guarantee — the lane is
elevated no matter how the Terminal was opened — and it is a trap. The Terminal
does not lift a tab in place. A tab whose profile asks for elevation is handed to
`elevate-shim.exe`, which puts a **UAC dialog** on screen and then opens a
**second, elevated Terminal window** for it — and that window arrives carrying

```
WindowsTerminal.exe --profile "{guid}" --startingDirectory "C:\Users\Ahmad"
```

which is the third injury: *any* argument makes the Terminal skip
`firstWindowPreference`, so it comes up with one default tab and **restores
nothing**. Measured on 2026-08-20 from the prefetch trail — `TIMI.EXE` 15:03:29,
`CONSENT.EXE` 15:04:16, `ELEVATE-SHIM.EXE` 15:04:34 — with the elevated window's
command line matching exactly.

So the flag cost all three of the things it was meant to protect: a prompt
instead of promptless elevation, two windows instead of one, and lost
conversations. Elevation is a property of the **window** and belongs to the
scheduled task. `TimiLane.exe` keeps the guarantee honestly: a lane that finds
itself unelevated runs the `Timi` task (no prompt), prints one line and exits
before writing anything, so the unelevated window empties itself out while the
elevated one opens. A stamp file records *which window* asked, so the other tabs
of that same window step aside quietly instead of firing the task again — and a
stamp from a different window means the relaunch itself came back unelevated, at
which point the lane says so and runs rather than bouncing windows forever.

### Ctrl + wheel zoom

Windows Terminal zooms on Ctrl+wheel only when nothing in the tab has asked for
mouse input. Its `MouseWheel` handler checks `_canSendVTMouseInput` **first** and
forwards the event to the application; the zoom branch below it is never reached,
and Ctrl does not suppress that check (only Shift does). Claude Code enables VT
mouse tracking, so every Ctrl+wheel went to the agent.

No Terminal setting changes that ordering, so the wheel is converted to a
keystroke instead: `timi-zoom.ahk` maps `Ctrl+WheelUp/Down` to
`ctrl+alt+shift+F9/F10`, which `settings.json` binds to `adjustFontSize`.
Keystrokes bound in the Terminal are consumed before the application sees them.
`Ctrl+MButton` resets the size.

It runs from the *ShareX Hotkey Keepalive* task, which matters: that task runs
with `RunLevel Highest`, and UIPI drops synthetic input sent from a lower
integrity level than the elevated Timi window.

---

## Taskbar pin — read this before "fixing" it

Every documented way to pin an app was tried and measured on this machine
(Windows 11 25H2, build 26200.9168). All of them fail:

* **The `taskbarpin` shell verb does not exist.** Not for `Timi.exe`, not for its
  Start menu shortcut. The string is still in `shell32.dll` (resource 5386,
  "Pin to tas&kbar") but nothing exposes the verb.
* **`TaskbarManager.RequestPinCurrentAppAsync` refuses.** `IsSupported` is true,
  `IsPinningAllowed` is false, and it never shows its consent dialog. Not a
  policy — a full sweep of `HKLM`/`HKCU` `Policies` and `PolicyManager` found no
  pinning value anywhere, and it still refused after the taskbar layout policy
  was removed and `gpupdate` run. It is the long-standing desktop-app
  limitation: the API works from packaged apps only.
* **Writing the `Taskband\Favorites` blob does not stick.** The format decodes
  cleanly — `0x00`, then `[DWORD cb][ITEMIDLIST][flag]` per pin, flag `0x00`
  between entries and `0xFF` at the end — and a hand-appended entry tiles
  correctly, but Explorer rewrites the value on restart and drops the addition.
  Tried with a freshly built PIDL and with one cloned byte-for-byte from the
  neighbouring FanControl pin.
* **Clearing `Taskband` to force a re-read just deletes the pins.** The layout
  policy is applied at *sign-in*, not on an Explorer restart. All four pins
  vanished and did not come back; they were restored from the `.reg` backup.

### Two more things the pin needs

**An identity — and the shortcut is the half that moves.** Taskbar buttons group
by AppUserModelID. `Timi.exe` launches and exits, and the window that appears
belongs to Windows Terminal, so left alone the icon you click and the window you
get are separate buttons.

Ask the shell what the window's id actually is and the fix falls out.
`IApplicationResolver::GetAppIDForWindow` on the live Timi window answers
`C:\Users\Ahmad\Timi\wt\WindowsTerminal.exe` with `explicit = False`: an
unpackaged app that never calls `SetCurrentProcessExplicitAppUserModelID` is
grouped by the **path of its binary**. So the shortcut is given that same string
as its AUMID, and the two are one button.

Both earlier attempts pushed the other way and neither could work. Stamping *the
Store Terminal's* id merged the buttons and pulled in every Terminal window the
user opened. Inventing an id (`Zeino.Timi`) and putting it only on the shortcut
guaranteed the two buttons it was meant to prevent — an explicit AUMID is
per-process and [is not inherited by child
processes](https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/nf-shobjidl_core-setcurrentprocessexplicitappusermodelid),
and a stamped shortcut cannot hand its id across the scheduled task that carries
the elevation. Using the id the window already has needs neither.

It stays exact to Timi because the path is Timi's *own* copy of the Terminal; the
user's own Terminal windows resolve elsewhere and never join this button.

**Pinning by hand produces a shortcut that bypasses Timi entirely — the
installer adopts it.** Right-clicking the running window and choosing "Pin to
taskbar" is the only route to a pin that works here without a sign-in, and what
it creates is named after the binary's `FileDescription` and points *straight at
the binary*:

```
Windows Terminal Host.lnk  ->  C:\Users\Ahmad\Timi\wt\WindowsTerminal.exe
```

That pin never reaches the scheduled task, so it opens Timi **unelevated**, and
everything downstream follows from that (see *Why `elevate` is not set on the
lane profiles* below). `Convert-StrayTerminalPin` in the installer rewrites any
pinned `.lnk` aimed at `Timi\wt\` so its target becomes `Timi.exe` and its
AUMID becomes the window's id — same file, so the pin itself survives, because
the pin list in the registry refers to it by path. Pinning `Timi.lnk` by hand
does not reuse the installed shortcut either: Windows copies it to
`Timi (2).lnk` and pins the copy, which is why every `Timi*.lnk` in that folder
is stamped too.

**Never restart Explorer to "refresh" the taskbar.** On 25H2 that moved the four
existing pins into a `Tombstones` subfolder and rewrote the pin list to point
*inside* it, so they stopped rendering while still appearing in the registry.
Copying the files back does not fix it — the paths in the blob are the problem.
The repair is to rebuild `Favorites` from a pre-tombstone `reg export` (a blob
made of entries Explorer itself wrote is accepted, unlike a hand-built one) and
force-kill Explorer so it cannot save over it. Backups live in this folder.

What does work is the mechanism this machine already pins with. Its pins come
from a policy taskbar layout —
`HKLM\SOFTWARE\Policies\Microsoft\Windows\Explorer\StartLayoutFile` pointing at
`C:\Windows\TaskbarLayoutModification.xml` with `PinListPlacement="Replace"` —
so `Install-Timi.ps1` adds Timi to that list. **The icon appears on the taskbar
at the next sign-in.** Until then it is in Start, and `Timi.exe` works from
anywhere.

---

## Options

```powershell
Install-Timi.ps1 -Force       # rebuild the icon and the exe
Install-Timi.ps1 -AutoStart   # also open Timi at logon, but only when there is
                              # something to restore; a logon with nothing
                              # parked stays quiet
Install-Timi.ps1 -SkipPin     # leave the taskbar alone
Launch-Timi.ps1  -New         # a second Timi window instead of raising the open one
Uninstall-Timi.ps1 [-KeepSettings] [-Full]
```

## When something is wrong

1. `%LOCALAPPDATA%\Timi\launch.log` — the launcher runs hidden from a scheduled
   task, so it would otherwise leave no trace at all. It records every launch
   and the decision it made ("raised existing Timi window", "restoring N
   persisted layout(s)", "reopening orphaned tabs: opus, opus, sonnet"), not
   just failures — a launch that goes *wrong* without failing is the interesting
   case and it produces no error.
2. `%LOCALAPPDATA%\Timi\install.log`, `pin.log` — last provisioning run, last
   pin attempt.
3. `Get-ScheduledTask Timi | Get-ScheduledTaskInfo` — `LastTaskResult` 0 is good.
4. `C:\Users\Ahmad\Scripts\hotkeys-ensure.log` — event-only; the last line is the
   answer for a dead Ctrl+wheel zoom.
5. Lane markers in `%LOCALAPPDATA%\Timi\lanes\` say which lanes were open, which
   Terminal hosted them, and which session each will resume — bearing in mind
   that only a tab opened during a window's first five seconds is offered one.

### A tab that opens but never paints

Check free RAM first. This VM has **8 GB**, and one Claude Code instance is
~300 MB. Three lanes plus Chrome plus Spotify puts the machine at its commit
limit, and a further lane then starts into a machine with nothing left to give:
the shell banner and the lane banner print, `claude` launches, and the TUI takes
minutes to appear or never does. It is not a Timi fault and no Timi setting
fixes it — close a lane or a browser window.
