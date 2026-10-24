# What the Smart Transfer and Smart Cleanup windows share: the look (styles), the building
# blocks of a kiosk-style screen (big choices, info cards, rows of facts), the sidebar of
# answers, the footer, and small helpers. Dot-sourced by each window script.
#
# A window script that uses it provides:
#   $AppTitle, $window, $ui, $app (with .Page), $AutoPilot, $Invariant, $DOT, $CHECK
#   $STAGES (Title / Pages / Go per step of the sidebar) and $StageUi (an ArrayList)
#   Show-Step, Test-CanGoBack, Get-StageAnswer, Invoke-Tile (what a big choice does), Write-UiLog
#   For screenshots: $ScreenshotDir and $auto (with .Shot)

# The styles go inside <Window.Resources> of each window's XAML (in place of __KIOSK_STYLES__).
$KioskStyles = @'
    <Style x:Key="H1" TargetType="TextBlock">
      <Setter Property="FontSize" Value="30"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="#0F172A"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <Style x:Key="Sub" TargetType="TextBlock">
      <Setter Property="FontSize" Value="16"/>
      <Setter Property="Foreground" Value="#64748B"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="Margin" Value="0,8,0,0"/>
    </Style>
    <Style x:Key="Label" TargetType="TextBlock">
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="#64748B"/>
    </Style>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="White"/>
      <Setter Property="CornerRadius" Value="14"/>
      <Setter Property="Padding" Value="20,16"/>
      <Setter Property="BorderBrush" Value="#E2E8F0"/>
      <Setter Property="BorderThickness" Value="1"/>
    </Style>
    <Style x:Key="Icon" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <Style x:Key="BaseButton" TargetType="Button">
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="22,10"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="10" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.88"/></Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="b" Property="Background" Value="#E2E8F0"/>
                <Setter TargetName="b" Property="BorderBrush" Value="#E2E8F0"/>
                <Setter Property="Foreground" Value="#94A3B8"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource BaseButton}">
      <Setter Property="Background" Value="#2563EB"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="BorderThickness" Value="0"/>
    </Style>
    <Style x:Key="Danger" TargetType="Button" BasedOn="{StaticResource BaseButton}">
      <Setter Property="Background" Value="#DC2626"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="BorderThickness" Value="0"/>
    </Style>
    <Style x:Key="Secondary" TargetType="Button" BasedOn="{StaticResource BaseButton}">
      <Setter Property="Background" Value="White"/>
      <Setter Property="Foreground" Value="#0F172A"/>
      <Setter Property="BorderBrush" Value="#CBD5E1"/>
      <Setter Property="BorderThickness" Value="1"/>
    </Style>
    <Style x:Key="Link" TargetType="Button">
      <Setter Property="Foreground" Value="#2563EB"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <TextBlock x:Name="t" Text="{TemplateBinding Content}" Foreground="{TemplateBinding Foreground}" Background="Transparent"/>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="t" Property="TextDecorations" Value="Underline"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="t" Property="Foreground" Value="#94A3B8"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="SideLink" TargetType="Button" BasedOn="{StaticResource Link}">
      <Setter Property="Foreground" Value="#93C5FD"/>
      <Setter Property="FontSize" Value="13"/>
    </Style>
    <!-- a big choice: one click answers the question -->
    <Style x:Key="Tile" TargetType="Button">
      <Setter Property="Background" Value="White"/>
      <Setter Property="BorderBrush" Value="#E2E8F0"/>
      <Setter Property="BorderThickness" Value="2"/>
      <Setter Property="Padding" Value="22,20"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="16" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Stretch"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="BorderBrush" Value="#93C5FD"/>
                <Setter TargetName="b" Property="Background" Value="#F8FBFF"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="#60A5FA"/></Trigger>
              <Trigger Property="Tag" Value="selected">
                <Setter TargetName="b" Property="BorderBrush" Value="#2563EB"/>
                <Setter TargetName="b" Property="Background" Value="#EFF6FF"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.55"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <!-- one answer in the sidebar; clickable once answered -->
    <Style x:Key="StageButton" TargetType="Button">
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="Transparent" CornerRadius="10" Padding="10,9">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#1E293B"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ProgressBar">
      <Setter Property="Height" Value="10"/>
      <Setter Property="Foreground" Value="#2563EB"/>
      <Setter Property="Background" Value="#E2E8F0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Grid>
              <Border x:Name="PART_Track" Background="{TemplateBinding Background}" CornerRadius="6"/>
              <Border x:Name="PART_Indicator" Background="{TemplateBinding Foreground}" CornerRadius="6" HorizontalAlignment="Left"/>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="DataGrid">
      <Setter Property="AutoGenerateColumns" Value="False"/>
      <Setter Property="CanUserAddRows" Value="False"/>
      <Setter Property="CanUserDeleteRows" Value="False"/>
      <Setter Property="CanUserResizeRows" Value="False"/>
      <Setter Property="CanUserReorderColumns" Value="False"/>
      <Setter Property="IsReadOnly" Value="True"/>
      <Setter Property="SelectionMode" Value="Single"/>
      <Setter Property="HeadersVisibility" Value="Column"/>
      <Setter Property="GridLinesVisibility" Value="Horizontal"/>
      <Setter Property="HorizontalGridLinesBrush" Value="#EEF2F7"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Background" Value="White"/>
      <Setter Property="RowBackground" Value="White"/>
      <Setter Property="MinRowHeight" Value="46"/>
      <Setter Property="FontSize" Value="13"/>
    </Style>
    <Style TargetType="DataGridColumnHeader">
      <Setter Property="Background" Value="#F8FAFC"/>
      <Setter Property="Foreground" Value="#64748B"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Padding" Value="10,9"/>
      <Setter Property="BorderBrush" Value="#E2E8F0"/>
      <Setter Property="BorderThickness" Value="0,0,0,1"/>
    </Style>
    <Style TargetType="DataGridCell">
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="10,0"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="DataGridCell">
            <Border Padding="{TemplateBinding Padding}" Background="Transparent">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="IsSelected" Value="True">
          <Setter Property="Foreground" Value="#0F172A"/>
          <Setter Property="Background" Value="Transparent"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="DataGridRow">
      <Setter Property="ToolTip" Value="{Binding Note}"/>
      <Style.Triggers>
        <Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="#EFF6FF"/></Trigger>
        <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#F8FAFC"/></Trigger>
      </Style.Triggers>
    </Style>
