<#
.SYNOPSIS
    Draws the looping pixel-art animation at the top of the README: docs\assets\hero.gif

.DESCRIPTION
    Photos fly from a phone into a laptop, the copy is checked, the phone frees up - and it all
    starts again. Drawn at a small size and scaled up with hard pixel edges, so it looks like
    pixel art and the GIF stays small. Nothing to install.

    powershell -STA -ExecutionPolicy Bypass -File extras\video-tools\make-banner.ps1
#>
[CmdletBinding()]
param(
    [string] $Output = '',
    [int] $Fps = 12,
    [double] $Seconds = 6.0,
    [int] $Scale = 3
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)   # this script lives in extras\video-tools
if (-not $Output) { $Output = Join-Path $Root 'docs\assets\hero.gif' }
Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase

$SW = 320; $SH = 110                 # the pixel canvas
$W = $SW * $Scale; $H = $SH * $Scale  # the GIF

function Brush([string] $Hex) { $b = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($Hex)); $b.Freeze(); return $b }
function Box($dc, $Brush, [double] $X, [double] $Y, [double] $Wd, [double] $Ht) { $dc.DrawRectangle($Brush, $null, (New-Object System.Windows.Rect ([math]::Round($X)), ([math]::Round($Y)), $Wd, $Ht)) }
function Ease([double] $t) { $t = [math]::Max(0, [math]::Min(1, $t)); return $t * $t * (3 - 2 * $t) }
function Clamp01([double] $t) { return [math]::Max(0, [math]::Min(1, $t)) }

$Sky = @((Brush '#0B1220'), (Brush '#0F1830'), (Brush '#131F3D'), (Brush '#18264A'))
$Star = Brush '#CBD5E1'; $StarDim = Brush '#64748B'
$Ground = Brush '#0A0F1C'; $GroundLine = Brush '#1E293B'
$Body = Brush '#475569'; $BodyLight = Brush '#64748B'; $Screen = Brush '#0F172A'; $Slot = Brush '#1E293B'
$Bar = Brush '#3B82F6'; $BarBack = Brush '#1E293B'; $Green = Brush '#22C55E'; $Scan = Brush '#93C5FD'
$Photos = @('#60A5FA', '#F472B6', '#FBBF24', '#34D399', '#A78BFA', '#F87171') | ForEach-Object { Brush $_ }
$Light = Brush '#F8FAFC'

$random = New-Object System.Random 7
$stars = 1..26 | ForEach-Object { @{ X = $random.Next(2, $SW - 2); Y = $random.Next(2, 70); P = $random.NextDouble() * 6.28; Big = ($random.Next(0, 5) -eq 0) } }

# where things are
$Phone = @{ X = 30; Y = 22; W = 30; H = 60 }
$Laptop = @{ X = 202; Y = 18; W = 92; H = 58 }
$Count = 12
function PhoneSlot([int] $i) { return @{ X = $Phone.X + 5 + ($i % 3) * 7; Y = $Phone.Y + 9 + [math]::Floor($i / 3) * 10 } }
function LaptopSlot([int] $i) { return @{ X = $Laptop.X + 10 + ($i % 4) * 19; Y = $Laptop.Y + 8 + [math]::Floor($i / 4) * 13 } }

function Draw-Photo($dc, [int] $i, [double] $X, [double] $Y, [double] $Alpha = 1.0) {
    $dc.PushOpacity($Alpha)
    Box $dc $Photos[$i % $Photos.Count] $X $Y 6 5
    Box $dc $Light $X $Y 1 1
    Box $dc $Screen ($X + 3) ($Y + 3) 2 1
    $dc.Pop()
}

