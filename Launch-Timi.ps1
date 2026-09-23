# Launch-Timi.ps1 - the Windows stand-in for /home/zeino/.local/bin/timi.
#
# Timi (Linux) is a single GTK window that is itself the terminal host: one tab
# per agent session, drawn by the app's own tab strip. Windows Terminal already
# IS a native, robust multi-tab terminal host, so this port does not reimplement
# that widget - it hosts the lanes inside Windows Terminal and supplies the
# things Windows Terminal has no opinion about: which lanes open, that they come
# back after a crash, and that they come back ELEVATED.
#
# What this script owns, in order:
#
#   1. Elevation. Timi runs as administrator so the agent inside it is not
#      stopped by a permission wall halfway through a task. The lift goes
#      through the "Timi" scheduled task (RunLevel Highest), which is what makes
#      it promptless - a shortcut with the "run as administrator" bit would put
#      a UAC dialog in front of every single launch.
#   2. Drive maps. An elevated logon session does not inherit the drive letters
#      mapped by the unelevated one (UAC's split token), so F:/H:/L:/Y:/Z: are
#      re-asserted here. EnableLinkedConnections in the registry fixes this
#      permanently, but only from the next boot, and only for maps that already
#      exist - this covers the first launch after a fresh logon either way.
#   3. Single window. Clicking a taskbar icon for an app that is already open
#      should raise it, not open a second copy. This also protects the restore
#      path: launching a second window while a restored one is up would replay
#      the same saved layout twice.
#   4. Restore, then seed. If Windows Terminal has a persisted layout, hand it
#      nothing and let it restore. If it does not but Timi's own lane markers
#      say lanes were open when the terminal died, seed exactly those. Only
#      with neither does it fall back to the default three lanes.
#
# Every relaunch used to open a FRESH window ("-w new" with three hard-coded
# tabs). That is exactly the thing that made restore impossible: command-line
# arguments suppress firstWindowPreference, so a launcher that always passes
# tabs can never get its tabs back.

[CmdletBinding()]
param(
    # Skip the raise-the-existing-window step and open another Timi window.
    [switch]$New,
    # Internal: set by the scheduled task so the elevated pass does not try to
    # elevate itself again.
    [switch]$Elevated
)

$ErrorActionPreference = 'Stop'

# This script normally runs hidden, from a scheduled task. Without this, a
# failure is a launcher that does nothing at all and leaves no trace - the task
# just records result 1 and the window never appears.
$TIMI_LOG = Join-Path $env:LOCALAPPDATA 'Timi\launch.log'

# Errors were the only thing this file ever recorded, and that turned out to be
# the wrong half. A launch that goes WRONG without failing - raising a window
# the user cannot see, seeding three fresh lanes over three saved ones - leaves
# no error at all, and the script runs hidden from a scheduled task, so there is
# nothing else to read afterwards. Every decision is written now; the file is
# trimmed rather than rotated because nobody will ever come looking for the
# hundredth-last launch.
function Write-TimiLog {
    param([string]$Message)
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path $TIMI_LOG -Parent) | Out-Null
        if ((Test-Path $TIMI_LOG) -and (Get-Item $TIMI_LOG).Length -gt 128KB) {
            $keep = Get-Content $TIMI_LOG -Tail 200
            Set-Content -Path $TIMI_LOG -Value $keep -Encoding UTF8
        }
        "{0}  {1}" -f (Get-Date -Format 's'), $Message | Out-File $TIMI_LOG -Append -Encoding UTF8
    } catch { }
}

trap {
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path $TIMI_LOG -Parent) | Out-Null
        "{0}  {1}`r`n    at {2}" -f (Get-Date -Format 's'), $_.Exception.Message,
            $_.InvocationInfo.PositionMessage | Out-File $TIMI_LOG -Append -Encoding UTF8
    } catch { }
    exit 1
}

$TIMI_DIR   = $PSScriptRoot
$LANE_STATE = Join-Path $env:LOCALAPPDATA 'Timi\lanes'

