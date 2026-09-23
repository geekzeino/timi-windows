# Patch-WtIcon.ps1 - stamps Timi.ico into Timi's OWN copy of Windows Terminal.
#
# Make-TimiIcon.ps1 already says why Timi must not wear the Terminal's icon:
# the taskbar entry should read "my agent shell", not "a terminal emulator".
# That only ever reached the *shortcut*. The window is drawn by
# Timi\wt\WindowsTerminal.exe, and an unpackaged Windows Terminal takes its
# window icon from its own RT_GROUP_ICON resource (IDI_APPICON) - not from
# settings.json, not from the shortcut that launched it, and not from an
# AppUserModelID (see the long note in Launch-Timi.ps1 about why that id cannot
# reach across the scheduled task). So Timi launched looking exactly like the
# user's Terminal: same glyph in the taskbar, same glyph in Alt+Tab, and no way
# to tell the two apart.
#
# Rewriting the resource is what makes the difference visible from the first
# frame of every window - including ones Windows Terminal opens itself, which a
# WM_SETICON poke from the launcher would miss. It is only defensible because
# `Timi\wt` is a PRIVATE, pinned copy that never auto-updates: the user's Store
# Terminal is a different install and is never touched, so it keeps the
# Microsoft glyph and the two apps finally look like two apps.
#
# Cost, stated plainly: editing resources invalidates the binary's Authenticode
# signature. Nothing on this machine enforces it - Smart App Control's
# enforcing policy (VerifiedAndReputableDesktop) is not enforced, only its
# Evaluation twin is, which audits and never blocks - and the file already
# lives in a user-writable folder. If a future Windows does start refusing it,
# `-Restore` puts the untouched Microsoft binaries back in one step.
#
# Idempotent: the pristine binary is kept beside the patched one as
# <name>.msorig and every run patches FROM that, so running this twice, or
# after unzipping a newer Terminal, produces the same result rather than
# stacking edits.

[CmdletBinding()]
param(
    # Timi's private Windows Terminal folder (the one with .portable in it).
    [string]$WtDir = "$PSScriptRoot\wt",
    # The icon to stamp in.
    [string]$Ico = "$PSScriptRoot\Timi.ico",
    # Put the untouched Microsoft binaries back.
    [switch]$Restore
)

$ErrorActionPreference = 'Stop'

# Both binaries carry an icon. WindowsTerminal.exe is the one that owns the
# window, so it is the one that matters; wt.exe is the launcher stub, patched
# too so that anything that looks at the file (an Explorer listing, a pinned
# shortcut to it, a "run as" dialog) tells the same story.
$TARGETS = @('WindowsTerminal.exe', 'wt.exe')

# --- Win32 -------------------------------------------------------------------

