# Install-Timi.ps1 - provisions Timi on this machine. Idempotent; safe to re-run.
#
# Everything here is a one-time side effect that lives outside the Timi folder:
# a scheduled task, two shortcuts, a taskbar pin, one HKLM value and one line in
# the hotkey keepalive. Each step says what it undoes, and Uninstall-Timi.ps1
# reverses the lot.
#
#   -Force      rebuild the icon and the exe even if they already exist
#   -AutoStart  also open Timi at logon when there is something to restore
#               (off by default: bringing an elevated terminal up on every
#               logon is a bigger change than "keep my tabs", and restore works
#               the same whenever the launcher is next clicked)
#   -SkipPin    leave the taskbar alone

[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$AutoStart,
    [switch]$SkipPin
)

$ErrorActionPreference = 'Stop'
$TIMI = $PSScriptRoot

function Step($msg) { Write-Host "  $msg" -ForegroundColor Gray }
function Ok($msg)   { Write-Host "  [ok] $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "  [--] $msg" -ForegroundColor Yellow }

# --- 0. elevation --------------------------------------------------------
# Needed for: a scheduled task with RunLevel Highest, and the HKLM value.
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Timi: installer needs administrator - re-launching with a UAC prompt." -ForegroundColor Yellow
    $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', $PSCommandPath)
    if ($Force)     { $psArgs += '-Force' }
    if ($AutoStart) { $psArgs += '-AutoStart' }
    if ($SkipPin)   { $psArgs += '-SkipPin' }
    Start-Process powershell.exe -ArgumentList $psArgs -Verb RunAs
    exit 0
}

Write-Host "`nTimi setup" -ForegroundColor Cyan

# --- 1. icon -------------------------------------------------------------
$ico = Join-Path $TIMI 'Timi.ico'
if ($Force -or -not (Test-Path $ico)) {
    & (Join-Path $TIMI 'Make-TimiIcon.ps1') -OutPath $ico | Out-Null
    Ok "icon  $ico"
} else { Step "icon  already present" }

# --- 2. launcher exe -----------------------------------------------------
$exe = Join-Path $TIMI 'Timi.exe'
$src = Join-Path $TIMI 'Timi.cs'
if ($Force -or -not (Test-Path $exe) -or ((Get-Item $src).LastWriteTime -gt (Get-Item $exe).LastWriteTime)) {
    # csc.exe from the in-box .NET Framework: no SDK, no NuGet, no project file.
    $csc = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path $csc)) { throw "Timi: csc.exe not found at $csc" }
    & $csc /nologo /target:winexe /platform:anycpu /optimize+ `
           /win32icon:$ico /reference:System.Windows.Forms.dll `
           /out:$exe $src
    if ($LASTEXITCODE -ne 0) { throw "Timi: compiling Timi.exe failed" }
    Ok "exe   $exe"
} else { Step "exe   already current" }