# Timi runs its OWN Windows Terminal, not the one in the Start menu. The
# unpackaged build under Timi\wt has a `.portable` marker next to the exe,
# which moves both its settings and its saved window layouts into Timi\wt\
# settings - so the lanes, the "+" button, the font bindings and the tab
# restore are Timi's alone. Sharing the Store install put nine agent profiles
# in the user's own Terminal, made its "+" open an agent, and made a plain `wt`
# restore Timi's tabs; portable mode is the only supported way to give one of
# the two its own settings file, and the Store build ignores the marker.
$WT_DIR     = Join-Path $TIMI_DIR 'wt'
$WT_EXE     = Join-Path $WT_DIR 'wt.exe'
$WT_STATE   = Join-Path $WT_DIR 'settings'

# Nothing here sets a taskbar identity, and nothing needs to. Measured with the
# shell's own IApplicationResolver on 2026-08-20, this window reports
# AppID = C:\Users\Ahmad\Timi\wt\WindowsTerminal.exe with explicit = False: an
# unpackaged app that sets no explicit id is grouped by the PATH of its binary.
# The earlier attempts went the other way round and both failed - a process's
# explicit id is not inherited by the processes it starts, and a shortcut's id
# cannot reach across the scheduled task that carries the elevation.
#
# So the shortcut is what moves. Install-Timi.ps1 stamps that same path onto the
# pinned .lnk as its AppUserModelID, and the pin and the window become ONE
# button. It stays exact to Timi because the path is Timi's own copy of the
# Terminal; the user's own Terminal windows resolve to a different id, which is
# what borrowing the Store Terminal's id got wrong before.

# Profile GUIDs come from the generated lanes.json - the ONE source of
# provider/GUID truth in this tree - so a regeneration never has to hand-edit
# this file. They are what gets passed to wt.exe rather than the profile NAMES,
# because wt.exe re-tokenizes its own raw command line - that is how its ";"
# syntax works at all - and a name with a space in it ("Timi - Opus") does not
# survive the trip: wt reads it as two tokens and fails with
# "[error 2147942402] when launching '- Fable'". GUIDs have no whitespace.
$LANES_JSON = Join-Path $PSScriptRoot 'lanes.json'
$LANE_MANIFEST = Get-Content $LANES_JSON -Raw | ConvertFrom-Json
$LANE_GUIDS = [ordered]@{}
foreach ($laneEntry in ($LANE_MANIFEST.providers.PSObject.Properties | Where-Object { $_.Name -in @('opus', 'sonnet', 'fable', 'gemini') })) {
    $LANE_GUIDS[$laneEntry.Name] = $laneEntry.Value.guid
}
$DEFAULT_LANES = @('opus', 'sonnet', 'fable')

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Resolve-Wt {
    # Timi's private copy only. There is deliberately no fall back to the Store
    # `wt.exe` on PATH: that one reads the user's settings, so a "helpful"
    # fallback would silently undo the split and open a window with none of the
    # lanes in it. The wt.exe beside WindowsTerminal.exe is the documented
    # entry point for the `-w new ; nt -p {guid}` command line; portable mode
    # keys off the marker file next to them, so either exe lands in the same
    # settings folder.
    if (Test-Path $WT_EXE) { return $WT_EXE }
    return $null
}

Write-TimiLog ("launch: admin={0} new={1} pid={2}" -f (Test-Admin), [bool]$New, $PID)

# --- 1. elevation --------------------------------------------------------

if (-not (Test-Admin) -and -not $Elevated) {
    $task = schtasks.exe /Query /TN Timi 2>$null
    if ($LASTEXITCODE -eq 0) {
        # The task carries RunLevel Highest, so this lifts without a prompt.
        schtasks.exe /Run /TN Timi | Out-Null
        exit 0
    }
    # No task registered (Install-Timi.ps1 never ran, or it was removed):
    # fall back to a normal UAC prompt rather than silently running unelevated.
    $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
                '-File', $PSCommandPath, '-Elevated')
    if ($New) { $psArgs += '-New' }
    Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs -Verb RunAs | Out-Null
    exit 0
}

