$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$root = Split-Path -Parent $PSScriptRoot
$appDir = Join-Path $root 'app'
$size = 256

$bmp = New-Object System.Drawing.Bitmap($size, $size)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
$g.Clear([System.Drawing.Color]::Transparent)

function New-RoundedPath([System.Drawing.RectangleF]$rect, [float]$radius) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $radius * 2
    $p.AddArc($rect.X, $rect.Y, $d, $d, 180, 90)
    $p.AddArc($rect.Right - $d, $rect.Y, $d, $d, 270, 90)
    $p.AddArc($rect.Right - $d, $rect.Bottom - $d, $d, $d, 0, 90)
    $p.AddArc($rect.X, $rect.Bottom - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

$bgRect = New-Object System.Drawing.RectangleF(14, 14, 228, 228)
$bgPath = New-RoundedPath $bgRect 52
$grad = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
    $bgRect,
    [System.Drawing.ColorTranslator]::FromHtml('#1E3A5F'),
    [System.Drawing.ColorTranslator]::FromHtml('#2563EB'),
    45
)
$g.FillPath($grad, $bgPath)

$bubbleRect = New-Object System.Drawing.RectangleF(48, 52, 160, 114)
$bubblePath = New-RoundedPath $bubbleRect 24
$g.FillPath([System.Drawing.Brushes]::White, $bubblePath)

$tail = [System.Drawing.PointF[]]@(
    (New-Object System.Drawing.PointF(92, 158)),
    (New-Object System.Drawing.PointF(140, 158)),
    (New-Object System.Drawing.PointF(106, 200))
)
$g.FillPolygon([System.Drawing.Brushes]::White, $tail)

$navy = [System.Drawing.ColorTranslator]::FromHtml('#1E3A5F')
$green = [System.Drawing.ColorTranslator]::FromHtml('#059669')
$penOuter = New-Object System.Drawing.Pen($navy, 9)
$g.DrawEllipse($penOuter, 104, 82, 50, 50)
$penHand = New-Object System.Drawing.Pen($green, 8)
$penHand.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
$penHand.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
$g.DrawLine($penHand, 129, 107, 129, 90)
$g.DrawLine($penHand, 129, 107, 143, 114)

$iconPng = Join-Path $appDir 'icon.png'
$bmp.Save($iconPng, [System.Drawing.Imaging.ImageFormat]::Png)

$penOuter.Dispose(); $penHand.Dispose(); $grad.Dispose(); $bgPath.Dispose(); $bubblePath.Dispose()
$g.Dispose(); $bmp.Dispose()

# Build a PNG-compressed ICO (256x256)
$pngBytes = [System.IO.File]::ReadAllBytes($iconPng)
$ms = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter($ms)
$bw.Write([UInt16]0)
$bw.Write([UInt16]1)
$bw.Write([UInt16]1)
$bw.Write([Byte]0)
$bw.Write([Byte]0)
$bw.Write([Byte]0)
$bw.Write([Byte]0)
$bw.Write([UInt16]1)
$bw.Write([UInt16]32)
$bw.Write([UInt32]$pngBytes.Length)
$bw.Write([UInt32]22)
$bw.Write($pngBytes)
$bw.Flush()
[System.IO.File]::WriteAllBytes((Join-Path $appDir 'app.ico'), $ms.ToArray())
$bw.Close()
$ms.Close()

Write-Host ('Icon created: ' + (Join-Path $appDir 'app.ico'))
