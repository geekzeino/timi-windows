# Uninstall-Timi.ps1 - undoes everything Install-Timi.ps1 put outside this folder.
#
# The Timi folder itself is left alone: it is the source, not the installation.
# Delete it by hand afterwards if that is what you want.
#
#   -KeepSettings  leave the Windows Terminal settings as they are
#   -Full          also clear EnableLinkedConnections (left set by default -
#                  other things on this box may now be relying on elevated
#                  processes seeing F:/H:/L:/Y:/Z:)

[CmdletBinding()]
param(
    [switch]$KeepSettings,
    [switch]$Full
)

$ErrorActionPreference = 'Continue'
$TIMI = $PSScriptRoot

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', $PSCommandPath)
    if ($KeepSettings) { $psArgs += '-KeepSettings' }
    if ($Full)         { $psArgs += '-Full' }
    Start-Process powershell.exe -ArgumentList $psArgs -Verb RunAs
    exit 0
}

function Ok($m) { Write-Host "  [ok] $m" -ForegroundColor Green }

# 1. scheduled task
if (Get-ScheduledTask -TaskName 'Timi' -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName 'Timi' -Confirm:$false
    Ok 'scheduled task removed'
}

# 2. shortcuts and the taskbar entry
$pinLnk = Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\Timi.lnk'
$smLnk  = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Timi.lnk'
# The installer removed a StartLayoutFile policy that was blocking all
# taskbar pinning on this machine. Put it back only if its backup note is
# still in the Timi folder - and note that doing so re-disables pinning for
# everything, not just Timi.
$note = Get-ChildItem (Join-Path $TIMI 'taskbar-policy-backup-*.txt') -ErrorAction SilentlyContinue |
        Sort-Object Name | Select-Object -First 1
if ($note) {
    $line = (Get-Content $note.FullName | Where-Object { $_ -match '^StartLayoutFile = ' })
    if ($line) {
        $file = $line -replace '^StartLayoutFile = ', ''
        New-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer' `
            -Name StartLayoutFile -PropertyType String -Value $file -Force | Out-Null
        Ok "StartLayoutFile policy restored ($file)"
    }
}

Remove-Item $pinLnk, $smLnk -Force -ErrorAction SilentlyContinue
Get-Process explorer -ErrorAction SilentlyContinue | Stop-Process -Force
Ok 'shortcuts removed (Explorer restarted to refresh the taskbar)'

# 3. Ctrl+wheel zoom hook
$vbs = 'C:\Users\Ahmad\Scripts\hotkeys-ensure.vbs'
if ((Test-Path $vbs) -and ((Get-Content $vbs -Raw) -match 'timi-zoom\.ahk')) {
    Copy-Item $vbs "$vbs.bak-uninstall-$(Get-Date -Format 'yyyyMMdd-HHmmss')" -Force
    (Get-Content $vbs -Raw).Replace(', "timi-zoom.ahk"', '') | Set-Content $vbs -Encoding UTF8
    Ok 'zoom hook unregistered from hotkeys-ensure.vbs'
}
Get-CimInstance Win32_Process -Filter "Name='AutoHotkey64.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*timi-zoom.ahk*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

# 4. Windows Terminal settings
# Timi keeps its lanes in its own portable Terminal under Timi\wt now, so there
# is normally nothing of Timi's in the user's settings to undo. This runs the
# patcher's --unpatch anyway - it is a no-op on a clean file and it is what
# rescues a machine still carrying the old shared-settings install. Restoring
# the oldest backup wholesale, which is what this used to do, would also throw
# away every unrelated change the user has made since Timi was installed.
if (-not $KeepSettings) {
    $py = Get-Command py -ErrorAction SilentlyContinue
    if (-not $py) { $py = Get-Command python -ErrorAction SilentlyContinue }
    if ($py) {
        & $py.Source (Join-Path $TIMI 'Patch-WtSettings.py') --unpatch | ForEach-Object { Ok $_ }
    } else {
        Write-Host "  [--] python not found - the user's Terminal settings were left as they are"
    }
}

# 5. lane state
Remove-Item (Join-Path $env:LOCALAPPDATA 'Timi') -Recurse -Force -ErrorAction SilentlyContinue
Ok 'lane markers cleared'

if ($Full) {
    Remove-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
        -Name EnableLinkedConnections -ErrorAction SilentlyContinue
    Ok 'EnableLinkedConnections cleared (takes effect at next sign-in)'
}

Write-Host "`nTimi removed. The Timi folder itself is untouched.`n" -ForegroundColor Cyan