# --- 2b. lane launcher exe ----------------------------------------------
# The process a Timi tab actually starts. Console exe, not winexe: it inherits
# the tab's console and hands it to claude.exe. /codepage:65001 because the
# source carries the lane glyphs literally and csc would otherwise read them
# through the ANSI codepage.
$laneExe = Join-Path $TIMI 'TimiLane.exe'
$laneSrc = Join-Path $TIMI 'TimiLane.cs'
if ($Force -or -not (Test-Path $laneExe) -or ((Get-Item $laneSrc).LastWriteTime -gt (Get-Item $laneExe).LastWriteTime)) {
    $csc = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path $csc)) { throw "Timi: csc.exe not found at $csc" }
    & $csc /nologo /target:exe /platform:anycpu /optimize+ /codepage:65001 `
           /win32icon:$ico /out:$laneExe $laneSrc
    if ($LASTEXITCODE -ne 0) { throw "Timi: compiling TimiLane.exe failed" }
    Ok "lane  $laneExe"
} else { Step "lane  already current" }

# --- 3. Windows Terminal settings ---------------------------------------
# Timi's own Terminal, not the user's. Portable mode ONLY works on the
# unpackaged (ZIP) build - the Store install ignores the `.portable` marker -
# so this is a real second copy of the Terminal, and without it the patcher
# would have nowhere to write and Launch-Timi.ps1 nothing to start.
$wtExe = Join-Path $TIMI 'wt\WindowsTerminal.exe'
if (-not (Test-Path $wtExe)) {
    $wtDir = Join-Path $TIMI 'wt'
    if (-not (Test-Path $wtDir)) { New-Item -ItemType Directory -Path $wtDir -Force | Out-Null }
    Write-Host "wt\WindowsTerminal.exe missing, downloading portable Windows Terminal..." -ForegroundColor Yellow
    $zipPath = Join-Path $TIMI 'wt-portable.zip'
    $wtUrl = 'https://github.com/microsoft/terminal/releases/download/v1.22.3232.0/Microsoft.WindowsTerminal_1.22.3232.0_x64.zip'
    try {
        Invoke-WebRequest -Uri $wtUrl -OutFile $zipPath -UseBasicParsing
        Expand-Archive -Path $zipPath -DestinationPath $wtDir -Force
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
        Ok "wt    Windows Terminal downloaded and unzipped"
    } catch {
        throw ("Timi: {0} is missing and download failed ($($_.Exception.Message)). Unzip unpackaged Windows Terminal release into {1} and place .portable marker." -f $wtExe, $wtDir)
    }
}
if (-not (Test-Path (Join-Path $TIMI 'wt\.portable'))) {
    New-Item -ItemType File -Path (Join-Path $TIMI 'wt\.portable') -Force | Out-Null
    Ok "wt    .portable marker restored"
}

# The window wears an icon that lives INSIDE that binary, so a freshly unzipped
# Terminal arrives wearing Microsoft's - identical to the user's own Terminal in
# the taskbar and in Alt+Tab. Re-stamp it here rather than only at first install,
# because that is exactly when it is lost. Idempotent; see Patch-WtIcon.ps1.
try { & (Join-Path $TIMI 'Patch-WtIcon.ps1') | ForEach-Object { Step "wt    $_" } }
catch { Warn "wt    icon not stamped: $($_.Exception.Message)" }   # cosmetic - never block the install

$py = Get-Command py -ErrorAction SilentlyContinue
if (-not $py) { $py = Get-Command python -ErrorAction SilentlyContinue }
if (-not $py) {
    foreach ($cand in @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python314\python.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312\python.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python311\python.exe'),
        'C:\Python312\python.exe',
        'C:\Python311\python.exe'
    )) {
        if (Test-Path $cand) { $py = [pscustomobject]@{ Source = $cand }; break }
    }
}
if ($py) {
    & $py.Source (Join-Path $TIMI 'Patch-WtSettings.py') | ForEach-Object { Step $_ }
} else {
    $settingsDir = Join-Path $TIMI 'wt\settings'
    if (-not (Test-Path $settingsDir)) { New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null }
    $dest = Join-Path $settingsDir 'settings.json'
    $srcSettings = Join-Path $TIMI 'wt-settings.json'
    if (Test-Path $srcSettings) {
        $content = Get-Content $srcSettings -Raw
        $escapedTimi = ($TIMI -replace '\\', '\\')
        $content = $content -replace '"C:\\\\Users\\\\Ahmad\\\\Timi', ('"' + $escapedTimi)
        Set-Content -Path $dest -Value $content -Encoding UTF8
        Ok "wt    settings seeded from pre-patched template"
    } else {
        throw "Timi: python is needed to patch the Windows Terminal settings"
    }
}

# Shard picker: deploy the picker seam and its data beside the lane exe so the
# account system ships on every install (contract: SHARE-CONTRACT.json).
foreach ($f in @('Timi-Shard.ps1','shards.json')) {
  $src = Join-Path $TIMI $f
  if (Test-Path $src) { Ok "shard  $f present" } else { Warn "shard  $f MISSING from $TIMI" }
}

# Antigravity CLI (agy) for Gemini lane
if (-not (Get-Command agy -ErrorAction SilentlyContinue) -and -not (Test-Path "$env:LOCALAPPDATA\agy\bin\agy.exe")) {
    Write-Host "Installing Antigravity CLI (agy) for Gemini..." -ForegroundColor Cyan
    try {
        irm https://antigravity.google/cli/install.ps1 | iex
        Ok "agy    Antigravity CLI installed"
    } catch {
        Warn "agy    install failed: $($_.Exception.Message)"
    }
}

# --- 4. scheduled task ---------------------------------------------------
# This is what makes elevation promptless. A shortcut with the "run as
# administrator" bit set would put a UAC dialog in front of every launch;
# Task Scheduler carries the elevation itself, and /Run needs no consent.
$taskArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $TIMI 'Launch-Timi.ps1')`""
$action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $taskArgs
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
                                        -LogonType Interactive -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                                          -StartWhenAvailable -MultipleInstances Parallel `
                                          -ExecutionTimeLimit ([TimeSpan]::Zero)
$triggers = @()
if ($AutoStart) {
    # 40s in: the drive maps and the network need to exist first, and the
    # launcher only opens a window when there is a layout or a lane marker to
    # restore, so a logon with nothing parked stays quiet.
    $t = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $t.Delay = 'PT40S'
    $triggers += $t
}
$register = @{
    TaskName    = 'Timi'
    Action      = $action
    Principal   = $principal
    Settings    = $settings
    Description = 'Launches Timi (elevated Windows Terminal agent shell). Created by Install-Timi.ps1.'
    Force       = $true
}
if ($triggers.Count) { $register.Trigger = $triggers }
Register-ScheduledTask @register | Out-Null
Ok ("task  Timi (elevated{0})" -f $(if ($AutoStart) { ', opens at logon when there is something to restore' } else { '' }))

# --- 5. shortcuts --------------------------------------------------------
function Get-TerminalAumid {
    # Taskbar buttons group by AppUserModelID. Timi.exe exits immediately and
    # the window that appears belongs to Windows Terminal, so unless the
    # shortcut and the window agree on an id the taskbar shows two buttons: the
    # pinned icon, and a separate one for the window it opened.
    #
    # This is the id the window ACTUALLY has, not a name invented for it. An
    # unpackaged app that never calls SetCurrentProcessExplicitAppUserModelID is
    # grouped by the path of its binary, and the shell says so: asked about the
    # live Timi window on 2026-08-20, IApplicationResolver::GetAppIDForWindow
    # answered C:\Users\Ahmad\Timi\wt\WindowsTerminal.exe with explicit=False.
    # Putting a made-up id ('Zeino.Timi') on the shortcut was the version before
    # this one, and it guaranteed the two buttons it was meant to prevent: the
    # window cannot be told to adopt it - an explicit id is per-process and is
    # not inherited from a launcher, and the shortcut's id cannot cross the
    # scheduled task that carries the elevation. Moving the SHORTCUT onto the
    # window's id is the direction that works with the shell instead of against
    # it.
    #
    # It is still exact to Timi: the path is Timi's own copy of the Terminal, so
    # the user's own Terminal windows resolve elsewhere and do not join this
    # button. That was the fault of the version before both - it borrowed the
    # STORE Terminal's id and collected every terminal window on the machine.
    return (Join-Path $TIMI 'wt\WindowsTerminal.exe')
}

function New-TimiShortcut {
    param([string]$Path)
    # Written by Timi.exe rather than WScript.Shell: the AppUserModelID lives in
    # the shortcut's property store, which the WScript object cannot reach.
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $p = Start-Process -FilePath $exe -ArgumentList @('/shortcut', "`"$Path`"", "`"$(Get-TerminalAumid)`"") -PassThru -Wait
    if ($p.ExitCode -ne 0 -or -not (Test-Path $Path)) {
        # Fall back to a plain shortcut - a pin that groups badly still beats no
        # pin at all.
        $sc = (New-Object -ComObject WScript.Shell).CreateShortcut($Path)
        $sc.TargetPath       = $exe
        $sc.WorkingDirectory = $TIMI
        $sc.IconLocation     = "$ico,0"
        $sc.Description      = 'Timi - agent terminal'
        $sc.Save()
    }
}

$startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Timi.lnk'
New-TimiShortcut -Path $startMenu
Ok "start menu entry"

# --- 6. taskbar pin ------------------------------------------------------
# Every documented way to pin an app was tried on this machine and measured;
# writing it down because the failures all look like bugs in this script
# otherwise:
#
#   * The "Pin to taskbar" SHELL VERB does not exist on Windows 11 25H2 - not
#     for Timi.exe, not for its Start menu shortcut. InvokeVerb('taskbarpin')
#     has nothing to invoke.
#   * The supported API, TaskbarManager.RequestPinCurrentAppAsync, reports
#     IsSupported=True but IsPinningAllowed=False and refuses before showing
#     its consent dialog. Not a policy: a full sweep of HKLM/HKCU Policies and
#     PolicyManager found no pinning value anywhere, and it still refused after
#     the taskbar layout policy was removed and gpupdate run. It is the
#     long-standing desktop-app limitation (WindowsAppSDK issue #1648) - the
#     API works from packaged apps only.
#   * Writing HKCU\...\Taskband\Favorites by hand does not stick. The blob is
#     a 0x00 header then [DWORD cb][ITEMIDLIST][flag] per pin, flag 0x00
#     between entries and 0xFF at the end - that much decodes cleanly, and a
#     hand-appended entry tiles correctly - but Explorer rewrites the value on
#     restart and drops the added pin, both with a freshly built PIDL and with
#     one cloned byte-for-byte from the neighbouring FanControl pin.
#   * Clearing Taskband to force a re-read just deletes the pins: the layout
#     policy is applied at SIGN-IN, not on an Explorer restart (measured - all
#     four pins vanished and did not come back; they were restored from the
#     .reg backup this script writes).
#
# One more thing the pin needs beyond existing: an identity. Taskbar buttons
# group by AppUserModelID; Timi.exe exits immediately and the window that shows
# up belongs to Windows Terminal, so without help the pinned icon and the window
# it opened are two separate buttons. New-TimiShortcut therefore writes the
# shortcut through Timi.exe /shortcut, which stamps the Terminal's own AUMID
# onto it - the button keeps Timi's icon and collects the Terminal windows.
#
# What is left is the mechanism this machine already pins with. The current
# pins came from a policy taskbar layout - HKLM\SOFTWARE\Policies\Microsoft\
# Windows\Explorer\StartLayoutFile pointing at C:\Windows\TaskbarLayoutModification.xml
# with PinListPlacement="Replace" - so Timi is added to that list. It appears
# on the taskbar at the next sign-in, alongside the pins already there.
$PIN_LNK = Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\Timi.lnk'

