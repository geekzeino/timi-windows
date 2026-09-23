# Timi-Shard.ps1 - the shard/account picker for one Timi lane on Windows.
#
# The Linux deck answers "who pays for this turn" through open_shard_menu and
# the `shard` control verb. Windows Terminal has no such menu, so this is the
# seam: given a lane, it lists that lane's accounts from shards.json (the
# manifest generated from the Linux pools - never hand-edited), shows the
# account the lane currently runs on, and writes the pick to the marker file
# TimiLane.cs already resolves at launch:
#
#   %LOCALAPPDATA%\Timi\account           <- the default for every lane
#   %LOCALAPPDATA%\Timi\account.<lane>    <- a per-lane pin, beats the default
#
# Solo lanes (codex -> chatgpt, deepseek -> deepseek) show their one account;
# a lane having ONE account is not a reason to hide which account it is - that
# was timi#37 on Linux and it is the same rule here.
#
# Usage:  Timi-Shard.ps1 [-Lane opus] [-Set <account>] [-List]
#   -List           print the lane's rows and exit (no prompt)
#   -Set <account>  write the pick non-interactively
#   neither         interactive numbered prompt
#
# The write is atomic-by-rename (tmp then Move-Item -Force), the same contract
# TimiLane.cs claims markers with - two pickers racing cannot interleave a
# half-written file.

[CmdletBinding()]
param(
    [string]$Lane,
    [string]$Set,
    [switch]$List
)

$ErrorActionPreference = 'Stop'

$script:TimiDir   = Split-Path -Parent $PSScriptRoot          # ...\timi-windows-v2 -> parent
$script:Shards    = Join-Path $PSScriptRoot 'shards.json'
$script:MarkerDir = Join-Path $env:LOCALAPPDATA 'Timi'

function Read-Shards {
    if (-not (Test-Path $Shards)) {
        throw "Timi: shards.json is missing from $PSScriptRoot - regenerate the manifest (Install-Timi.ps1)"
    }
    return (Get-Content $Shards -Raw | ConvertFrom-Json)
}

function Get-LaneRows {
    param([hashtable]$ByLane, [string]$LaneKey)
    return $ByLane[$LaneKey]
}

function Write-TimiLog {
    param([string]$Message)
    try {
        New-Item -ItemType Directory -Force -Path $MarkerDir | Out-Null
        "{0}  {1}" -f (Get-Date -Format 's'), $Message |
            Out-File (Join-Path $MarkerDir 'shard.log') -Append -Encoding UTF8
    } catch { }
}

$manifest = Read-Shards
if ($manifest.schema_version -ne 1) {
    throw "Timi: shards.json schema_version is $($manifest.schema_version), this picker speaks 1"
}

# Group the manifest rows per lane once; solo lanes keep their single row.
$byLane = @{}
foreach ($row in $manifest.shards) {
    if (-not $byLane.ContainsKey($row.provider)) { $byLane[$row.provider] = @() }
    $byLane[$row.provider] += $row
}

if (-not $Lane) {
    Write-Host "Lanes:" ([string]::Join(', ', ($byLane.Keys | Sort-Object))) -ForegroundColor Cyan
    $Lane = Read-Host "Lane"
}
if (-not $byLane.ContainsKey($Lane)) {
    throw "Timi: no picker rows for lane '$Lane' - is it in shards.json?"
}

$rows = Get-LaneRows -ByLane $byLane -LaneKey $Lane
$marker = Join-Path $MarkerDir ("account.{0}" -f $Lane)
$default = Join-Path $MarkerDir 'account'
$current = if (Test-Path $marker) { (Get-Content $marker -Raw).Trim() } `
           elseif (Test-Path $default) { (Get-Content $default -Raw).Trim() } else { "" }

if ($List) {
    foreach ($r in $rows) {
        $mark = if ($r.account -eq $current) { " <- current" } else { "" }
        Write-Host ("{0,-4} {1,-40} {2,-8}{3}" -f $r.slug, $r.account, $r.state, $mark)
    }
    exit 0
}

$picked = $Set
if (-not $picked) {
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $mark = if ($rows[$i].account -eq $current) { " <- current" } else { "" }
        Write-Host ("  [{0}] {1,-40} {2,-8}{3}" -f ($i + 1), $rows[$i].account, $rows[$i].state, $mark)
    }
    $sel = Read-Host "Account for $Lane"
    $idx = 0
    if (-not [int]::TryParse($sel, [ref]$idx) -or $idx -lt 1 -or $idx -gt $rows.Count) {
        throw "Timi: '$sel' is not one of the listed accounts"
    }
    $picked = $rows[$idx - 1].account
} else {
    $known = $rows | Where-Object { $_.account -eq $picked }
    if (-not $known) { throw "Timi: '$picked' is not an account on lane $Lane (see shards.json)" }
}

# A per-lane pin that equals the file the default already carries is noise -
# the pin exists to DIVERGE from the default (Launch-Timi/TimiLane read the
# lane file first, then the global one, so an equal value adds nothing).
if ((Test-Path $default) -and ((Get-Content $default -Raw).Trim()) -eq $picked) {
    Remove-Item $marker -Force -ErrorAction SilentlyContinue
    Write-TimiLog "pick $Lane -> $picked (equals the default; lane pin cleared)"
    Write-Host "Timi: $Lane runs on '$picked' (the shared default)" -ForegroundColor Green
    exit 0
}

$tmp = "$marker.tmp"
New-Item -ItemType Directory -Force -Path $MarkerDir | Out-Null
Set-Content -Path $tmp -Value $picked -Encoding ASCII -NoNewline
Move-Item -Force $tmp $marker
Write-TimiLog "pick $Lane -> $picked"
Write-Host "Timi: $Lane pinned to '$picked'" -ForegroundColor Green