function Draw-Frame([double] $t) {
    # t: seconds into the 6-second loop. Copy 0-4.1, check 4.1-4.6, free up 4.6-5.3, reset 5.4-6.
    $dv = New-Object System.Windows.Media.DrawingVisual
    [System.Windows.Media.RenderOptions]::SetEdgeMode($dv, [System.Windows.Media.EdgeMode]::Aliased)
    $dc = $dv.RenderOpen()
    # sky in bands, twinkling stars, the ground
    for ($b = 0; $b -lt 4; $b++) { Box $dc $Sky[$b] 0 ($b * 22) $SW 22 }
    foreach ($s in $stars) {
        $on = [math]::Sin($t * 2.2 + $s.P)
        if ($on -gt -0.2) { Box $dc $(if ($on -gt 0.55) { $Star } else { $StarDim }) $s.X $s.Y 1 1 }
        if ($s.Big -and $on -gt 0.75) { Box $dc $StarDim ($s.X - 1) $s.Y 3 1; Box $dc $StarDim $s.X ($s.Y - 1) 1 3; Box $dc $Star $s.X $s.Y 1 1 }
    }
    Box $dc $Ground 0 88 $SW ($SH - 88)
    Box $dc $GroundLine 0 88 $SW 1

    $reset = Ease (($t - 5.4) / 0.5)                 # 0 -> 1 while everything starts over
    # the phone
    Box $dc $BodyLight ($Phone.X - 1) ($Phone.Y - 1) ($Phone.W + 2) ($Phone.H + 2)
    Box $dc $Body $Phone.X $Phone.Y $Phone.W $Phone.H
    Box $dc $Screen ($Phone.X + 3) ($Phone.Y + 5) ($Phone.W - 6) ($Phone.H - 11)
    Box $dc $BodyLight ($Phone.X + 12) ($Phone.Y + 2) 6 1
    for ($i = 0; $i -lt $Count; $i++) {
        $p = PhoneSlot $i
        Box $dc $Slot $p.X $p.Y 6 5
        $freed = Ease (($t - (4.7 + $i * 0.05)) / 0.15)   # freed up after the check
        $alpha = 1 - $freed
        if ($t -ge 5.4) { $alpha = $reset }
        if ($alpha -gt 0.02) { Draw-Photo $dc $i $p.X $p.Y $alpha }
    }
    # the phone's storage bar: full, then empty after freeing up
    $full = 1 - 0.85 * (Ease (($t - 4.7) / 0.7)); if ($t -ge 5.4) { $full = 0.15 + 0.85 * $reset }
    Box $dc $BarBack ($Phone.X + 4) ($Phone.Y + $Phone.H - 5) ($Phone.W - 8) 2
    Box $dc $(if ($full -gt 0.5) { (Brush '#F59E0B') } else { $Green }) ($Phone.X + 4) ($Phone.Y + $Phone.H - 5) ([math]::Max(1, [math]::Round(($Phone.W - 8) * $full))) 2

    # the laptop
    Box $dc $BodyLight ($Laptop.X - 1) ($Laptop.Y - 1) ($Laptop.W + 2) ($Laptop.H + 2)
    Box $dc $Body $Laptop.X $Laptop.Y $Laptop.W $Laptop.H
    Box $dc $Screen ($Laptop.X + 4) ($Laptop.Y + 4) ($Laptop.W - 8) ($Laptop.H - 8)
    Box $dc $BodyLight ($Laptop.X - 9) ($Laptop.Y + $Laptop.H + 1) ($Laptop.W + 18) 4
    Box $dc $Body ($Laptop.X + 36) ($Laptop.Y + $Laptop.H + 1) 20 1

    # photos fly over, one after another, in an arc
    $landed = 0
    for ($i = 0; $i -lt $Count; $i++) {
        $start = 0.35 + $i * 0.28
        $u = ($t - $start) / 0.95
        $l = LaptopSlot $i
        if ($u -ge 1) {
            $landed++
            $alpha = 1 - $reset
            if ($alpha -gt 0.02) { Box $dc $Slot ($l.X - 1) ($l.Y - 1) 14 9; $dc.PushOpacity($alpha); Draw-Photo $dc $i ($l.X + 3) ($l.Y + 1); $dc.Pop() }
        }
        else {
            Box $dc $Slot ($l.X - 1) ($l.Y - 1) 14 9
            if ($u -gt 0) {
                $p = PhoneSlot $i
                $e = Ease $u
                $x = $p.X + (($l.X + 3) - $p.X) * $e
                $y = $p.Y + (($l.Y + 1) - $p.Y) * $e - [math]::Sin([math]::PI * $e) * 30
                # a short trail
                $dc.PushOpacity(0.35); Box $dc $Photos[$i % $Photos.Count] ($x - 4 * (1 - $e)) ($y + 2) 2 1; $dc.Pop()
                Draw-Photo $dc $i $x $y
            }
        }
    }
    # progress bar: how many have landed
    $progress = $landed / $Count
    if ($t -ge 5.4) { $progress = $progress * (1 - $reset) }
    Box $dc $BarBack ($Laptop.X + 10) ($Laptop.Y + $Laptop.H - 10) ($Laptop.W - 20) 3
    if ($progress -gt 0) { Box $dc $(if ($t -ge 4.5 -and $t -lt 5.4) { $Green } else { $Bar }) ($Laptop.X + 10) ($Laptop.Y + $Laptop.H - 10) ([math]::Max(1, [math]::Round(($Laptop.W - 20) * $progress))) 3 }

    # the check: a light sweeps over every copy
    if ($t -ge 4.1 -and $t -lt 4.6) {
        $sx = $Laptop.X + 6 + ($Laptop.W - 14) * (($t - 4.1) / 0.5)
        $dc.PushOpacity(0.55); Box $dc $Scan $sx ($Laptop.Y + 5) 2 ($Laptop.H - 17); $dc.Pop()
    }
    # a green tick above the laptop once everything matched
    $tick = (Ease (($t - 4.55) / 0.2)) * (1 - $reset)
    if ($tick -gt 0.02) {
        $cx = $Laptop.X + $Laptop.W / 2; $cy = $Laptop.Y - 8
        $dc.PushOpacity($tick)
        Box $dc $Green ($cx - 5) ($cy - 5) 11 11
        Box $dc $Light ($cx - 3) $cy 1 1; Box $dc $Light ($cx - 2) ($cy + 1) 1 1; Box $dc $Light ($cx - 1) ($cy + 2) 1 1
        Box $dc $Light $cx ($cy + 1) 1 1; Box $dc $Light ($cx + 1) $cy 1 1; Box $dc $Light ($cx + 2) ($cy - 1) 1 1; Box $dc $Light ($cx + 3) ($cy - 2) 1 1
        $dc.Pop()
    }
    $dc.Close()
    return $dv
}