function Test-Pinned {
    $fav = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband' `
             -Name Favorites -ErrorAction SilentlyContinue).Favorites
    if (-not $fav) { return $false }
    $b = [byte[]]$fav
    # The name can sit at either byte alignment inside the blob, so both are
    # decoded - checking only one silently reports "not pinned" when it is.
    foreach ($skip in 0, 1) {
        $text = [System.Text.Encoding]::Unicode.GetString($b, $skip, $b.Length - $skip)
        if ($text -match 'Timi\.lnk') { return $true }
        # A pin made from the RUNNING window keeps the name Windows gave it -
        # "Windows Terminal Host.lnk" - so matching only Timi.lnk reports "not
        # pinned" while a Timi pin is sitting right there, and the installer
        # queues a second one into the layout policy for the next sign-in.
        # The blob also carries the path the pin was built from, and that path
        # is inside the Timi folder; Convert-StrayTerminalPin has already
        # re-aimed such a shortcut at Timi.exe by the time this is asked.
        if ($text -match [regex]::Escape((Join-Path $TIMI 'wt'))) { return $true }
    }
    return $false
}

function Set-TaskbarLayoutEntry {
    $key = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'
    if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
    $file = (Get-ItemProperty $key -Name StartLayoutFile -ErrorAction SilentlyContinue).StartLayoutFile

    # An earlier version of this installer removed that value while working out
    # what was blocking the API. Put it back from the note it left.
    if (-not $file) {
        $note = Get-ChildItem (Join-Path $TIMI 'taskbar-policy-backup-*.txt') -ErrorAction SilentlyContinue |
                Sort-Object Name | Select-Object -First 1
        if ($note) {
            $line = Get-Content $note.FullName | Where-Object { $_ -match '^StartLayoutFile = ' }
            if ($line) { $file = $line -replace '^StartLayoutFile = ', '' }
        }
    }
    if (-not $file) { return $null }
    if (-not (Test-Path $file)) { return $null }

    $raw = Get-Content $file -Raw
    if ($raw -notmatch 'Timi\.lnk') {
        Copy-Item $file (Join-Path $TIMI ('taskbar-layout-backup-{0}.xml' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))) -Force
        $entry = '        <taskbar:DesktopApp DesktopApplicationLinkPath="{0}"/>' -f $PIN_LNK
        $updated = $raw -replace '(?m)^(\s*)</taskbar:TaskbarPinList>', ($entry + "`r`n" + '$1</taskbar:TaskbarPinList>')
        if ($updated -eq $raw) { return $null }
        [xml]$null = $updated          # parse-check before it goes to C:\Windows
        Set-Content -Path $file -Value $updated -Encoding UTF8
    }
    Set-ItemProperty -Path $key -Name StartLayoutFile -Value $file
    return $file
}

