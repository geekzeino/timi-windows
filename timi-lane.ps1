# timi-lane.ps1 - the process behind one Timi agent tab.
#
# Windows Terminal's own "restore my tabs" (firstWindowPreference:
# persistedWindowLayout) brings a tab back, but per its docs it restores the
# window/pane LAYOUT only - "not any contents of those panes". For a shell tab
# that is the whole story; for an agent tab it is half of one, because the tab
# comes back as a brand-new empty conversation and the work that was in it is
# gone. This wrapper closes that gap: it owns a Claude session id per lane and
# resumes it when - and only when - the terminal died underneath it.
#
# How "died" is told apart from "closed on purpose": the marker written at
# start records the PID *and start time* of the hosting WindowsTerminal.exe.
#   host process gone   -> the terminal crashed, or the box rebooted
#                          -> resume the session
#   host still alive    -> the user closed that tab themselves
#                          -> start a fresh session
# The start time is part of the check because Windows recycles PIDs; a stale
# marker pointing at a reused PID would otherwise read as "still open" and
# silently drop the resume.
#
# Session identity is ours, not `claude --continue`'s: --continue resumes the
# most recent conversation IN THIS DIRECTORY, and all three lanes run in
# %USERPROFILE%, so after a crash it would hand the Sonnet tab whichever lane
# happened to speak last. --session-id on the way in and --resume <that id> on
# the way back keeps each lane on its own thread.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('opus', 'sonnet', 'fable')]
    [string]$Lane
)

$ErrorActionPreference = 'Stop'

$LANES = @{
    opus   = @{ Model = 'opus';   Label = 'Opus';   Glyph = [char]0x2733 }
    sonnet = @{ Model = 'sonnet'; Label = 'Sonnet'; Glyph = [char]0x2756 }
    fable  = @{ Model = 'fable';  Label = 'Fable';  Glyph = [char]0x25B2 }
}
$spec     = $LANES[$Lane]
$stateDir = Join-Path $env:LOCALAPPDATA 'Timi\lanes'
$marker   = Join-Path $stateDir "$Lane.json"

# --- helpers -------------------------------------------------------------

# Walk up the process tree to the WindowsTerminal.exe hosting this tab.
# Depth is bounded: the real chain is powershell -> OpenConsole -> terminal,
# and an unbounded walk would hang on a PID loop.
function Get-HostTerminal {
    $walk = $PID
    for ($hop = 0; $hop -lt 6; $hop++) {
        $p = Get-CimInstance Win32_Process -Filter "ProcessId = $walk" -ErrorAction SilentlyContinue
        if (-not $p) { return $null }
        if ($p.Name -eq 'WindowsTerminal.exe') {
            $proc = Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue
            if (-not $proc) { return $null }
            return [pscustomobject]@{
                Pid   = [int]$p.ProcessId
                Start = $proc.StartTime.ToString('o')
            }
        }
        if (-not $p.ParentProcessId -or $p.ParentProcessId -eq $walk) { return $null }
        $walk = [int]$p.ParentProcessId
    }
    return $null
}

function Test-HostAlive {
    param($MarkerPid, $MarkerStart)
    # A marker with no host recorded means the lane once started outside a
    # Terminal window and we never knew who to watch. "Unknown" must read as
    # ALIVE here, not as dead: reading it as dead would make every such start
    # look like a crash and silently resume an old conversation.
    if (-not $MarkerPid) { return $true }
    $p = Get-Process -Id $MarkerPid -ErrorAction SilentlyContinue
    if (-not $p -or $p.ProcessName -ne 'WindowsTerminal') { return $false }
    # PID reuse guard - same number, different process.
    return ($p.StartTime.ToString('o') -eq $MarkerStart)
}

# Claude Code stores a directory's transcripts under a slug of its full path.
function Get-SessionFile {
    param([string]$SessionId)
    $slug = (Get-Location).Path -replace '[^A-Za-z0-9]', '-'
    return (Join-Path $env:USERPROFILE ".claude\projects\$slug\$SessionId.jsonl")
}