function Draw-Labels($dc, [double] $t) {
    # Crisp text on top, at full size: the three stages, the current one lit.
    $face = New-Object System.Windows.Media.Typeface (New-Object System.Windows.Media.FontFamily 'Consolas'), ([System.Windows.FontStyles]::Normal), ([System.Windows.FontWeights]::Bold), ([System.Windows.FontStretches]::Normal)
    $stage = 0; if ($t -ge 4.1) { $stage = 1 }; if ($t -ge 4.65) { $stage = 2 }; if ($t -ge 5.4) { $stage = -1 }
    $parts = @('COPY', '>', 'CHECK', '>', 'FREE UP')
    $active = Brush '#FBBF24'; $idle = Brush '#475569'; $arrow = Brush '#334155'
    $texts = @()
    for ($k = 0; $k -lt $parts.Count; $k++) {
        $b = $idle
        if ($parts[$k] -eq '>') { $b = $arrow } elseif ([math]::Floor($k / 2) -eq $stage) { $b = $active }
        $texts += New-Object System.Windows.Media.FormattedText $parts[$k], ([Globalization.CultureInfo]::InvariantCulture), ([System.Windows.FlowDirection]::LeftToRight), $face, 26, $b
    }
    $total = 0; foreach ($x in $texts) { $total += $x.Width + 18 }
    $x0 = ($W - $total + 18) / 2
    foreach ($x in $texts) { $dc.DrawText($x, (New-Object System.Windows.Point $x0, ($H - 52))); $x0 += $x.Width + 18 }
    if ($t -ge 4.55 -and $t -lt 5.4) {
        $badge = New-Object System.Windows.Media.FormattedText 'ALL FILES VERIFIED', ([Globalization.CultureInfo]::InvariantCulture), ([System.Windows.FlowDirection]::LeftToRight), $face, 20, (Brush '#22C55E')
        $a = Ease (($t - 4.55) / 0.2)
        $dc.PushOpacity($a)
        # left of the green tick, on its line
        $dc.DrawText($badge, (New-Object System.Windows.Point (($Laptop.X + $Laptop.W / 2 - 9) * $Scale - $badge.Width), (($Laptop.Y - 8) * $Scale - $badge.Height / 2)))
        $dc.Pop()
    }
}