# Pinning the RUNNING window - right click the taskbar button, "Pin to taskbar" -
# is the one route to a pin that works on this machine without a sign-in, and it
# produces a shortcut that bypasses everything Timi does. Windows names it after
# the binary's FileDescription and points it straight at that binary:
#
#     Windows Terminal Host.lnk  ->  C:\Users\Ahmad\Timi\wt\WindowsTerminal.exe
#
# Found live on 2026-08-20, and it was the whole of the user's complaint. That
# pin starts the Terminal DIRECTLY, so it never reaches the scheduled task and
# comes up unelevated; every lane profile then asked for elevation on its own,
# which the Terminal answers by putting a UAC dialog on screen and opening a
# SECOND, elevated window through elevate-shim.exe; and that window arrives with
# `--profile ... --startingDirectory ...` on its command line, which makes it
# skip firstWindowPreference and restore nothing. One wrong shortcut target,
# three symptoms: a prompt, two windows, and lost conversations.
#
# So any pin aimed at Timi's Terminal is adopted: same file, same pin, but the
# target becomes Timi.exe and the identity becomes the one the window resolves
# to. Rewriting the .lnk in place is deliberate - the pin list in the registry
# refers to it BY PATH, so the pin survives; deleting and recreating it would
# not, and hand-editing that blob is rejected by Explorer (see the notes above).
function Convert-StrayTerminalPin {
    $dir = Split-Path $PIN_LNK -Parent
    if (-not (Test-Path $dir)) { return }
    $wtDir = Join-Path $TIMI 'wt'
    $shell = New-Object -ComObject WScript.Shell
    foreach ($lnk in Get-ChildItem $dir -Filter '*.lnk' -ErrorAction SilentlyContinue) {
        if ($lnk.FullName -eq $PIN_LNK) { continue }
        try { $target = $shell.CreateShortcut($lnk.FullName).TargetPath } catch { continue }
        if (-not $target) { continue }
        if (-not $target.StartsWith($wtDir, [StringComparison]::OrdinalIgnoreCase)) { continue }
        New-TimiShortcut -Path $lnk.FullName
        Ok "adopted pinned $($lnk.Name) - it now launches Timi.exe (elevated, one window) instead of the bare Terminal"
    }
}

