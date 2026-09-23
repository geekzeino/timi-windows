# Make-TimiIcon.ps1 - generates Timi.ico (the launcher's own identity).
#
# Timi is not Windows Terminal and must not wear its icon: the whole point of a
# separate launcher is that the taskbar entry says "my agent shell", not "a
# terminal emulator". So the mark is Claude's asterisk in the Timi accent
# (#D97757 - the same orange the Opus lane's tab uses in wt-settings.json) on a
# dark rounded tile, which keeps it legible on both a light and a dark taskbar.
# A transparent-background mark would disappear into whichever theme matched it.
#
# Sizes are drawn NATIVELY, one bitmap per size, instead of downscaling one
# 256px master: an asterisk downscaled to 16px turns into an orange smudge,
# while re-drawing it at 16px keeps the spokes as actual pixels. Payloads are
# PNG (supported inside .ico by every Windows since Vista).

[CmdletBinding()]
param([string]$OutPath = "$PSScriptRoot\Timi.ico")

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

$SIZES = @(16, 20, 24, 32, 40, 48, 64, 128, 256)

$TILE_TOP    = [System.Drawing.Color]::FromArgb(255, 45, 42, 38)   # #2D2A26
$TILE_BOTTOM = [System.Drawing.Color]::FromArgb(255, 25, 24, 22)   # #191816
$TILE_EDGE   = [System.Drawing.Color]::FromArgb(255, 61, 57, 51)   # #3D3933
$ACCENT      = [System.Drawing.Color]::FromArgb(255, 217, 119, 87) # #D97757

function New-RoundedPath {
    param([single]$X, [single]$Y, [single]$W, [single]$H, [single]$R)
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $R * 2
    $p.AddArc($X,           $Y,           $d, $d, 180, 90)
    $p.AddArc($X + $W - $d, $Y,           $d, $d, 270, 90)
    $p.AddArc($X + $W - $d, $Y + $H - $d, $d, $d,   0, 90)
    $p.AddArc($X,           $Y + $H - $d, $d, $d,  90, 90)
    $p.CloseFigure()
    return $p
}