# --- 1b. finish setup if it was interrupted ------------------------------
# Install-Timi.ps1 needs administrator for three things: the scheduled task,
# the taskbar-pinning policy and the HKLM drive-map value. If its UAC prompt
# was ever declined - or a later change needs re-applying - a marker file asks
# the next elevated launch to finish the job. That costs no prompt at all,
# because this run is already elevated through the task, and it is the same
# trust boundary either way: whoever can write the marker can already edit
# this script, which the task runs elevated.
$pending = Join-Path $TIMI_DIR '.provision-pending'
if (Test-Path $pending) {
    Remove-Item $pending -Force -ErrorAction SilentlyContinue
    $installLog = Join-Path $env:LOCALAPPDATA 'Timi\install.log'
    New-Item -ItemType Directory -Force -Path (Split-Path $installLog -Parent) | Out-Null
    try {
        & (Join-Path $TIMI_DIR 'Install-Timi.ps1') *>&1 | Out-File $installLog -Encoding UTF8
    } catch {
        $_ | Out-File $installLog -Append -Encoding UTF8
    }
}

# --- 2. drive maps -------------------------------------------------------

$mapper = Join-Path $TIMI_DIR 'map-drives.cmd'
if (Test-Path $mapper) {
    # Already-mapped letters make `net use` return "local device name already
    # in use"; map-drives.cmd swallows that itself, so this stays quiet.
    #
    # Wrapped because $ErrorActionPreference is Stop and the trap above exits:
    # ANY stderr out of this step killed the launcher before a window existed,
    # and the scheduled task just recorded result 1. That is not a theory - it
    # is what "Timi is not opening" was on 2026-08-20, when the >nul redirects
    # in map-drives.cmd had been rewritten as >/dev/null and cmd.exe read them
    # as a missing path. Drive letters are a convenience; the window is the
    # product, and a missing H: must never be the reason it does not appear.
    try {
        & cmd.exe /c $mapper 2>$null | Out-Null
    } catch {
        Write-TimiLog "drive maps failed (continuing): $($_.Exception.Message)"
    }
}

# --- 3. single window ----------------------------------------------------

