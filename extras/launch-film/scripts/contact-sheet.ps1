<#
.SYNOPSIS
    Lays PNG frames out on one contact sheet, each labelled with its file name.
    powershell -STA -File scripts\contact-sheet.ps1 -Dir build\stills\16x9 -Output build\sheet.png
#>
param([string] $Dir, [string] $Output, [int] $Cols = 5, [int] $ThumbW = 480)
Add-Type -AssemblyName PresentationCore, WindowsBase
$files = @(Get-ChildItem -LiteralPath $Dir -Filter *.png | Sort-Object Name)
if (-not $files) { throw "No PNG files in $Dir" }
$first = New-Object System.Windows.Media.Imaging.BitmapImage (New-Object Uri $files[0].FullName)
$thumbH = [int] ($ThumbW * $first.PixelHeight / $first.PixelWidth)
$rows = [math]::Ceiling($files.Count / $Cols)
$cellH = $thumbH + 26
$dv = New-Object System.Windows.Media.DrawingVisual
$dc = $dv.RenderOpen()
$dc.DrawRectangle([System.Windows.Media.Brushes]::Black, $null, (New-Object System.Windows.Rect 0, 0, ($Cols * $ThumbW), ($rows * $cellH)))
for ($i = 0; $i -lt $files.Count; $i++) {
    $img = New-Object System.Windows.Media.Imaging.BitmapImage
    $img.BeginInit(); $img.CacheOption = 'OnLoad'; $img.DecodePixelWidth = $ThumbW; $img.UriSource = New-Object Uri $files[$i].FullName; $img.EndInit()
    $x = ($i % $Cols) * $ThumbW; $y = [math]::Floor($i / $Cols) * $cellH
    $dc.DrawImage($img, (New-Object System.Windows.Rect ($x + 2), ($y + 24), ($ThumbW - 4), ($thumbH - 2)))
    $label = New-Object System.Windows.Media.FormattedText($files[$i].BaseName, [Globalization.CultureInfo]::InvariantCulture, 'LeftToRight', (New-Object System.Windows.Media.Typeface 'Consolas'), 16, [System.Windows.Media.Brushes]::Gold, 1.0)
    $dc.DrawText($label, (New-Object System.Windows.Point ($x + 6), ($y + 3)))
}
$dc.Close()
$rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap(($Cols * $ThumbW), ($rows * $cellH), 96, 96, 'Pbgra32')
$rtb.Render($dv)
$enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
$enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
$fs = [IO.File]::Create($Output); $enc.Save($fs); $fs.Close()
"Contact sheet: $Output ($($files.Count) frames)"
