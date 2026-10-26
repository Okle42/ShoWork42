# 產生 ShoWork.Win\ShoWork42.ico：深色終端機視窗＋外圍綠色光暈，16–256 px 各一張（256 用 PNG，其餘用未壓縮 DIB，舊程式也讀得懂）。
# 用法：powershell -ExecutionPolicy Bypass -File make_icon.ps1
Add-Type -AssemblyName System.Drawing
$out = Join-Path $PSScriptRoot '..\ShoWork.Win\ShoWork42.ico'
function Rounded($g, $x, $y, $w, $h, $r) {
  $p = New-Object Drawing.Drawing2D.GraphicsPath
  $d = [float](2 * $r)
  $p.AddArc($x, $y, $d, $d, 180, 90); $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
  $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90); $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90); $p.CloseFigure()
  return $p
}
$pngs = foreach ($s in 16, 24, 32, 48, 64, 128, 256) {
  $bmp = New-Object Drawing.Bitmap $s, $s, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode = 'AntiAlias'; $g.Clear([Drawing.Color]::Transparent)
  $pad = [Math]::Max(2, [int]($s * 0.14)); $w = $s - 2 * $pad; $h = [int]($w * 0.78); $y = [int](($s - $h) / 2)
  $glow = [Drawing.Color]::FromArgb(0x30, 0xD1, 0x58)
  for ($i = $pad; $i -ge 1; $i--) {                                   # soft glow, fading outwards
    $t = 1 - $i / [float]($pad + 1); $a = [int](170 * $t * $t)
    $pen = New-Object Drawing.Pen ([Drawing.Color]::FromArgb($a, $glow)), 1.6
    $path = Rounded $g ($pad - $i) ($y - $i) ($w + 2 * $i) ($h + 2 * $i) ([Math]::Max(2, $s * 0.08) + $i)
    $g.DrawPath($pen, $path); $pen.Dispose(); $path.Dispose()
  }
  $body = Rounded $g $pad $y $w $h ([Math]::Max(2, $s * 0.08))
  $g.FillPath((New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(0x1F, 0x24, 0x2E))), $body)
  $g.DrawPath((New-Object Drawing.Pen $glow, ([Math]::Max(1, $s / 32.0))), $body)
  if ($s -ge 24) {                                                    # a prompt: ›_
    $pen = New-Object Drawing.Pen ([Drawing.Color]::FromArgb(235, 255, 255, 255)), ([Math]::Max(1.5, $s / 20.0))
    $pen.StartCap = 'Round'; $pen.EndCap = 'Round'; $pen.LineJoin = 'Round'
    $cx = $pad + $w * 0.22; $cy = $y + $h * 0.5; $k = $h * 0.16
    $g.DrawLines($pen, [Drawing.PointF[]]@((New-Object Drawing.PointF $cx, ($cy - $k)), (New-Object Drawing.PointF ($cx + $k), $cy), (New-Object Drawing.PointF $cx, ($cy + $k))))
    $g.DrawLine($pen, [float]($cx + $k * 1.6), [float]($cy + $k), [float]($cx + $k * 3.4), [float]($cy + $k))
  }
  $g.Dispose()
  $ms = New-Object IO.MemoryStream
  if ($s -eq 256) { $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png) }
  else {
    # BITMAPINFOHEADER (height doubled: XOR + AND mask), 32-bit BGRA rows bottom-up, then an all-zero AND mask
    $w2 = New-Object IO.BinaryWriter $ms
    $w2.Write([uint32]40); $w2.Write([int32]$s); $w2.Write([int32](2 * $s)); $w2.Write([uint16]1); $w2.Write([uint16]32)
    $w2.Write([uint32]0); $w2.Write([uint32]0); $w2.Write([int32]0); $w2.Write([int32]0); $w2.Write([uint32]0); $w2.Write([uint32]0)
    for ($yy = $s - 1; $yy -ge 0; $yy--) { for ($xx = 0; $xx -lt $s; $xx++) { $c = $bmp.GetPixel($xx, $yy); $w2.Write([byte]$c.B); $w2.Write([byte]$c.G); $w2.Write([byte]$c.R); $w2.Write([byte]$c.A) } }
    $maskRow = [int]([Math]::Ceiling($s / 32.0) * 4); $w2.Write((New-Object byte[] ($maskRow * $s)))
    $w2.Flush()
  }
  $bmp.Dispose()
  , @($s, $ms.ToArray())
}
$f = New-Object IO.BinaryWriter ([IO.File]::Create($out))
$f.Write([uint16]0); $f.Write([uint16]1); $f.Write([uint16]$pngs.Count)
$offset = 6 + 16 * $pngs.Count
foreach ($p in $pngs) {
  $s = $p[0]; $data = $p[1]
  $f.Write([byte]($s % 256)); $f.Write([byte]($s % 256)); $f.Write([byte]0); $f.Write([byte]0)
  $f.Write([uint16]1); $f.Write([uint16]32); $f.Write([uint32]$data.Length); $f.Write([uint32]$offset)
  $offset += $data.Length
}
foreach ($p in $pngs) { $f.Write([byte[]]$p[1]) }
$f.Close()
"wrote $out ($((Get-Item $out).Length) bytes)"