Add-Type -Namespace Timi -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
[DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
[DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
[DllImport("advapi32.dll", SetLastError=true)] public static extern bool OpenProcessToken(IntPtr proc, uint access, out IntPtr token);
[DllImport("advapi32.dll", SetLastError=true)] public static extern bool GetTokenInformation(IntPtr token, int cls, out uint info, int len, out int ret);
'@ -ErrorAction SilentlyContinue

function Test-ProcessElevated {
    param([int]$ProcessId)
    try {
        $h = [Timi.Win]::OpenProcess(0x1000, $false, $ProcessId)   # QUERY_LIMITED_INFORMATION
        if ($h -eq [IntPtr]::Zero) { return $false }
        try {
            $tok = [IntPtr]::Zero
            if (-not [Timi.Win]::OpenProcessToken($h, 8, [ref]$tok)) { return $false }   # TOKEN_QUERY
            try {
                $elevated = 0; $len = 0
                if ([Timi.Win]::GetTokenInformation($tok, 20, [ref]$elevated, 4, [ref]$len)) {
                    return ($elevated -ne 0)                                             # TokenElevation
                }
                return $false
            } finally { [void][Timi.Win]::CloseHandle($tok) }
        } finally { [void][Timi.Win]::CloseHandle($h) }
    } catch { return $false }
}

function Get-TimiTerminals {
    # "Is Timi already open?" is now exactly "is one of MY OWN Terminal binaries
    # running?" - Timi has its own copy under Timi\wt, so the executable path is
    # an identity no other window on the machine can borrow.
    #
    # The lane markers used to answer this, and they were wrong in the one case
    # that matters. TimiLane deletes its marker when the agent exits, so a Timi
    # window sitting on the plain shells it leaves behind looked CLOSED, and the
    # next click on the taskbar icon opened a second window beside it. Matching
    # on the "Administrator: " window title was the attempt before that, and it
    # was too loose in the other direction: every elevated Terminal on the box
    # looked like Timi.
    #
    # Elevation is part of the identity, not a detail. This launcher runs
    # elevated; an UNELEVATED Timi window must not count as "already open",
    # because raising it instead of opening the elevated one is exactly how a
    # window that never got administrator becomes permanent.
    $wantElevated = Test-Admin
    $found = @()
    foreach ($p in Get-CimInstance Win32_Process -Filter "Name='WindowsTerminal.exe'" -ErrorAction SilentlyContinue) {
        if (-not $p.ExecutablePath) { continue }
        if (-not $p.ExecutablePath.StartsWith($WT_DIR, [StringComparison]::OrdinalIgnoreCase)) { continue }
        if ((Test-ProcessElevated -ProcessId $p.ProcessId) -ne $wantElevated) { continue }
        $found += [int]$p.ProcessId
    }
    return $found
}

function Show-ExistingTimi {
    $timiPids = Get-TimiTerminals
    if (-not $timiPids) {
        Write-TimiLog 'no Timi terminal running at this elevation'
        return $false
    }
    $wins = Get-Process WindowsTerminal -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowHandle -ne 0 -and $timiPids -contains $_.Id } |
            Sort-Object StartTime -Descending
    foreach ($w in $wins) {
        $h = $w.MainWindowHandle
        if ([Timi.Win]::IsIconic($h)) { [void][Timi.Win]::ShowWindow($h, 9) }  # SW_RESTORE
        if ([Timi.Win]::SetForegroundWindow($h)) {
            Write-TimiLog "raised existing Timi window (pid $($w.Id))"
            return $true
        }
        # A process started by Task Scheduler did not get the last input event,
        # so Windows can refuse it the foreground. AppActivate goes through the
        # shell, which is allowed to hand it over.
        try {
            (New-Object -ComObject WScript.Shell).AppActivate($w.Id) | Out-Null
            Write-TimiLog "raised existing Timi window via AppActivate (pid $($w.Id))"
            return $true
        } catch { }
    }
    # Running, but nothing raiseable. Two very different situations, and telling
    # them apart matters more than either case: a Terminal that started a second
    # ago has simply not shown its window yet, and opening another one now is how
    # an impatient double click becomes two windows. A Terminal that has been up
    # for a minute with no window is stuck, and treating THAT as "already open"
    # would mean the taskbar icon does nothing at all, for good - the worst
    # failure this launcher has, because it looks exactly like a dead shortcut.
    $youngest = Get-Process WindowsTerminal -ErrorAction SilentlyContinue |
                Where-Object { $timiPids -contains $_.Id } |
                Sort-Object StartTime -Descending | Select-Object -First 1
    if ($youngest -and ((Get-Date) - $youngest.StartTime).TotalSeconds -lt 30) {
        Write-TimiLog "Timi terminal $($youngest.Id) is $([int]((Get-Date) - $youngest.StartTime).TotalSeconds)s old with no window yet - waiting, not opening a second"
        return $true
    }
    Write-TimiLog "Timi terminal $($timiPids -join ',') is running but has no window to raise - opening one"
    return $false
}

if (-not $New) {
    if (Show-ExistingTimi) { exit 0 }
}

# --- 4. restore, then seed ----------------------------------------------

function Get-PersistedLayoutCount {
    # An elevated Terminal keeps its window state in elevated-state.json and an
    # unelevated one in state.json, and it only ever RESTORES from its own.
    # Reading both looks harmless and is not: this launcher runs elevated, saw
    # the layout the user's ordinary Terminal window had saved, launched
    # `wt` with no arguments expecting a restore, and got a bare default-profile
    # window instead - because the elevated state file was empty.
    $name = if (Test-Admin) { 'elevated-state.json' } else { 'state.json' }
    $path = Join-Path $WT_STATE $name
    if (-not (Test-Path $path)) { return 0 }
    try {
        $st = Get-Content $path -Raw | ConvertFrom-Json
        if (-not $st.persistedWindowLayouts) { return 0 }
        return @($st.persistedWindowLayouts).Count
    } catch { return 0 }
}

function Get-LaneConfigDir {
    # Where Claude Code keeps this lane's transcripts. A lane billing a Timi
    # account runs with CLAUDE_CONFIG_DIR pointed at ~\.claude-cfg\<account>
    # and writes everything under THAT, so reading ~\.claude regardless sees
    # only the conversations from before the account was added. TimiLane.cs
    # resolves the account exactly this way - the per-lane file first, then the
    # global one, and only if that folder actually holds credentials - and the
    # two have to agree: this function deletes the markers that one is about to
    # claim.
    param([string]$Lane)
    $dir    = Join-Path $env:LOCALAPPDATA 'Timi'
    $chosen = $null
    foreach ($f in @((Join-Path $dir "account.$Lane"), (Join-Path $dir 'account'))) {
        if (Test-Path $f) { $chosen = (Get-Content $f -Raw).Trim(); break }
    }
    if ($chosen) {
        $acct = Join-Path $env:USERPROFILE ".claude-cfg\$chosen"
        if (Test-Path (Join-Path $acct '.credentials.json')) { return $acct }
    }
    return (Join-Path $env:USERPROFILE '.claude')
}

function Get-CrashedLanes {
    # A marker whose hosting WindowsTerminal.exe is gone is a TAB that was open
    # when the terminal died - one marker per tab, so a lane the user had open
    # twice comes back twice. See TimiLane.cs for why the start time is compared
    # as well as the PID, and for the claim that pairs each seeded tab with
    # exactly one of these markers.
    if (-not (Test-Path $LANE_STATE)) { return @() }
    # The transcript folder for the lanes' working directory. TimiLane derives
    # the same one from its own CWD; the lanes all start in %USERPROFILE%,
    # which is what makes it computable from here too. The config dir it hangs
    # off is per lane, so it is resolved inside the loop.
    $slug = [regex]::Replace($env:USERPROFILE, '[^A-Za-z0-9]', '-')
    $found = @()
    foreach ($f in Get-ChildItem -Path $LANE_STATE -Filter '*.json' -ErrorAction SilentlyContinue) {
        try {
            $m = Get-Content $f.FullName -Raw | ConvertFrom-Json
            if (-not $LANE_GUIDS.Contains($m.lane)) { continue }
            $p = Get-Process -Id $m.wtPid -ErrorAction SilentlyContinue
            $alive = $p -and $p.ProcessName -eq 'WindowsTerminal' -and
                     $p.StartTime.ToString('o') -eq $m.wtStart
            if ($alive) { continue }
            # A tab closed before it ever said anything leaves a marker naming a
            # transcript that was never written. Seeding a tab for it is not just
            # wasted: that empty marker is then what the next lane claims,
            # instead of the one holding the real conversation.
            $sessions = Join-Path (Get-LaneConfigDir $m.lane) "projects\$slug"
            if (-not (Test-Path (Join-Path $sessions ($m.sessionId + '.jsonl')))) {
                Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
                Write-TimiLog "dropped empty $($m.lane) marker $($f.Name) (no transcript on disk)"
                continue
            }
            $found += [pscustomobject]@{ Lane = $m.lane; Opened = $m.opened }
        } catch { }
    }
    return @($found | Sort-Object Opened | Select-Object -ExpandProperty Lane)
}

$wt = Resolve-Wt
if (-not $wt) {
    Write-Error ("Timi: its own Windows Terminal is missing from $WT_DIR. Unzip the unpackaged " +
                 "release there and keep the .portable file next to the exe - Install-Timi.ps1 checks both.")
    exit 1
}

$layouts = Get-PersistedLayoutCount
if ($New -and $layouts -gt 0) {
    # -New means "open ANOTHER Timi", and the saved layout is not a record of a
    # past session while one is running: the Terminal keeps it current for the
    # windows that are open right now. Restoring it here duplicates the tabs of
    # the window already on screen into the new one - measured 2026-08-20, where
    # -New produced a second window holding a copy of this window's Opus tab.
    # (Both windows live in the same WindowsTerminal.exe process, which is why
    # that showed up as a new lane with no new process behind it.)
    Write-TimiLog "-New: ignoring $layouts live layout(s) and seeding instead"
    $layouts = 0
}
if ($layouts -gt 0) {
    # No arguments at all: anything on the command line makes the Terminal skip
    # firstWindowPreference and open a plain new window instead of restoring.
    Write-TimiLog "restoring $layouts persisted layout(s) - wt.exe with no arguments"
    Start-Process -FilePath $wt
    exit 0
}

$lanes = Get-CrashedLanes
if ($lanes.Count -eq 0) {
    Write-TimiLog 'no persisted layout and no orphaned tabs - seeding the default lanes'
    $lanes = $DEFAULT_LANES
} else {
    Write-TimiLog "no persisted layout - reopening orphaned tabs: $($lanes -join ', ')"
}

$wtArgs = @('-w', 'new')
$first = $true
foreach ($lane in $lanes) {
    if (-not $first) { $wtArgs += ';' }
    $wtArgs += @('nt', '-p', $LANE_GUIDS[$lane])
    $first = $false
}
Start-Process -FilePath $wt -ArgumentList $wtArgs
Write-TimiLog ("started wt.exe " + ($wtArgs -join ' '))