function New-TimiBitmap {
    param([int]$Size)

    $bmp = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)

    # Tile. Inset by half a pixel-unit so the antialiased edge lands inside the
    # bitmap instead of being clipped, which is what makes small sizes look
    # chipped on one side.
    $inset  = [single]([Math]::Max(1, [Math]::Round($Size * 0.02)))
    $side   = [single]($Size - 2 * $inset)
    $radius = [single][Math]::Max(2, [Math]::Round($Size * 0.22))
    $tile = New-RoundedPath -X $inset -Y $inset -W $side -H $side -R $radius
    $rect = New-Object System.Drawing.RectangleF($inset, $inset, $side, $side)
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $TILE_TOP, $TILE_BOTTOM, 90.0)
    $g.FillPath($brush, $tile)
    if ($Size -ge 32) {
        $pen = New-Object System.Drawing.Pen($TILE_EDGE, [single]([Math]::Max(1, $Size / 64)))
        $g.DrawPath($pen, $tile)
        $pen.Dispose()
    }
    $brush.Dispose()

    # Asterisk: four rounded bars through the centre at 0/45/90/135 degrees.
    # Four bars beat eight tapered spokes below 24px - tapered tips fall under
    # one pixel and antialias away to nothing.
    $len   = [single]($Size * 0.62)
    $thick = [single]([Math]::Max(2.0, $Size * 0.115))
    $accentBrush = New-Object System.Drawing.SolidBrush($ACCENT)
    $state = $g.Save()
    $g.TranslateTransform([single]($Size / 2.0), [single]($Size / 2.0))
    foreach ($angle in 0, 45, 90, 135) {
        $g.RotateTransform([single]$angle)
        $bar = New-RoundedPath -X ([single](-$len / 2)) -Y ([single](-$thick / 2)) `
                               -W $len -H $thick -R ([single]($thick / 2))
        $g.FillPath($accentBrush, $bar)
        $bar.Dispose()
        $g.RotateTransform([single](-$angle))
    }
    $g.Restore($state)
    $accentBrush.Dispose()

    $tile.Dispose()
    $g.Dispose()
    return $bmp
}

# --- assemble the .ico ---------------------------------------------------
# Payload format per size is NOT a free choice. GDI+ (System.Drawing.Icon, and
# anything built on it) cannot decode a PNG-compressed entry - it reads the PNG
# bytes as a DIB and renders noise, which is exactly what a first pass of this
# script produced at 16-48px. The shell's own loader handles PNG fine, but half
# the things that will ever draw this icon are not the shell. So: uncompressed
# 32-bit BGRA DIBs up to 64px (the sizes the taskbar, Alt+Tab and Explorer
# actually use), PNG only for 128/256 where the size saving is real and the
# consumers are modern.
function Get-IconDib {
    param([System.Drawing.Bitmap]$Bitmap)

    $w = $Bitmap.Width; $h = $Bitmap.Height
    $rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
    $data = $Bitmap.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
                             [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $pixels = New-Object byte[] ($data.Stride * $h)
    [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $pixels, 0, $pixels.Length)
    $stride = $data.Stride
    $Bitmap.UnlockBits($data)

    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    # BITMAPINFOHEADER - biHeight is doubled because it covers XOR + AND masks.
    $bw.Write([UInt32]40); $bw.Write([Int32]$w); $bw.Write([Int32]($h * 2))
    $bw.Write([UInt16]1);  $bw.Write([UInt16]32); $bw.Write([UInt32]0)
    $bw.Write([UInt32]0);  $bw.Write([Int32]0);   $bw.Write([Int32]0)
    $bw.Write([UInt32]0);  $bw.Write([UInt32]0)
    # XOR bitmap, bottom-up.
    for ($y = $h - 1; $y -ge 0; $y--) { $bw.Write($pixels, $y * $stride, $w * 4) }
    # AND mask: 1bpp, 4-byte aligned rows, all zero. The alpha channel does the
    # real masking; a zeroed AND mask just means "no legacy transparency".
    $maskStride = [int](([Math]::Floor(($w + 31) / 32)) * 4)
    $bw.Write((New-Object byte[] ($maskStride * $h)), 0, $maskStride * $h)
    $bw.Flush()
    $bytes = $ms.ToArray()
    $bw.Dispose(); $ms.Dispose()
    # Unary comma: without it PowerShell unrolls the byte[] into the pipeline
    # and the caller gets an Object[] of boxed bytes. Its .Length still reads
    # correct, so the icon directory looked right while BinaryWriter silently
    # took the char[] overload and wrote UTF-8 garbage for every payload.
    return ,$bytes
}

$entries = @()
foreach ($s in $SIZES) {
    $bmp = New-TimiBitmap -Size $s
    if ($s -ge 128) {
        $ms = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $bytes = $ms.ToArray()
        $ms.Dispose()
    } else {
        $bytes = Get-IconDib -Bitmap $bmp
    }
    $entries += , @{ Size = $s; Bytes = [byte[]]$bytes }
    $bmp.Dispose()
}

$out = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter($out)
$bw.Write([UInt16]0)               # reserved
$bw.Write([UInt16]1)               # type: icon
$bw.Write([UInt16]$entries.Count)

# 6-byte header + 16 bytes per directory entry, then the payloads back to back.
$offset = 6 + (16 * $entries.Count)
foreach ($p in $entries) {
    # 256 is encoded as 0 in the single-byte width/height fields.
    $dim = [byte]($(if ($p.Size -ge 256) { 0 } else { $p.Size }))
    $bw.Write($dim)                # width
    $bw.Write($dim)                # height
    $bw.Write([byte]0)             # palette count (0 = truecolour)
    $bw.Write([byte]0)             # reserved
    $bw.Write([UInt16]1)           # colour planes
    $bw.Write([UInt16]32)          # bits per pixel
    $bw.Write([UInt32]$p.Bytes.Length)
    $bw.Write([UInt32]$offset)
    $offset += $p.Bytes.Length
}
foreach ($p in $entries) { $bw.Write($p.Bytes) }
$bw.Flush()

[System.IO.File]::WriteAllBytes($OutPath, $out.ToArray())
$bw.Dispose(); $out.Dispose()

# Also drop the 256px PNG next to it - handy for eyeballing the mark without
# an icon viewer, and for anything that wants a PNG (shortcut previews, docs).
$big = New-TimiBitmap -Size 256
$big.Save("$([System.IO.Path]::ChangeExtension($OutPath,'png'))", [System.Drawing.Imaging.ImageFormat]::Png)
$big.Dispose()

Write-Output ("wrote {0} ({1} bytes, {2} sizes)" -f $OutPath, (Get-Item $OutPath).Length, $entries.Count)