if (-not ('TimiIcon.Res' -as [type])) {
    Add-Type -Namespace TimiIcon -Name Res -MemberDefinition @'
[DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
public static extern IntPtr BeginUpdateResource(string file, bool deleteExisting);
[DllImport("kernel32.dll", SetLastError=true)]
public static extern bool UpdateResource(IntPtr h, IntPtr type, IntPtr name, ushort lang, byte[] data, uint cb);
[DllImport("kernel32.dll", SetLastError=true)]
public static extern bool EndUpdateResource(IntPtr h, bool discard);
[DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
public static extern IntPtr LoadLibraryEx(string file, IntPtr h, uint flags);
[DllImport("kernel32.dll")] public static extern bool FreeLibrary(IntPtr h);
public delegate bool EnumResNameProc(IntPtr mod, IntPtr type, IntPtr name, IntPtr param);
public delegate bool EnumResLangProc(IntPtr mod, IntPtr type, IntPtr name, ushort lang, IntPtr param);
[DllImport("kernel32.dll", SetLastError=true)]
public static extern bool EnumResourceNames(IntPtr h, IntPtr type, EnumResNameProc cb, IntPtr param);
[DllImport("kernel32.dll", SetLastError=true)]
public static extern bool EnumResourceLanguages(IntPtr h, IntPtr type, IntPtr name, EnumResLangProc cb, IntPtr param);
'@
}

$RT_ICON       = [IntPtr]3
$RT_GROUP_ICON = [IntPtr]14
$AS_DATAFILE   = 0x2

function Throw-Win32([string]$what) {
    $e = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    throw ("{0} failed: {1} (0x{2:X})" -f $what, ([ComponentModel.Win32Exception]::new($e).Message), $e)
}

# Which icon groups does this binary carry, and in which language? Read them
# rather than hard-coding 101: a newer Terminal build is free to renumber, and
# a group written under the wrong LANGID is a second, invisible resource that
# the loader never picks.
function Get-IconGroups([string]$exe) {
    $h = [TimiIcon.Res]::LoadLibraryEx($exe, [IntPtr]::Zero, $AS_DATAFILE)
    if ($h -eq [IntPtr]::Zero) { Throw-Win32 "LoadLibraryEx($exe)" }
    try {
        $ids = New-Object System.Collections.ArrayList
        $nameCb = [TimiIcon.Res+EnumResNameProc]{
            param($m, $t, $n, $p)
            if ([int64]$n -lt 0x10000) { [void]$ids.Add([int]$n) }   # integer ids only
            return $true
        }
        [void][TimiIcon.Res]::EnumResourceNames($h, $RT_GROUP_ICON, $nameCb, [IntPtr]::Zero)

        $out = New-Object System.Collections.ArrayList
        foreach ($id in $ids) {
            $langs = New-Object System.Collections.ArrayList
            $langCb = [TimiIcon.Res+EnumResLangProc]{
                param($m, $t, $n, $l, $p) [void]$langs.Add([int]$l); return $true
            }
            [void][TimiIcon.Res]::EnumResourceLanguages($h, $RT_GROUP_ICON, [IntPtr]$id, $langCb, [IntPtr]::Zero)
            foreach ($l in $langs) { [void]$out.Add([pscustomobject]@{ Id = $id; Lang = [uint16]$l }) }
        }
        # Same question for the images themselves - their ids are what a fresh
        # group has to avoid colliding with.
        $imgIds = New-Object System.Collections.ArrayList
        $imgCb = [TimiIcon.Res+EnumResNameProc]{
            param($m, $t, $n, $p)
            if ([int64]$n -lt 0x10000) { [void]$imgIds.Add([int]$n) }
            return $true
        }
        [void][TimiIcon.Res]::EnumResourceNames($h, $RT_ICON, $imgCb, [IntPtr]::Zero)
        return [pscustomobject]@{ Groups = $out; ImageIds = $imgIds }
    } finally { [void][TimiIcon.Res]::FreeLibrary($h) }
}

# .ico on disk and RT_GROUP_ICON in a binary are the same directory with one
# field swapped: the 4-byte file offset of each image becomes the 2-byte
# resource id it was stored under. Everything else is byte-identical, which is
# why this can be a straight rewrite rather than a re-encode.
function Read-IcoImages([string]$path) {
    $bytes = [IO.File]::ReadAllBytes($path)
    if ($bytes.Length -lt 6) { throw "$path is not an icon" }
    if ([BitConverter]::ToUInt16($bytes, 0) -ne 0 -or [BitConverter]::ToUInt16($bytes, 2) -ne 1) {
        throw "$path is not an ICO (bad ICONDIR header)"
    }
    $count = [BitConverter]::ToUInt16($bytes, 4)
    $imgs = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $count; $i++) {
        $e = 6 + $i * 16
        $size = [BitConverter]::ToUInt32($bytes, $e + 8)
        $off  = [BitConverter]::ToUInt32($bytes, $e + 12)
        $data = New-Object byte[] $size
        [Array]::Copy($bytes, $off, $data, 0, $size)
        [void]$imgs.Add([pscustomobject]@{
            Width  = $bytes[$e]; Height = $bytes[$e + 1]
            Colors = $bytes[$e + 2]; Reserved = $bytes[$e + 3]
            Planes = [BitConverter]::ToUInt16($bytes, $e + 4)
            Bits   = [BitConverter]::ToUInt16($bytes, $e + 6)
            Data   = $data
        })
    }
    return $imgs
}

function New-GroupBlob($imgs, [int]$firstId) {
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$imgs.Count)
    for ($i = 0; $i -lt $imgs.Count; $i++) {
        $im = $imgs[$i]
        $bw.Write([byte]$im.Width); $bw.Write([byte]$im.Height)
        $bw.Write([byte]$im.Colors); $bw.Write([byte]$im.Reserved)
        $bw.Write([uint16]$im.Planes); $bw.Write([uint16]$im.Bits)
        $bw.Write([uint32]$im.Data.Length)
        $bw.Write([uint16]($firstId + $i))
    }
    $bw.Flush()
    return $ms.ToArray()
}