# The GIF is written here directly: a fixed palette (the scene's own colours, so no dithering
# noise), only the pixels that changed since the previous frame, exact frame times, and the
# "loop forever" flag that Windows' own GIF encoder leaves out.
if (-not ('PixelGif' -as [type])) {
    Add-Type -TypeDefinition @"
using System; using System.Collections.Generic; using System.IO;
public static class PixelGif
{
    // BGRA pixels to palette indexes (nearest colour).
    public static byte[] Index(byte[] bgra, int[] palette)
    {
        byte[] o = new byte[bgra.Length / 4];
        Dictionary<int, byte> cache = new Dictionary<int, byte>();
        for (int i = 0; i < o.Length; i++)
        {
            int b = bgra[i * 4], g = bgra[i * 4 + 1], r = bgra[i * 4 + 2];
            int key = (r << 16) | (g << 8) | b;
            byte idx;
            if (!cache.TryGetValue(key, out idx))
            {
                int best = int.MaxValue;
                for (int p = 0; p < palette.Length; p++)
                {
                    int pr = (palette[p] >> 16) & 255, pg = (palette[p] >> 8) & 255, pb = palette[p] & 255;
                    int d = (pr - r) * (pr - r) + (pg - g) * (pg - g) + (pb - b) * (pb - b);
                    if (d < best) { best = d; idx = (byte)p; }
                }
                cache[key] = idx;
            }
            o[i] = idx;
        }
        return o;
    }

    public static void Write(string path, int w, int h, List<byte[]> frames, int[] palette, int delayCs)
    {
        const byte Clear = 255;   // the transparent index: "same as before"
        using (BinaryWriter bw = new BinaryWriter(File.Create(path)))
        {
            bw.Write(System.Text.Encoding.ASCII.GetBytes("GIF89a"));
            bw.Write((ushort)w); bw.Write((ushort)h);
            bw.Write((byte)0xF7); bw.Write((byte)0); bw.Write((byte)0);
            for (int p = 0; p < 256; p++)
            {
                int c = p < palette.Length ? palette[p] : 0;
                bw.Write((byte)((c >> 16) & 255)); bw.Write((byte)((c >> 8) & 255)); bw.Write((byte)(c & 255));
            }
            bw.Write(new byte[] { 0x21, 0xFF, 0x0B }); bw.Write(System.Text.Encoding.ASCII.GetBytes("NETSCAPE2.0"));
            bw.Write(new byte[] { 3, 1, 0, 0, 0 });
            byte[] previous = null;
            int pending = 0;
            for (int f = 0; f < frames.Count; f++)
            {
                byte[] cur = frames[f];
                int x0 = 0, y0 = 0, x1 = w - 1, y1 = h - 1;
                if (previous != null)
                {
                    x0 = w; y0 = h; x1 = -1; y1 = -1;
                    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++)
                        if (cur[y * w + x] != previous[y * w + x]) { if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y; }
                    if (x1 < 0) { pending += delayCs; continue; }   // nothing changed: the last frame just stays longer
                }
                int fw = x1 - x0 + 1, fh = y1 - y0 + 1;
                byte[] sub = new byte[fw * fh];
                for (int y = 0; y < fh; y++) for (int x = 0; x < fw; x++)
                {
                    int k = (y + y0) * w + x + x0;
                    sub[y * fw + x] = (previous != null && cur[k] == previous[k]) ? Clear : cur[k];
                }
                // the delay of the frame before goes on that frame: patch it now
                if (pending > 0 && f > 0) { /* folded into this frame's own delay below */ }
                bw.Write(new byte[] { 0x21, 0xF9, 4, (byte)(previous == null ? 0x04 : 0x05) });
                bw.Write((ushort)(delayCs + pending)); pending = 0;
                bw.Write(Clear); bw.Write((byte)0);
                bw.Write((byte)0x2C); bw.Write((ushort)x0); bw.Write((ushort)y0); bw.Write((ushort)fw); bw.Write((ushort)fh); bw.Write((byte)0);
                bw.Write((byte)8);
                byte[] data = Lzw(sub);
                for (int i = 0; i < data.Length; i += 255) { int n = Math.Min(255, data.Length - i); bw.Write((byte)n); bw.Write(data, i, n); }
                bw.Write((byte)0);
                previous = cur;
            }
            bw.Write((byte)0x3B);
        }
    }

    // GIF's LZW, 8-bit codes, the classic encoder's code-size rules.
    static byte[] Lzw(byte[] pixels)
    {
        const int initBits = 9, clearCode = 256, eoi = 257, maxCodes = 4096;
        MemoryStream outp = new MemoryStream();
        int bits = initBits, maxCode = (1 << bits) - 1, next = eoi + 1;
        long acc = 0; int accBits = 0; bool clearFlag = false;
        Dictionary<int, int> dict = new Dictionary<int, int>();
        Action<int> output = delegate (int code)
        {
            acc |= (long)code << accBits; accBits += bits;
            while (accBits >= 8) { outp.WriteByte((byte)(acc & 255)); acc >>= 8; accBits -= 8; }
            if (next > maxCode || clearFlag)
            {
                if (clearFlag) { bits = initBits; maxCode = (1 << bits) - 1; clearFlag = false; }
                else { bits++; maxCode = bits == 12 ? maxCodes : (1 << bits) - 1; }
            }
        };
        output(clearCode);
        int prefix = pixels[0];
        for (int i = 1; i < pixels.Length; i++)
        {
            int k = pixels[i];
            int key = (prefix << 8) | k;
            int code;
            if (dict.TryGetValue(key, out code)) { prefix = code; continue; }
            output(prefix);
            prefix = k;
            if (next < maxCodes) dict[key] = next++;
            else { dict.Clear(); next = eoi + 1; clearFlag = true; output(clearCode); }
        }
        output(prefix);
        output(eoi);
        if (accBits > 0) outp.WriteByte((byte)(acc & 255));
        return outp.ToArray();
    }
}
"@
}