'@

# ---------------------------------------------------------------------------
# formatting
# ---------------------------------------------------------------------------

function Format-Bytes {
    param([double] $Bytes)
    if ($Bytes -lt 1024) { return ('{0} B' -f [int64] $Bytes) }
    $value = $Bytes
    foreach ($unit in 'KB', 'MB', 'GB', 'TB') {
        $value = $value / 1024
        if ($value -lt 1024 -or $unit -eq 'TB') { return ($value.ToString('N1', $Invariant) + ' ' + $unit) }
    }
}

function Format-Count { param([int64] $N) return $N.ToString('N0', $Invariant) }

function Format-Plural {
    param([int64] $N, [string] $One, [string] $Many)
    if ($N -eq 1) { return "1 $One" }
    return ('{0} {1}' -f (Format-Count $N), $Many)
}

function Format-Eta {
    param([double] $Seconds)
    if ($Seconds -lt 0) { return '' }
    if ($Seconds -lt 60) { return 'less than a minute' }
    $minutes = [math]::Ceiling($Seconds / 60)
    if ($minutes -lt 60) { return "about $minutes min" }
    $hours = [math]::Floor($minutes / 60); $rest = $minutes % 60
    if ($rest -eq 0) { return "about $hours h" }
    return "about $hours h $rest min"
}