# Windows Terminal is running while this runs - it IS the window Timi is in -
# and a running image cannot be overwritten. It can be RENAMED, though, so the
# patched file takes the real name and the live process keeps its old inode.
function Install-Binary([string]$staged, [string]$target) {
    try {
        Move-Item -LiteralPath $staged -Destination $target -Force
        return 'replaced'
    } catch {
        $parked = "$target.inuse-$(Get-Date -Format yyyyMMdd-HHmmss)"
        Rename-Item -LiteralPath $target -NewName (Split-Path $parked -Leaf)
        Move-Item -LiteralPath $staged -Destination $target -Force
        return "replaced (old image parked as $(Split-Path $parked -Leaf) - delete after the next Timi restart)"
    }
}

# --- run ---------------------------------------------------------------------

if (-not (Test-Path $WtDir)) { throw "Timi: $WtDir does not exist - nothing to patch." }

# Images parked by an earlier run, once the process holding them has gone.
# Still-locked ones simply fail the delete and wait for the run after that.
Get-ChildItem -LiteralPath $WtDir -Filter '*.exe.inuse-*' -ErrorAction SilentlyContinue | ForEach-Object {
    try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop; Write-Output "swept $($_.Name)" } catch { }
}

foreach ($name in $TARGETS) {
    $target = Join-Path $WtDir $name
    $orig   = "$target.msorig"
    if (-not (Test-Path $target)) { Write-Warning "skip $name (not present)"; continue }

    if ($Restore) {
        if (Test-Path $orig) {
            $r = Install-Binary -staged $orig -target $target
            Write-Output "$name  restored from .msorig  ($r)"
        } else {
            Write-Output "$name  no .msorig - already stock"
        }
        continue
    }

    if (-not (Test-Path $orig)) { Copy-Item -LiteralPath $target -Destination $orig }

    $info = Get-IconGroups $orig
    if ($info.Groups.Count -eq 0) { Write-Warning "skip $name (no icon groups)"; continue }

    # Start the new images above every id already in the file so nothing that
    # still points at an old image can be broken by the rewrite.
    $firstId = 1
    if ($info.ImageIds.Count -gt 0) {
        $firstId = ([int](($info.ImageIds | Measure-Object -Maximum).Maximum)) + 1
    }

    $imgs  = Read-IcoImages $Ico
    $stage = "$target.new"
    if (Test-Path $stage) { Remove-Item -LiteralPath $stage -Force }
    Copy-Item -LiteralPath $orig -Destination $stage

    $h = [TimiIcon.Res]::BeginUpdateResource($stage, $false)
    if ($h -eq [IntPtr]::Zero) { Throw-Win32 'BeginUpdateResource' }
    $ok = $false
    try {
        $lang = [uint16]$info.Groups[0].Lang
        for ($i = 0; $i -lt $imgs.Count; $i++) {
            $d = $imgs[$i].Data
            if (-not [TimiIcon.Res]::UpdateResource($h, $RT_ICON, [IntPtr]($firstId + $i), $lang, $d, [uint32]$d.Length)) {
                Throw-Win32 "UpdateResource(RT_ICON #$($firstId + $i))"
            }
        }
        # Every group, not just IDI_APPICON: this build carries three and the
        # loader is free to pick any of them for a given surface.
        $blob = New-GroupBlob $imgs $firstId
        foreach ($g in $info.Groups) {
            if (-not [TimiIcon.Res]::UpdateResource($h, $RT_GROUP_ICON, [IntPtr]$g.Id, [uint16]$g.Lang, $blob, [uint32]$blob.Length)) {
                Throw-Win32 "UpdateResource(RT_GROUP_ICON #$($g.Id))"
            }
        }
        $ok = $true
    } finally {
        if (-not [TimiIcon.Res]::EndUpdateResource($h, -not $ok)) { if ($ok) { Throw-Win32 'EndUpdateResource' } }
    }

    $r = Install-Binary -staged $stage -target $target
    $groups = ($info.Groups | ForEach-Object { "#$($_.Id)" }) -join ','
    Write-Output "$name  groups $groups <- $(Split-Path $Ico -Leaf) ($($imgs.Count) sizes, images #$firstId+)  $r"
}