# Claude Code reads its TUI theme from globalConfig.theme in ~/.claude.json
# (verified in the binary: themeSetting comes off the global config object).
# Windows Terminal already follows the OS light/dark switch on its own;
# without this the terminal would go light while Claude Code kept painting a
# dark-background palette on top of it.
#
# The edit is a targeted text splice, NOT a parse-and-rewrite: that file also
# holds the OAuth account, every project's history and several caches, and a
# ConvertTo-Json round-trip of it is a good way to lose one of those to a
# depth limit. Writes only happen when the value actually changes, so on a
# normal launch this touches nothing.
function Sync-ClaudeTheme {
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    $light = $true
    try {
        $v = (Get-ItemProperty -Path $key -Name AppsUseLightTheme -ErrorAction Stop).AppsUseLightTheme
        $light = ($v -eq 1)
    } catch { return }   # key absent on some SKUs - leave the theme alone
    $want = if ($light) { 'light' } else { 'dark' }

    $cfg = Join-Path $env:USERPROFILE '.claude.json'
    if (-not (Test-Path $cfg)) { return }

    # One writer at a time: all three lanes start within the same second.
    $mutex = New-Object System.Threading.Mutex($false, 'Global\TimiThemeSync')
    if (-not $mutex.WaitOne(3000)) { return }
    try {
        $raw = [System.IO.File]::ReadAllText($cfg)
        $m   = [regex]::Match($raw, '"theme"\s*:\s*"[^"]*"')
        if ($m.Success) {
            if ($m.Value -match ('"' + $want + '"$')) { return }   # already correct
            $updated = $raw.Remove($m.Index, $m.Length).Insert($m.Index, ('"theme": "' + $want + '"'))
        } else {
            $brace = $raw.IndexOf('{')
            if ($brace -lt 0) { return }
            $updated = $raw.Insert($brace + 1, ('"theme": "' + $want + '",'))
        }
        try { $null = $updated | ConvertFrom-Json } catch { return }  # never write unparseable json
        $bak = "$cfg.timi-bak"
        if (-not (Test-Path $bak)) { [System.IO.File]::Copy($cfg, $bak) }
        [System.IO.File]::WriteAllText($cfg, $updated, (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        # A theme mismatch is cosmetic; never take the tab down over it.
    } finally {
        $mutex.ReleaseMutex(); $mutex.Dispose()
    }
}

# --- decide: resume or fresh --------------------------------------------

New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
$hostTerm = Get-HostTerminal

$resumeId = $null
if (Test-Path $marker) {
    try {
        $old = Get-Content $marker -Raw | ConvertFrom-Json
        if (-not (Test-HostAlive -MarkerPid $old.wtPid -MarkerStart $old.wtStart)) {
            if ($old.sessionId -and (Test-Path (Get-SessionFile $old.sessionId))) {
                $resumeId = $old.sessionId
            }
        }
    } catch {
        Remove-Item $marker -Force -ErrorAction SilentlyContinue
    }
}

$sessionId = if ($resumeId) { $resumeId } else { [guid]::NewGuid().ToString() }

@{
    lane      = $Lane
    sessionId = $sessionId
    wtPid     = if ($hostTerm) { $hostTerm.Pid }   else { 0 }
    wtStart   = if ($hostTerm) { $hostTerm.Start } else { '' }
    shellPid  = $PID
    opened    = (Get-Date).ToString('o')
} | ConvertTo-Json | Set-Content -Path $marker -Encoding UTF8

Sync-ClaudeTheme

# --- run -----------------------------------------------------------------

$short = $sessionId.Substring(0, 8)
if ($resumeId) {
    Write-Host ("{0} Timi {1} - restoring session {2} (the terminal went away, this tab did not)" -f $spec.Glyph, $spec.Label, $short) -ForegroundColor DarkYellow
} else {
    Write-Host ("{0} Timi {1} - new session {2}" -f $spec.Glyph, $spec.Label, $short) -ForegroundColor DarkGray
}

$common = @('--model', $spec.Model, '--effort', 'xhigh')
try {
    if ($resumeId) {
        $t0 = Get-Date
        & claude @common '--resume' $resumeId
        # A transcript that claude itself refuses (corrupt, or written by a
        # newer build) fails in about a second. Falling back keeps the tab
        # usable instead of parking it on an error.
        if ($LASTEXITCODE -ne 0 -and ((Get-Date) - $t0).TotalSeconds -lt 20) {
            Write-Host "  resume failed - starting a fresh session instead" -ForegroundColor DarkYellow
            & claude @common '--session-id' ([guid]::NewGuid().ToString())
        }
    } else {
        & claude @common '--session-id' $sessionId
    }
} finally {
    # Reached only when claude returned on its own. A crash, a reboot or a
    # closed window never gets here - which is exactly what leaves the marker
    # behind for the next launch to find.
    Remove-Item $marker -Force -ErrorAction SilentlyContinue
}