if ($SkipPin) {
    Step "taskbar pin skipped"
} else {
    Convert-StrayTerminalPin
    New-TimiShortcut -Path $PIN_LNK
    # Pinning by hand does not reuse this shortcut - Windows copies it and the
    # copy lands as "Timi (2).lnk", which is then the one the taskbar actually
    # points at. Stamp every Timi shortcut in the folder, or the identity fix
    # above silently applies to the file nobody is using.
    foreach ($extra in Get-ChildItem (Split-Path $PIN_LNK -Parent) -Filter 'Timi*.lnk' -ErrorAction SilentlyContinue) {
        if ($extra.FullName -ne $PIN_LNK) { New-TimiShortcut -Path $extra.FullName }
    }
    if (Test-Pinned) {
        Ok "taskbar pin present"
    } else {
        $file = Set-TaskbarLayoutEntry
        if ($file) {
            Ok "taskbar pin queued in $file - it appears at the next sign-in (this machine pins by policy layout; nothing else on Windows 11 25H2 can add a pin, see the notes above)"
        } else {
            Warn "no taskbar layout policy to add Timi to - pin it by hand from Start"
        }
    }
}

# --- 7. mapped drives in elevated sessions -------------------------------
# UAC gives an elevated process a different logon session, and drive letters
# mapped by the unelevated one are not in it. Without this, an elevated Timi
# sees no F:/H:/L:/Y:/Z:. Takes effect from the next sign-in; Launch-Timi.ps1
# re-maps them at every launch so today still works.
$sysPolicy = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
$current = (Get-ItemProperty $sysPolicy -Name EnableLinkedConnections -ErrorAction SilentlyContinue).EnableLinkedConnections
if ($current -ne 1) {
    New-ItemProperty -Path $sysPolicy -Name EnableLinkedConnections -PropertyType DWord -Value 1 -Force | Out-Null
    Ok "EnableLinkedConnections=1 (mapped drives in elevated sessions, from next sign-in)"
} else { Step "EnableLinkedConnections already set" }

# --- 8. Ctrl+wheel zoom hook --------------------------------------------
# Registered in the existing keepalive rather than started here, so it comes
# back after a reboot and after AutoHotkey is restarted - and so it runs from
# that task's RunLevel Highest, which is what lets its synthetic keystrokes
# reach an elevated Timi window at all.
#
# The hook is a MODULE inside global-hotkeys.ahk now, not the standalone
# timi-zoom.ahk this used to look for - that file is gone, so the old check
# reported "Ctrl+wheel zoom will not work" on a machine where it works fine.
$vbs = 'C:\Users\Ahmad\Scripts\hotkeys-ensure.vbs'
$ahk = 'C:\Users\Ahmad\Scripts\global-hotkeys.ahk'
if (-not (Test-Path $ahk)) {
    Warn "global-hotkeys.ahk missing - Ctrl+wheel zoom will not work"
} elseif ((Get-Content $ahk -Raw) -notmatch 'adjustFontSize|\{F9\}') {
    Warn "the Windows Terminal / Timi module is not in $ahk"
} elseif ((Get-Content $vbs -Raw) -notmatch 'global-hotkeys\.ahk') {
    Warn "global-hotkeys.ahk is not in the SCRIPTS array of $vbs"
} else {
    # A resident instance older than the script is running the PREVIOUS version
    # of the module - AutoHotkey does not watch the file. The keepalive will not
    # replace it either: it only relaunches what is dead. #SingleInstance Force
    # makes a fresh launch take over, and this runs elevated (from the task or
    # from the installer's own lift), which is the only context that can stop
    # the elevated instance the keepalive started.
    $stale = Get-Process AutoHotkey64 -ErrorAction SilentlyContinue |
             Where-Object { $_.StartTime -lt (Get-Item $ahk).LastWriteTime }
    if ($stale) {
        $stale | Stop-Process -Force -ErrorAction SilentlyContinue
        Ok "restarted the hotkey script (it predated the current $([IO.Path]::GetFileName($ahk)))"
    }
    schtasks.exe /Run /TN "ShareX Hotkey Keepalive" | Out-Null
    Ok "Ctrl+wheel zoom hook registered and running"
}

Write-Host "`nTimi is installed. Click the taskbar icon (or Start > Timi) to open it.`n" -ForegroundColor Cyan