$Palette = @('#0B1220', '#0F1830', '#131F3D', '#18264A', '#CBD5E1', '#64748B', '#0A0F1C', '#1E293B', '#475569', '#0F172A',
             '#3B82F6', '#22C55E', '#93C5FD', '#60A5FA', '#F472B6', '#FBBF24', '#34D399', '#A78BFA', '#F87171', '#F8FAFC',
             '#F59E0B', '#334155') | ForEach-Object { [Convert]::ToInt32($_.Substring(1), 16) }
$indexed = New-Object 'System.Collections.Generic.List[byte[]]'
$frames = [int] ($Fps * $Seconds)
$delay = [int] [math]::Round(100.0 / $Fps)   # in hundredths of a second
$pixels = New-Object byte[] ($W * $H * 4)
for ($f = 0; $f -lt $frames; $f++) {
    $t = $f / $Fps
    $small = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($SW, $SH, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $small.Render((Draw-Frame $t))
    # scaled up with hard pixel edges; the text is drawn hard-edged too
    $big = New-Object System.Windows.Media.DrawingVisual
    [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($big, [System.Windows.Media.BitmapScalingMode]::NearestNeighbor)
    [System.Windows.Media.TextOptions]::SetTextRenderingMode($big, [System.Windows.Media.TextRenderingMode]::Aliased)
    $dc = $big.RenderOpen()
    $dc.DrawImage($small, (New-Object System.Windows.Rect 0, 0, $W, $H))
    Draw-Labels $dc $t
    $dc.Close()
    $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($W, $H, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($big)
    $rtb.CopyPixels($pixels, $W * 4, 0)
    $indexed.Add([PixelGif]::Index($pixels, $Palette))
}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Output) | Out-Null
[PixelGif]::Write($Output, $W, $H, $indexed, $Palette, $delay)
Write-Host ("Animation written: {0}  ({1} frames, {2}x{3}, {4:N0} KB)" -f $Output, $frames, $W, $H, ((Get-Item -LiteralPath $Output).Length / 1KB))