function Format-ShortPath {
    # Long paths are shortened in running text, keeping the drive and the last folders:
    # C:\...\Pictures\iPhone Photos. Screens that are about the path show it in full.
    param([string] $Path, [int] $Max = 48)
    if (-not $Path -or $Path.Length -le $Max) { return $Path }
    $root = [System.IO.Path]::GetPathRoot($Path)
    $parts = @($Path.Substring($root.Length).Split('\') | Where-Object { $_ })
    $tail = ''
    for ($i = $parts.Count - 1; $i -ge 0; $i--) {
        $candidate = $parts[$i]
        if ($tail) { $candidate += '\' + $tail }
        if ($tail -and ($root.Length + 4 + $candidate.Length) -gt $Max) { break }
        $tail = $candidate
    }
    return $root.TrimEnd('\') + '\...\' + $tail
}

# ---------------------------------------------------------------------------
# messages, dialogs, files and drives
# ---------------------------------------------------------------------------

function Show-Message {
    param([string] $Text, [string] $Title = $AppTitle, [string] $Icon = 'Information')
    Write-UiLog "message: $Text"
    if ($AutoPilot) { return }
    [void] [System.Windows.MessageBox]::Show($window, $Text, $Title, 'OK', $Icon)
}

function Confirm-Action {
    param([string] $Text, [string] $Title = $AppTitle, [string] $Icon = 'Question')
    if ($AutoPilot) { Write-UiLog "auto-confirmed: $Text"; return $true }
    $answer = [System.Windows.MessageBox]::Show($window, $Text, $Title, 'YesNo', $Icon, 'No')
    return ($answer -eq 'Yes')
}

function Invoke-Safely {
    param([scriptblock] $Action)
    try { & $Action }
    catch {
        Write-UiLog ("window error: {0} {1}" -f $_.Exception.Message, $_.ScriptStackTrace)
        Show-Message ("Something went wrong: " + $_.Exception.Message) $AppTitle 'Warning'
    }
}

function Select-FolderDialog {
    param([string] $Description, [string] $Start)
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = $Description
    $dialog.ShowNewFolderButton = $true
    if ($Start -and (Test-Path -LiteralPath $Start)) { $dialog.SelectedPath = $Start }
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dialog.SelectedPath }
    return ''
}

function Open-Path {
    param([string] $Path)
    if ($AutoPilot) { Write-UiLog "would open: $Path"; return }
    if ($Path -and (Test-Path -LiteralPath $Path)) { Start-Process -FilePath $Path }
}

function Set-Color { param($Element, [string] $Property, [string] $Color) $Element.$Property = (New-Object System.Windows.Media.BrushConverter).ConvertFromString($Color) }

function Get-SafeName {
    param([string] $Name)
    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    $safe = (-join ($Name.ToCharArray() | ForEach-Object { if ($invalid -contains $_) { '_' } else { $_ } })).TrimEnd('.', ' ')
    if (-not $safe) { $safe = 'unnamed' }
    return $safe
}

function Test-DriveRoot { param([string] $Path) return ($Path.TrimEnd('\') -eq ([System.IO.Path]::GetPathRoot($Path)).TrimEnd('\')) }

function Get-DriveTitle {
    # "Local Disk (C:)", "USB drive (E:)", or the drive's own name.
    param($Drive)
    $label = ''
    try { $label = $Drive.VolumeLabel } catch { }
    if (-not $label) {
        switch ([string] $Drive.DriveType) {
            'Removable' { $label = 'USB drive' }
            'Network'   { $label = 'Network drive' }
            default     { $label = 'Local Disk' }
        }
    }
    return ('{0} ({1})' -f $label, $Drive.Name.TrimEnd('\'))
}

function Get-UsableDrives {
    param([string[]] $Types = @('Fixed', 'Removable', 'Network'))
    return @([System.IO.DriveInfo]::GetDrives() | Where-Object { $Types -contains [string] $_.DriveType -and $_.IsReady })
}

# ---------------------------------------------------------------------------
# building blocks: big choices, info cards, rows of facts
# ---------------------------------------------------------------------------

function New-Text {
    param([string] $Text, [double] $Size = 14, [string] $Color = '#0F172A', [string] $Weight = 'Normal', [string] $Margin = '0')
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Text; $t.FontSize = $Size; $t.FontWeight = $Weight; $t.TextWrapping = 'Wrap'; $t.Margin = $Margin
    Set-Color $t 'Foreground' $Color
    return $t
}

function New-IconCircle {
    param([string] $Icon, [double] $Size = 56, [string] $Accent = '#2563EB', [string] $Back = '#DBEAFE')
    $circle = New-Object System.Windows.Controls.Border
    $circle.Width = $Size; $circle.Height = $Size; $circle.CornerRadius = [string] ($Size / 2)
    $circle.HorizontalAlignment = 'Left'; $circle.VerticalAlignment = 'Top'
    Set-Color $circle 'Background' $Back
    $glyph = New-Object System.Windows.Controls.TextBlock
    $glyph.Style = $window.FindResource('Icon')
    $glyph.Text = $Icon; $glyph.FontSize = [math]::Round($Size * 0.45); $glyph.HorizontalAlignment = 'Center'
    Set-Color $glyph 'Foreground' $Accent
    $circle.Child = $glyph
    return $circle
}

function New-Badge {
    param([string] $Text, [string] $Back = '#DCFCE7', [string] $Fore = '#166534')
    $b = New-Object System.Windows.Controls.Border
    $b.CornerRadius = '10'; $b.Padding = '9,2'; $b.Margin = '10,0,0,0'; $b.VerticalAlignment = 'Center'
    Set-Color $b 'Background' $Back
    $b.Child = New-Text -Text $Text -Size 11 -Color $Fore -Weight 'Bold'
    return $b
}

function New-MiniBar {
    # A thin bar: how full a drive is.
    param([double] $Fraction)
    $grid = New-Object System.Windows.Controls.Grid
    $grid.Height = 6; $grid.Margin = '0,10,0,0'; $grid.MaxWidth = 360; $grid.HorizontalAlignment = 'Left'; $grid.Width = 360
    $back = New-Object System.Windows.Controls.Border; $back.CornerRadius = '3'; Set-Color $back 'Background' '#E2E8F0'
    $fill = New-Object System.Windows.Controls.Border; $fill.CornerRadius = '3'; $fill.HorizontalAlignment = 'Left'
    $fill.Width = 360 * [math]::Max(0.02, [math]::Min(1.0, $Fraction))
    if ($Fraction -gt 0.9) { Set-Color $fill 'Background' '#DC2626' } else { Set-Color $fill 'Background' '#64748B' }
    [void] $grid.Children.Add($back); [void] $grid.Children.Add($fill)
    return $grid
}

function New-Tile {
    # One big choice. Clicking it answers the question (Invoke-Tile). -Wide lays it out as a
    # row (icon, text, arrow) for lists of choices; otherwise it is a tall card for a grid.
    param(
        [string] $Action, [string] $Icon, [string] $Title, [string] $Text = '', [string] $Extra = '',
        [string] $Badge = '', [string] $Accent = '#2563EB', [string] $AccentBack = '#DBEAFE',
        [switch] $Wide, [switch] $Selected, [double] $Bar = -1
    )
    $button = New-Object System.Windows.Controls.Button
    $button.Style = $window.FindResource('Tile')
    $button.CommandParameter = $Action
    if ($Selected) { $button.Tag = 'selected' }

    $texts = New-Object System.Windows.Controls.StackPanel
    # Badges on the right, the title fills the rest - so a long title wraps instead of being cut.
    $titleRow = New-Object System.Windows.Controls.DockPanel
    $titleSize = 20; if ($Wide) { $titleSize = 17 }
    $badges = @()
    if ($Selected) { $badges += (New-Badge 'Your choice' '#DBEAFE' '#1E40AF') }
    if ($Badge) { $badges += (New-Badge $Badge) }
    foreach ($b in $badges) { $b.VerticalAlignment = 'Top'; $b.Margin = '10,3,0,0'; [System.Windows.Controls.DockPanel]::SetDock($b, 'Right'); [void] $titleRow.Children.Add($b) }
    [void] $titleRow.Children.Add((New-Text -Text $Title -Size $titleSize -Weight 'SemiBold'))
    [void] $texts.Children.Add($titleRow)
    if ($Text) { [void] $texts.Children.Add((New-Text -Text $Text -Size 14 -Color '#64748B' -Margin '0,5,0,0')) }
    if ($Extra) { [void] $texts.Children.Add((New-Text -Text $Extra -Size 13 -Color '#334155' -Weight 'SemiBold' -Margin '0,7,0,0')) }
    if ($Bar -ge 0) { [void] $texts.Children.Add((New-MiniBar $Bar)) }

    if ($Wide) {
        $button.Margin = '0,0,0,12'
        $button.Padding = '20,16'
        $grid = New-Object System.Windows.Controls.Grid
        foreach ($w in 'Auto', '*', 'Auto') {
            $c = New-Object System.Windows.Controls.ColumnDefinition
            $c.Width = (New-Object System.Windows.GridLengthConverter).ConvertFromString($w)
            [void] $grid.ColumnDefinitions.Add($c)
        }
        $circle = New-IconCircle -Icon $Icon -Size 52 -Accent $Accent -Back $AccentBack
        $texts.Margin = '18,2,12,0'; $texts.VerticalAlignment = 'Center'
        [System.Windows.Controls.Grid]::SetColumn($texts, 1)
        $arrow = New-Object System.Windows.Controls.TextBlock
        $arrow.Style = $window.FindResource('Icon'); $arrow.Text = [string] [char] 0xE76C; $arrow.FontSize = 16
        Set-Color $arrow 'Foreground' '#94A3B8'
        [System.Windows.Controls.Grid]::SetColumn($arrow, 2)
        [void] $grid.Children.Add($circle); [void] $grid.Children.Add($texts); [void] $grid.Children.Add($arrow)
        $button.Content = $grid
    }
    else {
        $button.Margin = '8'
        $button.Padding = '24,26'
        $button.MinHeight = 230
        $stack = New-Object System.Windows.Controls.StackPanel
        [void] $stack.Children.Add((New-IconCircle -Icon $Icon -Size 64 -Accent $Accent -Back $AccentBack))
        $texts.Margin = '0,22,0,0'
        [void] $stack.Children.Add($texts)
        $button.Content = $stack
    }
    $button.Add_Click({ param($s, $e) Invoke-Safely { Invoke-Tile ([string] $s.CommandParameter) } })
    return $button
}

function New-InfoCard {
    # Not a choice - something to know, with at most one button.
    param([string] $Icon, [string] $Title, [string] $Text, [string] $Tone = 'amber', [string] $ButtonText = '', [string] $ButtonAction = '')
    $colors = @{ amber = @('#FFFBEB', '#FCD34D', '#B45309', '#78350F', '#92400E'); blue = @('#EFF6FF', '#BFDBFE', '#2563EB', '#1E3A8A', '#1E40AF'); green = @('#F0FDF4', '#86EFAC', '#16A34A', '#14532D', '#166534') }[$Tone]
    $card = New-Object System.Windows.Controls.Border
    $card.CornerRadius = '14'; $card.Padding = '20,16'; $card.Margin = '0,0,0,12'; $card.BorderThickness = '1'
    Set-Color $card 'Background' $colors[0]; Set-Color $card 'BorderBrush' $colors[1]
    $dock = New-Object System.Windows.Controls.DockPanel
    $glyph = New-Object System.Windows.Controls.TextBlock
    $glyph.Style = $window.FindResource('Icon'); $glyph.Text = $Icon; $glyph.FontSize = 22; $glyph.VerticalAlignment = 'Top'; $glyph.Margin = '0,2,14,0'
    Set-Color $glyph 'Foreground' $colors[2]
    [System.Windows.Controls.DockPanel]::SetDock($glyph, 'Left')
    [void] $dock.Children.Add($glyph)
    $texts = New-Object System.Windows.Controls.StackPanel
    [void] $texts.Children.Add((New-Text -Text $Title -Size 16 -Color $colors[3] -Weight 'SemiBold'))
    if ($Text) { [void] $texts.Children.Add((New-Text -Text $Text -Size 14 -Color $colors[4] -Margin '0,4,0,0')) }
    if ($ButtonText) {
        $b = New-Object System.Windows.Controls.Button
        $b.Style = $window.FindResource('Secondary'); $b.Content = $ButtonText; $b.Padding = '16,8'; $b.Margin = '0,12,0,0'; $b.HorizontalAlignment = 'Left'
        $b.CommandParameter = $ButtonAction
        $b.Add_Click({ param($s, $e) Invoke-Safely { Invoke-Tile ([string] $s.CommandParameter) } })
        [void] $texts.Children.Add($b)
    }
    [void] $dock.Children.Add($texts)
    $card.Child = $dock
    return $card
}

function New-FactRow {
    # A row in a card: icon, a label, the value, a line of detail - and optionally "Change".
    param([string] $Icon, [string] $Label, [string] $Value, [string] $Detail = '', [string] $Change = '', [switch] $Last, [string] $Accent = '#2563EB', [string] $AccentBack = '#DBEAFE')
    $row = New-Object System.Windows.Controls.Border
    $row.Padding = '22,16'
    if (-not $Last) { $row.BorderThickness = '0,0,0,1'; Set-Color $row 'BorderBrush' '#EEF2F7' }
    $grid = New-Object System.Windows.Controls.Grid
    foreach ($w in 'Auto', '*', 'Auto') {
        $c = New-Object System.Windows.Controls.ColumnDefinition
        $c.Width = (New-Object System.Windows.GridLengthConverter).ConvertFromString($w)
        [void] $grid.ColumnDefinitions.Add($c)
    }
    $circle = New-IconCircle -Icon $Icon -Size 42 -Accent $Accent -Back $AccentBack
    $texts = New-Object System.Windows.Controls.StackPanel
    $texts.Margin = '16,0,12,0'; $texts.VerticalAlignment = 'Center'
    if ($Label) { [void] $texts.Children.Add((New-Text -Text $Label.ToUpperInvariant() -Size 11 -Color '#64748B' -Weight 'Bold')) }
    [void] $texts.Children.Add((New-Text -Text $Value -Size 16 -Weight 'SemiBold' -Margin '0,2,0,0'))
    if ($Detail) { [void] $texts.Children.Add((New-Text -Text $Detail -Size 13 -Color '#64748B' -Margin '0,2,0,0')) }
    [System.Windows.Controls.Grid]::SetColumn($texts, 1)
    [void] $grid.Children.Add($circle); [void] $grid.Children.Add($texts)
    if ($Change) {
        $b = New-Object System.Windows.Controls.Button
        $b.Style = $window.FindResource('Secondary'); $b.Content = 'Change'; $b.Padding = '16,7'; $b.FontSize = 13; $b.VerticalAlignment = 'Center'
        $b.CommandParameter = 'goto:' + $Change
        $b.Add_Click({ param($s, $e) Invoke-Safely { Invoke-Tile ([string] $s.CommandParameter) } })
        [System.Windows.Controls.Grid]::SetColumn($b, 2)
        [void] $grid.Children.Add($b)
    }
    $row.Child = $grid
    return $row
}

# ---------------------------------------------------------------------------
# the sidebar of answers and the footer
# ---------------------------------------------------------------------------

function Get-StageIndex {
    param([string] $Page)
    for ($i = 0; $i -lt $STAGES.Count; $i++) { if ($STAGES[$i].Pages -contains $Page) { return $i } }
    return 0
}

function Initialize-StageList {
    # (Again whenever $STAGES changes.)
    $ui.StageList.Children.Clear()
    $StageUi.Clear()
    for ($i = 0; $i -lt $STAGES.Count; $i++) {
        $button = New-Object System.Windows.Controls.Button
        $button.Style = $window.FindResource('StageButton')
        $button.CommandParameter = $i
        $button.Margin = '0,0,0,4'
        $grid = New-Object System.Windows.Controls.Grid
        foreach ($w in 'Auto', '*') {
            $c = New-Object System.Windows.Controls.ColumnDefinition
            $c.Width = (New-Object System.Windows.GridLengthConverter).ConvertFromString($w)
            [void] $grid.ColumnDefinitions.Add($c)
        }
        $dot = New-Object System.Windows.Controls.Border
        $dot.Width = 28; $dot.Height = 28; $dot.CornerRadius = '14'; $dot.VerticalAlignment = 'Top'
        $num = New-Text -Text ([string] ($i + 1)) -Size 13 -Weight 'SemiBold'
        $num.HorizontalAlignment = 'Center'; $num.VerticalAlignment = 'Center'
        $dot.Child = $num
        $texts = New-Object System.Windows.Controls.StackPanel
        $texts.Margin = '12,3,0,0'
        $title = New-Text -Text $STAGES[$i].Title -Size 14 -Weight 'SemiBold'
        $answer = New-Text -Text '' -Size 12 -Color '#94A3B8' -Margin '0,2,0,0'
        $answer.TextTrimming = 'CharacterEllipsis'; $answer.MaxHeight = 34
        $change = New-Text -Text 'Change' -Size 11 -Color '#93C5FD' -Weight 'SemiBold' -Margin '0,3,0,0'
        [void] $texts.Children.Add($title); [void] $texts.Children.Add($answer); [void] $texts.Children.Add($change)
        [System.Windows.Controls.Grid]::SetColumn($texts, 1)
        [void] $grid.Children.Add($dot); [void] $grid.Children.Add($texts)
        $button.Content = $grid
        $button.Add_Click({ param($s, $e) Invoke-Safely { $stage = $STAGES[[int] $s.CommandParameter]; if ($stage.Go -and (Test-CanGoBack)) { Show-Step $stage.Go } } })
        [void] $ui.StageList.Children.Add($button)
        [void] $StageUi.Add(@{ Button = $button; Dot = $dot; Num = $num; Title = $title; Answer = $answer; Change = $change })
    }
}

function Update-StageList {
    $current = Get-StageIndex $app.Page
    $canGo = Test-CanGoBack
    for ($i = 0; $i -lt $StageUi.Count; $i++) {
        $s = $StageUi[$i]
        $answer = Get-StageAnswer $i
        $s.Answer.Text = $answer
        if ($answer) { $s.Answer.Visibility = 'Visible' } else { $s.Answer.Visibility = 'Collapsed' }
        $clickable = ($i -lt $current) -and $canGo -and [bool] $STAGES[$i].Go
        $s.Button.IsHitTestVisible = $clickable
        if ($clickable) { $s.Button.Cursor = [System.Windows.Input.Cursors]::Hand; $s.Change.Visibility = 'Visible' }
        else { $s.Button.Cursor = [System.Windows.Input.Cursors]::Arrow; $s.Change.Visibility = 'Collapsed' }
        if ($i -lt $current) {
            Set-Color $s.Dot 'Background' '#16A34A'; $s.Num.Text = $CHECK; Set-Color $s.Num 'Foreground' 'White'; Set-Color $s.Title 'Foreground' '#E2E8F0'
        }
        elseif ($i -eq $current) {
            Set-Color $s.Dot 'Background' '#2563EB'; $s.Num.Text = [string] ($i + 1); Set-Color $s.Num 'Foreground' 'White'; Set-Color $s.Title 'Foreground' 'White'
        }
        else {
            Set-Color $s.Dot 'Background' '#1E293B'; $s.Num.Text = [string] ($i + 1); Set-Color $s.Num 'Foreground' '#64748B'; Set-Color $s.Title 'Foreground' '#64748B'
        }
    }
}

function Set-Footer {
    # Back bottom left, the next step bottom right, an optional second action next to it.
    param([string] $Back = 'Back', [string] $Next = '', [bool] $NextEnabled = $true, [string] $Alt = '', [string] $Text = '', [string] $NextStyle = 'Primary')
    if ($Back) { $ui.BackButton.Content = ([string] [char] 0x2190) + '  ' + $Back; $ui.BackButton.Visibility = 'Visible'; $ui.BackButton.IsEnabled = $true }
    else { $ui.BackButton.Visibility = 'Hidden' }
    if ($Next) {
        $ui.NextButton.Style = $window.FindResource($NextStyle)
        $ui.NextButton.Content = $Next; $ui.NextButton.Visibility = 'Visible'; $ui.NextButton.IsEnabled = $NextEnabled
    }
    else { $ui.NextButton.Visibility = 'Collapsed' }
    if ($Alt) { $ui.AltButton.Content = $Alt; $ui.AltButton.Visibility = 'Visible'; $ui.AltButton.IsEnabled = $true }
    else { $ui.AltButton.Visibility = 'Collapsed' }
    $ui.FooterText.Text = $Text
}

# ---------------------------------------------------------------------------
# testing aid
# ---------------------------------------------------------------------------

function Save-Screenshot {
    param([string] $Name)
    if (-not $ScreenshotDir) { return }
    try {
        New-Item -ItemType Directory -Force -Path $ScreenshotDir | Out-Null
        $window.UpdateLayout()
        $content = $window.Content
        $w = [int] $content.ActualWidth; $h = [int] $content.ActualHeight
        $bitmap = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($w, $h, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
        $bitmap.Render($content)
        $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
        $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
        $auto.Shot++
        $stream = [System.IO.File]::Create((Join-Path $ScreenshotDir ('{0:00}-{1}.png' -f $auto.Shot, $Name)))
        $encoder.Save($stream); $stream.Close()
    }
    catch { Write-UiLog "screenshot failed: $($_.Exception.Message)" }
}

function Invoke-Click {
    param($Button)
    $Button.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
}
