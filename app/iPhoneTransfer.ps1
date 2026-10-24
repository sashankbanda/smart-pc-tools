<#
.SYNOPSIS
    iPhone Transfer - a simple window that copies photos and videos off an iPhone, checks
    every file, and only then offers to free up space on the phone.

.DESCRIPTION
    Five steps, one screen each:
      1. Connect      plug in, unlock, Trust - the app finds the phone by itself
      2. Choose       every folder is read and analysed; the PC's free space is shown and
                      whole folders that fit are recommended (oldest first)
      3. Copy         live progress, pause / stop, survives unplugging, resumes later
      4. Check        every file on the phone is compared with its copy on the PC
      5. Free up      delete from the phone - only folders where every file matched

    Start it by double-clicking "iPhone Transfer.cmd" next to this folder.

.PARAMETER SourceFolder
    Use a folder on this PC (an SD card, a camera, an old backup) instead of an iPhone.

.PARAMETER Destination
    Start with this destination instead of the last one used.

.PARAMETER AutoPilot
    Testing aid: walk through the steps by itself. -AutoStopAfter says where to stop;
    deleting automatically is only ever allowed together with -SourceFolder.
#>

[CmdletBinding()]
param(
    [string] $SourceFolder = '',
    [string] $Destination = '',
    [switch] $AutoPilot,
    [string[]] $AutoFolders = @(),
    [ValidateSet('Analyze', 'Copy', 'Check', 'Delete')]
    [string] $AutoStopAfter = 'Check',
    [switch] $AutoFullCheck,
    [switch] $AutoInterrupt,
    [switch] $AutoCompare,
    [switch] $AutoTrouble,
    [string] $ScreenshotDir = '',

    # Tutorial recording: a folder of made-up photos plays the part of the iPhone, and the
    # steps are walked through by tools\make-tutorial.ps1. Never needed for real use.
    [string] $DemoPhone = '',
    [switch] $Tutorial
)

$ErrorActionPreference = 'Stop'
$AutoFolders = @($AutoFolders | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
if ($Tutorial) {
    if (-not $DemoPhone -or -not $Destination -or -not $ScreenshotDir) { throw '-Tutorial needs -DemoPhone, -Destination and -ScreenshotDir (it never runs on a real phone).' }
    $AutoPilot = $true
}

# The app is started without a console window, so a problem at start-up would otherwise
# vanish without a word. Say what happened instead.
Add-Type -AssemblyName PresentationFramework
trap {
    $message = $_.Exception.Message
    try {
        $dir = Join-Path $env:LOCALAPPDATA 'iPhoneTransfer\logs'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Add-Content -LiteralPath (Join-Path $dir 'startup-errors.log') -Value ('{0}  {1}  {2}' -f (Get-Date), $message, $_.ScriptStackTrace)
    }
    catch { }
    if (-not $AutoPilot) { [void] [System.Windows.MessageBox]::Show("iPhone Transfer stopped because of a problem:`r`n`r`n$message", 'iPhone Transfer', 'OK', 'Error') }
    break
}

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    throw 'Please start iPhone Transfer with "iPhone Transfer.cmd" (it needs powershell -STA).'
}
if ($AutoPilot -and $AutoStopAfter -eq 'Delete' -and -not $SourceFolder) {
    throw 'Automatic deleting is only allowed with -SourceFolder - never on a real phone.'
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
if (-not ('IPhoneTransferApp.Native' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'Native.cs') }

$Invariant = [System.Globalization.CultureInfo]::InvariantCulture
$DOT = ' ' + [char] 0x00B7 + ' '
$RESERVE = 2GB          # keep this much free on the PC when recommending
$DEFAULT_SPEED = 20MB   # bytes per second, until we have measured this phone

# ---------------------------------------------------------------------------
# settings and logs
# ---------------------------------------------------------------------------

$SettingsDir  = Join-Path $env:APPDATA 'iPhoneTransfer'
$SettingsPath = Join-Path $SettingsDir 'settings.json'
$LogDir       = Join-Path $env:LOCALAPPDATA 'iPhoneTransfer\logs'
$LogPath      = Join-Path $LogDir ('app-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

function Get-Settings {
    $s = @{ LastDestination = ''; Speed = [double] $DEFAULT_SPEED }
    try {
        if (Test-Path -LiteralPath $SettingsPath) {
            $j = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json
            if ($j.LastDestination) { $s.LastDestination = [string] $j.LastDestination }
            if ($j.Speed -gt 1MB) { $s.Speed = [double] $j.Speed }
        }
    }
    catch { }
    return $s
}

function Save-Settings {
    if ($AutoPilot) { return }   # test runs must not change what a real user sees next time
    try {
        New-Item -ItemType Directory -Force -Path $SettingsDir | Out-Null
        $data = @{ LastDestination = $app.Dest; Speed = $app.Speed }
        [System.IO.File]::WriteAllText($SettingsPath, ($data | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
    }
    catch { }
}

# ---------------------------------------------------------------------------
# the window
# ---------------------------------------------------------------------------

[xml] $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="iPhone Transfer" Width="1200" Height="800" MinWidth="1000" MinHeight="680"
        WindowStartupLocation="CenterScreen" FontFamily="Segoe UI" FontSize="14"
        Foreground="#0F172A" Background="#F1F5F9" UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    <Style x:Key="H1" TargetType="TextBlock">
      <Setter Property="FontSize" Value="26"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="#0F172A"/>
    </Style>
    <Style x:Key="Sub" TargetType="TextBlock">
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Foreground" Value="#64748B"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="Margin" Value="0,4,0,0"/>
    </Style>
    <Style x:Key="Label" TargetType="TextBlock">
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="#64748B"/>
    </Style>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="White"/>
      <Setter Property="CornerRadius" Value="12"/>
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
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8" Padding="{TemplateBinding Padding}">
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
    <Style x:Key="Small" TargetType="Button" BasedOn="{StaticResource Secondary}">
      <Setter Property="Padding" Value="12,5"/>
      <Setter Property="FontSize" Value="13"/>
    </Style>
    <Style x:Key="Link" TargetType="Button">
      <Setter Property="Foreground" Value="#2563EB"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <TextBlock x:Name="t" Text="{TemplateBinding Content}" Foreground="{TemplateBinding Foreground}"/>
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
    </Style>
    <Style TargetType="ProgressBar">
      <Setter Property="Height" Value="10"/>
      <Setter Property="Foreground" Value="#2563EB"/>
      <Setter Property="Background" Value="#E2E8F0"/>
      <Setter Property="BorderThickness" Value="0"/>
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
      <Setter Property="MinRowHeight" Value="40"/>
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
      <Style.Triggers>
        <Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="#EFF6FF"/></Trigger>
        <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#F8FAFC"/></Trigger>
      </Style.Triggers>
    </Style>
  </Window.Resources>

  <Grid Background="#F1F5F9">
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="250"/>
      <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>

    <!-- sidebar -->
    <Border Grid.Column="0" Background="#0F172A">
      <DockPanel Margin="24,28,20,22">
        <StackPanel DockPanel.Dock="Top">
          <StackPanel Orientation="Horizontal">
            <Border Width="38" Height="38" CornerRadius="10" Background="#1D4ED8">
              <TextBlock Style="{StaticResource Icon}" Text="&#xE8EA;" FontSize="20" Foreground="White" HorizontalAlignment="Center"/>
            </Border>
            <StackPanel Margin="12,0,0,0" VerticalAlignment="Center">
              <TextBlock Text="iPhone Transfer" FontSize="18" FontWeight="SemiBold" Foreground="White"/>
              <TextBlock Text="Copy, check, then free up" FontSize="12" Foreground="#94A3B8"/>
            </StackPanel>
          </StackPanel>
          <StackPanel Margin="0,36,0,0">
            <Grid Margin="0,0,0,22">
              <Grid.ColumnDefinitions><ColumnDefinition Width="32"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <Border x:Name="Step0Dot" Width="30" Height="30" CornerRadius="15" Background="#1E293B" VerticalAlignment="Top">
                <TextBlock x:Name="Step0Num" Text="1" Foreground="#94A3B8" FontWeight="SemiBold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
              <StackPanel Grid.Column="1" Margin="12,0,0,0">
                <TextBlock x:Name="Step0Title" Text="Connect" Foreground="#CBD5E1" FontWeight="SemiBold"/>
                <TextBlock x:Name="Step0Sub" Text="Plug in your iPhone" Foreground="#64748B" FontSize="12" TextWrapping="Wrap"/>
              </StackPanel>
            </Grid>
            <Grid Margin="0,0,0,22">
              <Grid.ColumnDefinitions><ColumnDefinition Width="32"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <Border x:Name="Step1Dot" Width="30" Height="30" CornerRadius="15" Background="#1E293B" VerticalAlignment="Top">
                <TextBlock x:Name="Step1Num" Text="2" Foreground="#94A3B8" FontWeight="SemiBold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
              <StackPanel Grid.Column="1" Margin="12,0,0,0">
                <TextBlock x:Name="Step1Title" Text="Choose folders" Foreground="#CBD5E1" FontWeight="SemiBold"/>
                <TextBlock x:Name="Step1Sub" Text="See what is on it" Foreground="#64748B" FontSize="12" TextWrapping="Wrap"/>
              </StackPanel>
            </Grid>
            <Grid Margin="0,0,0,22">
              <Grid.ColumnDefinitions><ColumnDefinition Width="32"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <Border x:Name="Step2Dot" Width="30" Height="30" CornerRadius="15" Background="#1E293B" VerticalAlignment="Top">
                <TextBlock x:Name="Step2Num" Text="3" Foreground="#94A3B8" FontWeight="SemiBold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
              <StackPanel Grid.Column="1" Margin="12,0,0,0">
                <TextBlock x:Name="Step2Title" Text="Copy" Foreground="#CBD5E1" FontWeight="SemiBold"/>
                <TextBlock x:Name="Step2Sub" Text="To this PC" Foreground="#64748B" FontSize="12" TextWrapping="Wrap"/>
              </StackPanel>
            </Grid>
            <Grid Margin="0,0,0,22">
              <Grid.ColumnDefinitions><ColumnDefinition Width="32"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <Border x:Name="Step3Dot" Width="30" Height="30" CornerRadius="15" Background="#1E293B" VerticalAlignment="Top">
                <TextBlock x:Name="Step3Num" Text="4" Foreground="#94A3B8" FontWeight="SemiBold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
              <StackPanel Grid.Column="1" Margin="12,0,0,0">
                <TextBlock x:Name="Step3Title" Text="Check" Foreground="#CBD5E1" FontWeight="SemiBold"/>
                <TextBlock x:Name="Step3Sub" Text="Every file compared" Foreground="#64748B" FontSize="12" TextWrapping="Wrap"/>
              </StackPanel>
            </Grid>
            <Grid Margin="0,0,0,22">
              <Grid.ColumnDefinitions><ColumnDefinition Width="32"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <Border x:Name="Step4Dot" Width="30" Height="30" CornerRadius="15" Background="#1E293B" VerticalAlignment="Top">
                <TextBlock x:Name="Step4Num" Text="5" Foreground="#94A3B8" FontWeight="SemiBold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
              <StackPanel Grid.Column="1" Margin="12,0,0,0">
                <TextBlock x:Name="Step4Title" Text="Free up iPhone" Foreground="#CBD5E1" FontWeight="SemiBold"/>
                <TextBlock x:Name="Step4Sub" Text="Optional" Foreground="#64748B" FontSize="12" TextWrapping="Wrap"/>
              </StackPanel>
            </Grid>
          </StackPanel>
        </StackPanel>
        <StackPanel DockPanel.Dock="Bottom" VerticalAlignment="Bottom">
          <Border Background="#1E293B" CornerRadius="10" Padding="14,12" Margin="0,0,0,14">
            <StackPanel>
              <StackPanel Orientation="Horizontal">
                <TextBlock Style="{StaticResource Icon}" Text="&#xEA18;" Foreground="#4ADE80" FontSize="14"/>
                <TextBlock Text="Your files stay on this PC" Foreground="White" FontSize="12" FontWeight="SemiBold" Margin="8,0,0,0"/>
              </StackPanel>
              <TextBlock Text="Nothing is uploaded. Nothing is deleted unless you ask, and only after every file has been checked."
                         Foreground="#94A3B8" FontSize="11" TextWrapping="Wrap" Margin="0,6,0,0"/>
            </StackPanel>
          </Border>
          <Button x:Name="ShortcutButton" Content="Add a desktop shortcut" Style="{StaticResource SideLink}" HorizontalAlignment="Left" Margin="0,0,0,8"/>
          <Button x:Name="OpenLogButton" Content="Open the activity log" Style="{StaticResource SideLink}" HorizontalAlignment="Left"/>
        </StackPanel>
      </DockPanel>
    </Border>

    <!-- pages -->
    <Grid Grid.Column="1" Margin="34,28,34,24">

      <!-- 1. connect -->
      <ScrollViewer x:Name="PageConnect" VerticalScrollBarVisibility="Auto">
        <StackPanel MaxWidth="760" HorizontalAlignment="Left">
          <TextBlock Text="Connect your iPhone" Style="{StaticResource H1}"/>
          <TextBlock Text="The app finds your iPhone by itself as soon as it is plugged in and unlocked." Style="{StaticResource Sub}"/>
          <Border Style="{StaticResource Card}" Margin="0,24,0,0" Padding="24,20">
            <StackPanel>
              <Grid Margin="0,0,0,16">
                <Grid.ColumnDefinitions><ColumnDefinition Width="44"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <Border Width="32" Height="32" CornerRadius="16" Background="#DBEAFE" VerticalAlignment="Top"><TextBlock Text="1" Foreground="#1D4ED8" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
                <StackPanel Grid.Column="1"><TextBlock Text="Plug the iPhone into this PC with its cable" FontWeight="SemiBold" FontSize="15"/><TextBlock Text="A USB port directly on the PC is faster and steadier than a hub." Style="{StaticResource Sub}"/></StackPanel>
              </Grid>
              <Grid Margin="0,0,0,16">
                <Grid.ColumnDefinitions><ColumnDefinition Width="44"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <Border Width="32" Height="32" CornerRadius="16" Background="#DBEAFE" VerticalAlignment="Top"><TextBlock Text="2" Foreground="#1D4ED8" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
                <StackPanel Grid.Column="1"><TextBlock Text="Unlock the iPhone" FontWeight="SemiBold" FontSize="15"/><TextBlock Text="Enter your passcode so the screen shows your home screen." Style="{StaticResource Sub}"/></StackPanel>
              </Grid>
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="44"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <Border Width="32" Height="32" CornerRadius="16" Background="#DBEAFE" VerticalAlignment="Top"><TextBlock Text="3" Foreground="#1D4ED8" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
                <StackPanel Grid.Column="1"><TextBlock Text="Tap &quot;Trust&quot; on the iPhone if it asks" FontWeight="SemiBold" FontSize="15"/><TextBlock Text="&quot;Trust This Computer?&quot; appears the first time. Tap Trust and enter your passcode." Style="{StaticResource Sub}"/></StackPanel>
              </Grid>
            </StackPanel>
          </Border>

          <Border x:Name="ConnectStatusCard" Style="{StaticResource Card}" Margin="0,16,0,0" Padding="24,18">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <Border x:Name="ConnectIconBack" Width="48" Height="48" CornerRadius="24" Background="#F1F5F9">
                <TextBlock x:Name="ConnectIcon" Style="{StaticResource Icon}" Text="&#xE8EA;" FontSize="22" Foreground="#64748B" HorizontalAlignment="Center"/>
              </Border>
              <StackPanel Grid.Column="1" Margin="16,0,0,0" VerticalAlignment="Center">
                <TextBlock x:Name="ConnectTitle" Text="Looking for your iPhone..." FontSize="17" FontWeight="SemiBold"/>
                <TextBlock x:Name="ConnectDetail" Text="Plug it in and unlock it." Style="{StaticResource Sub}"/>
                <ProgressBar x:Name="ConnectBar" IsIndeterminate="True" Height="4" Margin="0,10,0,0" MaxWidth="320" HorizontalAlignment="Left" Width="320"/>
              </StackPanel>
            </Grid>
          </Border>

          <StackPanel Orientation="Horizontal" Margin="0,22,0,0">
            <Button x:Name="ConnectContinue" Content="Continue" Style="{StaticResource Primary}" IsEnabled="False" MinWidth="160"/>
            <Button x:Name="UseFolderButton" Content="Use a folder on this PC instead (SD card, camera)" Style="{StaticResource Link}" Margin="20,0,0,0" VerticalAlignment="Center"/>
          </StackPanel>

          <Expander Header="The iPhone does not show up?" Margin="0,26,0,0" FontSize="13" Foreground="#334155">
            <StackPanel Margin="22,8,0,0">
              <TextBlock TextWrapping="Wrap" Foreground="#475569" LineHeight="21">
                <Run FontWeight="SemiBold">Install Apple Devices</Run><Run Text=" (free, from the Microsoft Store). It adds the driver Windows needs to see an iPhone. You do not need to open it or sign in."/><LineBreak/>
                <Run FontWeight="SemiBold">Unplug and plug back in,</Run><Run Text=" then unlock the phone and watch for the Trust question."/><LineBreak/>
                <Run FontWeight="SemiBold">Try another cable or USB port.</Run><Run Text=" Some cables only charge."/><LineBreak/>
                <Run FontWeight="SemiBold">Tapped &quot;Don't Trust&quot; by mistake?</Run><Run Text=" On the iPhone: Settings > General > Transfer or Reset iPhone > Reset > Reset Location &amp; Privacy, then plug in again."/>
              </TextBlock>
            </StackPanel>
          </Expander>
        </StackPanel>
      </ScrollViewer>

      <!-- 2. analyse and choose -->
      <Grid x:Name="PageAnalyze" Visibility="Collapsed">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <DockPanel Grid.Row="0">
          <StackPanel DockPanel.Dock="Right" VerticalAlignment="Center" Width="300">
            <TextBlock x:Name="ScanStatus" Text="" Foreground="#475569" FontSize="13" TextAlignment="Right" TextWrapping="Wrap"/>
            <ProgressBar x:Name="ScanBar" Height="5" Margin="0,6,0,0" Maximum="100"/>
          </StackPanel>
          <StackPanel>
            <TextBlock x:Name="AnalyzeTitle" Text="What's on your iPhone" Style="{StaticResource H1}"/>
            <TextBlock x:Name="AnalyzeSub" Text="Every folder is being read. Choose the folders to copy - whole folders, so nothing is left behind." Style="{StaticResource Sub}"/>
          </StackPanel>
        </DockPanel>

        <StackPanel Grid.Row="1" Margin="0,16,0,0">
          <WrapPanel x:Name="SummaryChips"/>
          <TextBlock x:Name="TypesText" Foreground="#64748B" FontSize="12" TextWrapping="Wrap" Margin="2,2,0,0"/>
        </StackPanel>

        <Border Grid.Row="2" Style="{StaticResource Card}" Margin="0,14,0,0" Padding="20,14">
          <Grid>
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <DockPanel Grid.Row="0" Grid.Column="0" Margin="0,0,12,10" LastChildFill="True">
              <TextBlock DockPanel.Dock="Left" Style="{StaticResource Icon}" Text="&#xE8EA;" FontSize="18" Foreground="#2563EB" Width="20"/>
              <TextBlock DockPanel.Dock="Left" Text="Copy from" Style="{StaticResource Label}" Margin="10,0,8,0" VerticalAlignment="Center" Width="62"/>
              <TextBlock x:Name="SourceText" Text="" FontWeight="SemiBold" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
            </DockPanel>
            <StackPanel Grid.Row="0" Grid.Column="1" Orientation="Horizontal" Margin="0,0,0,10">
              <Button x:Name="UseIPhoneButton" Content="Use the iPhone" Style="{StaticResource Small}" Margin="0,0,8,0"/>
              <Button x:Name="ChangeSourceButton" Content="Choose a folder..." Style="{StaticResource Small}"/>
            </StackPanel>
            <DockPanel Grid.Row="1" Grid.Column="0" Margin="0,0,12,0" LastChildFill="True">
              <TextBlock DockPanel.Dock="Left" Style="{StaticResource Icon}" Text="&#xE8B7;" FontSize="18" Foreground="#2563EB" Width="20"/>
              <TextBlock DockPanel.Dock="Left" Text="Save to" Style="{StaticResource Label}" Margin="10,0,8,0" VerticalAlignment="Center" Width="62"/>
              <TextBlock x:Name="DestText" Text="" FontWeight="SemiBold" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
            </DockPanel>
            <StackPanel Grid.Row="1" Grid.Column="1" Orientation="Horizontal">
              <Button x:Name="OpenDestButton" Content="Open" Style="{StaticResource Small}" Margin="0,0,8,0"/>
              <Button x:Name="ChangeDestButton" Content="Change..." Style="{StaticResource Small}"/>
            </StackPanel>
            <Grid x:Name="SpaceArea" Grid.Row="2" Grid.ColumnSpan="2" Margin="0,12,0,0" Height="12">
              <Border CornerRadius="6" Background="#E2E8F0"/>
              <Grid x:Name="SpaceBar" ClipToBounds="True">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition x:Name="SpaceUsed" Width="1*"/>
                  <ColumnDefinition x:Name="SpaceNeed" Width="0*"/>
                  <ColumnDefinition x:Name="SpaceFree" Width="1*"/>
                </Grid.ColumnDefinitions>
                <Border Grid.Column="0" Background="#94A3B8" CornerRadius="6,0,0,6"/>
                <Border x:Name="SpaceNeedFill" Grid.Column="1" Background="#2563EB"/>
              </Grid>
            </Grid>
            <TextBlock x:Name="SpaceText" Grid.Row="3" Grid.Column="0" Margin="0,8,0,0" FontSize="13" Foreground="#475569" TextWrapping="Wrap"/>
            <WrapPanel x:Name="DrivePanel" Grid.Row="3" Grid.Column="1" Margin="0,6,0,0" HorizontalAlignment="Right"/>
          </Grid>
        </Border>

        <Border x:Name="RecommendCard" Grid.Row="3" Margin="0,12,0,0" Background="#EFF6FF" BorderBrush="#BFDBFE" BorderThickness="1" CornerRadius="12" Padding="18,12">
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <TextBlock Style="{StaticResource Icon}" Text="&#xE735;" FontSize="18" Foreground="#2563EB" VerticalAlignment="Top" Margin="0,2,0,0"/>
            <StackPanel Grid.Column="1" Margin="12,0,12,0">
              <TextBlock x:Name="RecommendTitle" Text="Reading your folders..." FontWeight="SemiBold" Foreground="#1E3A8A" TextWrapping="Wrap"/>
              <TextBlock x:Name="RecommendText" Text="A recommendation appears once every folder has been read." Foreground="#1E40AF" FontSize="13" TextWrapping="Wrap" Margin="0,2,0,0"/>
            </StackPanel>
            <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
              <Button x:Name="ResumeButton" Content="Continue last copy" Style="{StaticResource Primary}" Padding="14,7" FontSize="13" Margin="0,0,8,0" Visibility="Collapsed"/>
              <Button x:Name="SelectRecommendedButton" Content="Select recommended" Style="{StaticResource Small}" IsEnabled="False"/>
            </StackPanel>
          </Grid>
        </Border>

        <Border Grid.Row="4" Style="{StaticResource Card}" Margin="0,12,0,0" Padding="0">
          <Grid>
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
            <DockPanel Margin="16,10,16,6">
              <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                <Button x:Name="SelectAllButton" Content="Select all" Style="{StaticResource Link}" Margin="0,0,16,0"/>
                <Button x:Name="SelectNoneButton" Content="Clear selection" Style="{StaticResource Link}" Margin="0,0,16,0"/>
                <Button x:Name="RescanButton" Content="Read again" Style="{StaticResource Link}" ToolTip="Read every folder again, for example after unlocking the iPhone"/>
              </StackPanel>
              <TextBlock x:Name="FolderListLabel" Text="Folders on the iPhone" Style="{StaticResource Label}" VerticalAlignment="Center"/>
            </DockPanel>
            <DataGrid x:Name="FolderGrid" Grid.Row="1" Margin="4,0,4,4">
              <DataGrid.RowStyle>
                <Style TargetType="DataGridRow" BasedOn="{StaticResource {x:Type DataGridRow}}">
                  <Setter Property="ToolTip" Value="{Binding Types}"/>
                </Style>
              </DataGrid.RowStyle>
              <DataGrid.Columns>
                <DataGridTemplateColumn Header="" Width="44">
                  <DataGridTemplateColumn.CellTemplate>
                    <DataTemplate>
                      <CheckBox IsChecked="{Binding Selected, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" IsEnabled="{Binding CanSelect}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </DataTemplate>
                  </DataGridTemplateColumn.CellTemplate>
                </DataGridTemplateColumn>
                <DataGridTextColumn Header="Folder" Binding="{Binding Name}" Width="110" FontWeight="SemiBold"/>
                <DataGridTextColumn Header="Dates" Binding="{Binding Dates}" Width="160"/>
                <DataGridTextColumn Header="Photos" Binding="{Binding Photos}" Width="70"/>
                <DataGridTextColumn Header="Videos" Binding="{Binding Videos}" Width="70"/>
                <DataGridTextColumn Header="Other" Binding="{Binding Other}" Width="62"/>
                <DataGridTextColumn Header="Size" Binding="{Binding Size}" Width="86"/>
                <DataGridTemplateColumn Header="On this PC" Width="*">
                  <DataGridTemplateColumn.CellTemplate>
                    <DataTemplate>
                      <StackPanel VerticalAlignment="Center" Margin="0,5">
                        <TextBlock Text="{Binding Status}" Foreground="{Binding StatusColor}" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
                        <TextBlock Text="{Binding Note}" Foreground="#64748B" TextWrapping="Wrap" FontSize="12" Margin="0,1,0,0"/>
                      </StackPanel>
                    </DataTemplate>
                  </DataGridTemplateColumn.CellTemplate>
                </DataGridTemplateColumn>
              </DataGrid.Columns>
            </DataGrid>
          </Grid>
        </Border>

        <Border Grid.Row="5" Style="{StaticResource Card}" Margin="0,12,0,0" Padding="20,12">
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <StackPanel VerticalAlignment="Center">
              <TextBlock x:Name="SelectionText" Text="No folders selected yet" FontWeight="SemiBold" FontSize="15" TextWrapping="Wrap"/>
              <TextBlock x:Name="SelectionDetail" Text="" Foreground="#64748B" FontSize="13" TextWrapping="Wrap" Margin="0,2,0,0"/>
            </StackPanel>
            <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
              <Button x:Name="CompareButton" Content="Compare only" Style="{StaticResource Secondary}" IsEnabled="False" Margin="16,0,0,0"
                      ToolTip="List every file of the selected folders and where it is on this PC - nothing is copied"/>
              <Button x:Name="StartCopyButton" Content="Copy selected folders" Style="{StaticResource Primary}" IsEnabled="False" MinWidth="200" Margin="10,0,0,0"/>
            </StackPanel>
          </Grid>
        </Border>
      </Grid>

      <!-- 3. copy -->
      <Grid x:Name="PageCopy" Visibility="Collapsed">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <StackPanel Grid.Row="0">
          <TextBlock x:Name="CopyTitle" Text="Copying to this PC" Style="{StaticResource H1}"/>
          <TextBlock x:Name="CopySub" Text="Keep the iPhone plugged in and unlocked. This PC will not go to sleep while copying." Style="{StaticResource Sub}"/>
        </StackPanel>

        <Border x:Name="WaitingBanner" Grid.Row="1" Visibility="Collapsed" Margin="0,16,0,0" Background="#FEF3C7" BorderBrush="#FCD34D" BorderThickness="1" CornerRadius="12" Padding="18,14">
          <DockPanel>
            <TextBlock DockPanel.Dock="Left" Style="{StaticResource Icon}" Text="&#xE7BA;" FontSize="20" Foreground="#B45309"/>
            <Button x:Name="TryAgainButton" DockPanel.Dock="Right" Content="Try again now" Style="{StaticResource Small}" Visibility="Collapsed" VerticalAlignment="Center" Margin="12,0,0,0"/>
            <StackPanel Margin="12,0,0,0">
              <TextBlock x:Name="WaitingTitle" Text="The iPhone was disconnected" FontWeight="SemiBold" Foreground="#78350F" FontSize="15"/>
              <TextBlock x:Name="WaitingText" Text="Plug it back in and unlock it - copying continues by itself from where it stopped. Nothing copied so far is lost." Foreground="#92400E" FontSize="13" TextWrapping="Wrap"/>
            </StackPanel>
          </DockPanel>
        </Border>

        <Border Grid.Row="2" Style="{StaticResource Card}" Margin="0,16,0,0" Padding="24,20">
          <StackPanel>
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <TextBlock x:Name="CopyPercent" Text="0%" FontSize="44" FontWeight="SemiBold" Foreground="#1D4ED8" VerticalAlignment="Center"/>
              <StackPanel Grid.Column="1" Margin="22,0,0,0" VerticalAlignment="Center">
                <TextBlock x:Name="CopyAmounts" Text="Getting ready..." FontSize="16" FontWeight="SemiBold"/>
                <TextBlock x:Name="CopyRate" Text="" Foreground="#475569" Margin="0,3,0,0"/>
              </StackPanel>
            </Grid>
            <ProgressBar x:Name="CopyBar" Height="14" Margin="0,16,0,0" Maximum="1000"/>
            <Grid Margin="0,16,0,0">
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="260"/></Grid.ColumnDefinitions>
              <StackPanel>
                <TextBlock Text="NOW COPYING" Style="{StaticResource Label}"/>
                <TextBlock x:Name="CopyCurrent" Text="" Margin="0,3,0,0" TextTrimming="CharacterEllipsis"/>
              </StackPanel>
              <StackPanel Grid.Column="1" VerticalAlignment="Bottom">
                <TextBlock x:Name="CopyCurrentPct" Text="" Foreground="#64748B" FontSize="12" HorizontalAlignment="Right"/>
                <ProgressBar x:Name="CopyFileBar" Height="6" Margin="0,4,0,0" Maximum="1000"/>
              </StackPanel>
            </Grid>
            <WrapPanel Margin="0,18,0,0">
              <Border Background="#F0FDF4" CornerRadius="8" Padding="12,6" Margin="0,0,10,0"><TextBlock x:Name="CopyStatCopied" Text="Copied 0" Foreground="#166534" FontWeight="SemiBold" FontSize="13"/></Border>
              <Border Background="#F1F5F9" CornerRadius="8" Padding="12,6" Margin="0,0,10,0"><TextBlock x:Name="CopyStatAlready" Text="Already on PC 0" Foreground="#334155" FontWeight="SemiBold" FontSize="13"/></Border>
              <Border Background="#FEF2F2" CornerRadius="8" Padding="12,6"><TextBlock x:Name="CopyStatFailed" Text="Problems 0" Foreground="#991B1B" FontWeight="SemiBold" FontSize="13"/></Border>
            </WrapPanel>
          </StackPanel>
        </Border>

        <Border Grid.Row="3" Style="{StaticResource Card}" Margin="0,14,0,0" Padding="0">
          <DataGrid x:Name="CopyGrid" Margin="4">
            <DataGrid.Columns>
              <DataGridTextColumn Header="Folder" Binding="{Binding Name}" Width="130" FontWeight="SemiBold"/>
              <DataGridTextColumn Header="Files to copy" Binding="{Binding Files}" Width="130"/>
              <DataGridTextColumn Header="Size" Binding="{Binding Size}" Width="100"/>
              <DataGridTemplateColumn Header="Progress" Width="200">
                <DataGridTemplateColumn.CellTemplate>
                  <DataTemplate><ProgressBar Value="{Binding Percent}" Maximum="100" Height="8" VerticalAlignment="Center"/></DataTemplate>
                </DataGridTemplateColumn.CellTemplate>
              </DataGridTemplateColumn>
              <DataGridTemplateColumn Header="Status" Width="*">
                <DataGridTemplateColumn.CellTemplate>
                  <DataTemplate><TextBlock Text="{Binding Status}" Foreground="{Binding StatusColor}" FontWeight="SemiBold" VerticalAlignment="Center"/></DataTemplate>
                </DataGridTemplateColumn.CellTemplate>
              </DataGridTemplateColumn>
            </DataGrid.Columns>
          </DataGrid>
        </Border>

        <Grid Grid.Row="4" Margin="0,14,0,0">
          <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <TextBlock x:Name="CopyFootnote" VerticalAlignment="Center" Foreground="#64748B" FontSize="12" TextWrapping="Wrap"
                     Text="Tip: you can stop at any time. Press Copy again later and it continues where it stopped - files already copied are not copied twice."/>
          <StackPanel Grid.Column="1" Orientation="Horizontal">
            <Button x:Name="PauseButton" Content="Pause" Style="{StaticResource Secondary}" MinWidth="110" Margin="0,0,10,0"/>
            <Button x:Name="StopButton" Content="Stop" Style="{StaticResource Secondary}" MinWidth="110"/>
            <Button x:Name="CopyBackButton" Content="Back to folders" Style="{StaticResource Secondary}" Visibility="Collapsed" Margin="10,0,0,0"/>
            <Button x:Name="CopyRetryButton" Content="Continue copying" Style="{StaticResource Primary}" Visibility="Collapsed" Margin="10,0,0,0"/>
          </StackPanel>
        </Grid>
      </Grid>

      <!-- 4. check -->
      <Grid x:Name="PageCheck" Visibility="Collapsed">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <StackPanel Grid.Row="0">
          <TextBlock x:Name="CheckTitle" Text="Checking every file" Style="{StaticResource H1}"/>
          <TextBlock x:Name="CheckSub" Text="Each file on the iPhone is compared with its copy on this PC: name, size, and a digital fingerprint of the content." Style="{StaticResource Sub}"/>
        </StackPanel>

        <Border x:Name="CheckProgressCard" Grid.Row="1" Style="{StaticResource Card}" Margin="0,16,0,0" Padding="22,16">
          <StackPanel>
            <DockPanel>
              <TextBlock x:Name="CheckPercent" DockPanel.Dock="Right" Text="0%" FontSize="22" FontWeight="SemiBold" Foreground="#1D4ED8"/>
              <StackPanel>
                <TextBlock x:Name="CheckStep" Text="Getting ready..." FontWeight="SemiBold"/>
                <TextBlock x:Name="CheckDetail" Text="" Foreground="#64748B" FontSize="13" Margin="0,2,0,0" TextTrimming="CharacterEllipsis"/>
              </StackPanel>
            </DockPanel>
            <ProgressBar x:Name="CheckBar" Height="10" Margin="0,12,0,0" Maximum="1000"/>
          </StackPanel>
        </Border>

        <Border x:Name="VerdictCard" Grid.Row="2" Visibility="Collapsed" Margin="0,16,0,0" CornerRadius="12" Padding="20,16" BorderThickness="1">
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <Border x:Name="VerdictIconBack" Width="46" Height="46" CornerRadius="23" VerticalAlignment="Top">
              <TextBlock x:Name="VerdictIcon" Style="{StaticResource Icon}" FontSize="22" Foreground="White" HorizontalAlignment="Center"/>
            </Border>
            <StackPanel Grid.Column="1" Margin="16,0,0,0">
              <TextBlock x:Name="VerdictTitle" FontSize="18" FontWeight="SemiBold" TextWrapping="Wrap"/>
              <TextBlock x:Name="VerdictText" FontSize="13" TextWrapping="Wrap" Margin="0,4,0,0"/>
            </StackPanel>
          </Grid>
        </Border>

        <Border Grid.Row="3" Style="{StaticResource Card}" Margin="0,14,0,0" Padding="0">
          <Grid>
            <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
            <DataGrid x:Name="CheckGrid" Margin="4">
              <DataGrid.Columns>
                <DataGridTextColumn Header="Folder" Binding="{Binding Name}" Width="120" FontWeight="SemiBold"/>
                <DataGridTextColumn Header="On the iPhone" Binding="{Binding Phone}" Width="190"/>
                <DataGridTextColumn Header="On this PC" Binding="{Binding Laptop}" Width="190"/>
                <DataGridTemplateColumn Header="Result" Width="*">
                  <DataGridTemplateColumn.CellTemplate>
                    <DataTemplate><TextBlock Text="{Binding Status}" Foreground="{Binding StatusColor}" FontWeight="SemiBold" VerticalAlignment="Center" TextWrapping="Wrap"/></DataTemplate>
                  </DataGridTemplateColumn.CellTemplate>
                </DataGridTemplateColumn>
              </DataGrid.Columns>
            </DataGrid>
            <Expander x:Name="ProblemsExpander" Grid.Row="1" Header="Files that need attention" Visibility="Collapsed" Margin="16,4,16,10" FontSize="13">
              <ListBox x:Name="ProblemsList" MaxHeight="150" BorderThickness="0" FontSize="12" Margin="0,6,0,0"/>
            </Expander>
          </Grid>
        </Border>

        <Grid Grid.Row="4" Margin="0,14,0,0">
          <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <WrapPanel VerticalAlignment="Center">
            <Button x:Name="OpenReportButton" Content="Open the report" Style="{StaticResource Secondary}" Margin="0,0,10,0" IsEnabled="False"/>
            <Button x:Name="OpenPhotosButton" Content="Open the photos folder" Style="{StaticResource Secondary}" Margin="0,0,10,0"/>
            <Button x:Name="FullCheckButton" Content="Full check (slower)" Style="{StaticResource Secondary}" Margin="0,0,10,0" IsEnabled="False"
                    ToolTip="Reads every file from the iPhone again and compares it with the copy. Takes about as long as the copy did."/>
            <Button x:Name="FixButton" Content="Copy the missing files" Style="{StaticResource Primary}" Visibility="Collapsed" Margin="0,0,10,0"/>
            <Button x:Name="CheckBackButton" Content="Back to folders" Style="{StaticResource Link}" VerticalAlignment="Center" Margin="6,0,0,0"/>
          </WrapPanel>
          <Button x:Name="GoDeleteButton" Grid.Column="1" Content="Free up space on the iPhone" Style="{StaticResource Primary}" IsEnabled="False" MinWidth="220"/>
        </Grid>
      </Grid>

      <!-- 5. free up -->
      <Grid x:Name="PageDelete" Visibility="Collapsed">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <StackPanel Grid.Row="0">
          <TextBlock x:Name="DeleteTitle" Text="Free up space on your iPhone" Style="{StaticResource H1}"/>
          <TextBlock x:Name="DeleteSub" Text="Only folders where every single file was found on this PC and matched are listed. Tick the ones to remove from the iPhone." Style="{StaticResource Sub}"/>
        </StackPanel>

        <Border Grid.Row="1" Margin="0,16,0,0" Background="#FFF7ED" BorderBrush="#FDBA74" BorderThickness="1" CornerRadius="12" Padding="18,14">
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <TextBlock Style="{StaticResource Icon}" Text="&#xE7BA;" FontSize="20" Foreground="#C2410C" VerticalAlignment="Top" Margin="0,2,0,0"/>
            <StackPanel Grid.Column="1" Margin="12,0,0,0">
              <TextBlock x:Name="DeleteWarnTitle" Text="Deleting from the iPhone cannot be undone from this PC" FontWeight="SemiBold" Foreground="#7C2D12"/>
              <TextBlock x:Name="DeleteWarnText" Foreground="#9A3412" FontSize="13" TextWrapping="Wrap" Margin="0,3,0,0"
                         Text="The copies on this PC are not touched. If you use iCloud Photos, deleting here also deletes the photos from iCloud and your other Apple devices - check Settings > [your name] > iCloud > Photos on the iPhone first. Files added to a folder after the check are never deleted."/>
            </StackPanel>
          </Grid>
        </Border>

        <Border Grid.Row="2" Style="{StaticResource Card}" Margin="0,14,0,0" Padding="0">
          <DataGrid x:Name="DeleteGrid" Margin="4">
            <DataGrid.Columns>
              <DataGridTemplateColumn Header="" Width="44">
                <DataGridTemplateColumn.CellTemplate>
                  <DataTemplate>
                    <CheckBox IsChecked="{Binding Selected, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" IsEnabled="{Binding CanSelect}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                  </DataTemplate>
                </DataGridTemplateColumn.CellTemplate>
              </DataGridTemplateColumn>
              <DataGridTextColumn Header="Folder" Binding="{Binding Name}" Width="120" FontWeight="SemiBold"/>
              <DataGridTextColumn Header="Dates" Binding="{Binding Dates}" Width="160"/>
              <DataGridTextColumn Header="Files" Binding="{Binding Files}" Width="90"/>
              <DataGridTextColumn Header="Size" Binding="{Binding Size}" Width="90"/>
              <DataGridTemplateColumn Header="Status" Width="*">
                <DataGridTemplateColumn.CellTemplate>
                  <DataTemplate><TextBlock Text="{Binding Status}" Foreground="{Binding StatusColor}" FontWeight="SemiBold" VerticalAlignment="Center" TextWrapping="Wrap"/></DataTemplate>
                </DataGridTemplateColumn.CellTemplate>
              </DataGridTemplateColumn>
            </DataGrid.Columns>
          </DataGrid>
        </Border>

        <Border x:Name="DeleteProgressCard" Grid.Row="3" Style="{StaticResource Card}" Margin="0,14,0,0" Padding="22,14" Visibility="Collapsed">
          <StackPanel>
            <DockPanel>
              <TextBlock x:Name="DeletePercent" DockPanel.Dock="Right" Text="0%" FontSize="20" FontWeight="SemiBold" Foreground="#B91C1C"/>
              <StackPanel>
                <TextBlock x:Name="DeleteStep" Text="Deleting from the iPhone..." FontWeight="SemiBold"/>
                <TextBlock x:Name="DeleteDetail" Text="" Foreground="#64748B" FontSize="13" Margin="0,2,0,0" TextTrimming="CharacterEllipsis"/>
              </StackPanel>
            </DockPanel>
            <ProgressBar x:Name="DeleteBar" Height="8" Margin="0,10,0,0" Maximum="1000" Foreground="#DC2626"/>
          </StackPanel>
        </Border>

        <Border Grid.Row="4" Style="{StaticResource Card}" Margin="0,14,0,0" Padding="20,14">
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <StackPanel VerticalAlignment="Center">
              <TextBlock x:Name="DeleteSelectionText" Text="Nothing selected" FontWeight="SemiBold" FontSize="15"/>
              <CheckBox x:Name="DeleteConfirmCheck" Margin="0,8,0,0" FontSize="13">
                <TextBlock TextWrapping="Wrap" Text="I understand the selected files will be removed from my iPhone. Their copies stay on this PC."/>
              </CheckBox>
            </StackPanel>
            <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
              <Button x:Name="DeleteBackButton" Content="Back" Style="{StaticResource Secondary}" Margin="0,0,10,0" MinWidth="90"/>
              <Button x:Name="DeleteButton" Content="Delete from iPhone" Style="{StaticResource Danger}" IsEnabled="False" MinWidth="220"/>
              <Button x:Name="FinishButton" Content="Done" Style="{StaticResource Primary}" Visibility="Collapsed" MinWidth="140"/>
            </StackPanel>
          </Grid>
        </Border>
      </Grid>
    </Grid>
  </Grid>
</Window>
'@

$window = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}
foreach ($node in $xaml.SelectNodes('//*[@*[local-name()="Name"]]')) {
    $name = $node.Attributes | Where-Object { $_.LocalName -eq 'Name' } | Select-Object -First 1 -ExpandProperty Value
    if ($name) { $ui[$name] = $window.FindName($name) }
}
$window.TaskbarItemInfo = New-Object System.Windows.Shell.TaskbarItemInfo
$IconPath = Join-Path $PSScriptRoot 'iPhoneTransfer.ico'
[IPhoneTransferApp.Native]::SetAppId('iPhoneTransfer.App')
if (Test-Path -LiteralPath $IconPath) {
    try { $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create((New-Object System.Uri $IconPath)) } catch { }
}

# ---------------------------------------------------------------------------
# state shared with the engine
# ---------------------------------------------------------------------------

$sync = [hashtable]::Synchronized(@{})
$sync.Commands = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
$sync.Events   = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
$sync.UiLog    = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$sync.Progress = [hashtable]::Synchronized(@{})
$sync.Cancel = $false; $sync.Pause = $false; $sync.Quit = $false; $sync.Busy = $false
$sync.Watch = (-not $SourceFolder)
$sync.NewDest = $null
$sync.TryAgain = $false
$sync.LogPath = $LogPath

$settings = Get-Settings
$app = @{
    Page = 'Connect'; Device = $null; SourceKind = ''; SourceLabel = ''; Capacity = [int64] 0
    Rows = New-Object 'System.Collections.ObjectModel.ObservableCollection[IPhoneTransferApp.Row]'
    RowByName = @{}; Summaries = @{}
    CopyRows = New-Object 'System.Collections.ObjectModel.ObservableCollection[IPhoneTransferApp.Row]'
    CheckRows = New-Object 'System.Collections.ObjectModel.ObservableCollection[IPhoneTransferApp.Row]'
    DeleteRows = New-Object 'System.Collections.ObjectModel.ObservableCollection[IPhoneTransferApp.Row]'
    Dest = ''; Speed = [double] $settings.Speed
    Scanning = $false; ScanDone = $false; AutoSelected = $false
    CopyFolders = @(); CopyStats = $null; CopyRunning = $false; CopyDone = $null
    CheckFolders = @(); CheckRunning = $false; CheckDone = $null; Report = ''; VerifiedOk = @{}; PartialOk = @{}
    DeleteRunning = $false; DeleteDone = $null
    Session = $null; Waiting = $false; DeviceGone = $false; ForceClose = $false; LastFreeCheck = [DateTime]::MinValue
    Free = [int64] -1; Total = [int64] -1
}
$ui.FolderGrid.ItemsSource = $app.Rows
$ui.CopyGrid.ItemsSource = $app.CopyRows
$ui.CheckGrid.ItemsSource = $app.CheckRows
$ui.DeleteGrid.ItemsSource = $app.DeleteRows

$GREEN = '#15803D'; $AMBER = '#B45309'; $RED = '#B91C1C'; $GRAY = '#64748B'; $BLUE = '#1D4ED8'

# ---------------------------------------------------------------------------
# small helpers
# ---------------------------------------------------------------------------

function Write-UiLog { param([string] $Text) $sync.UiLog.Enqueue($Text) }

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

function Format-Dates {
    param([string] $First, [string] $Last)
    if (-not $First) { return '' }
    try {
        $a = [DateTime]::ParseExact($First, 'yyyy-MM-dd', $Invariant)
        $b = [DateTime]::ParseExact($Last, 'yyyy-MM-dd', $Invariant)
        if ($a.Date -eq $b.Date) { return $a.ToString('d MMM yyyy', $Invariant) }
        if ($a.Year -eq $b.Year -and $a.Month -eq $b.Month) { return ('{0} - {1}' -f $a.ToString('%d', $Invariant), $b.ToString('d MMM yyyy', $Invariant)) }
        if ($a.Year -eq $b.Year) { return ('{0} - {1}' -f $a.ToString('d MMM', $Invariant), $b.ToString('d MMM yyyy', $Invariant)) }
        return ('{0} - {1}' -f $a.ToString('d MMM yyyy', $Invariant), $b.ToString('d MMM yyyy', $Invariant))
    }
    catch { return "$First - $Last" }
}

function Get-FolderLabel {
    # "202608_a" -> "Aug 2026"; anything else is shown as it is.
    param([string] $Name)
    if ($Name -match '^(\d{4})(\d{2})(?:__|_)?([a-z])?$') {
        try {
            $d = New-Object DateTime ([int] $Matches[1]), ([int] $Matches[2]), 1
            return $d.ToString('MMM yyyy', $Invariant)
        }
        catch { }
    }
    return ''
}

function Show-Message {
    param([string] $Text, [string] $Title = 'iPhone Transfer', [string] $Icon = 'Information')
    Write-UiLog "message: $Text"
    if ($AutoPilot) { return }
    [void] [System.Windows.MessageBox]::Show($window, $Text, $Title, 'OK', $Icon)
}

function Confirm-Action {
    param([string] $Text, [string] $Title = 'iPhone Transfer', [string] $Icon = 'Question')
    if ($AutoPilot) { Write-UiLog "auto-confirmed: $Text"; return $true }
    $answer = [System.Windows.MessageBox]::Show($window, $Text, $Title, 'YesNo', $Icon, 'No')
    return ($answer -eq 'Yes')
}

function Send-Command { param([hashtable] $Command) $sync.Commands.Enqueue($Command) }

function Get-SourceWord {
    if ($app.SourceKind -eq 'Folder') { return 'the source folder' }
    return 'the iPhone'
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

# ---------------------------------------------------------------------------
# navigation
# ---------------------------------------------------------------------------

$PAGES = @('Connect', 'Analyze', 'Copy', 'Check', 'Delete')

function Show-Page {
    param([string] $Name)
    $app.Page = $Name
    foreach ($p in $PAGES) {
        $element = $ui["Page$p"]
        if ($p -eq $Name) { $element.Visibility = 'Visible' } else { $element.Visibility = 'Collapsed' }
    }
    $current = [array]::IndexOf($PAGES, $Name)
    for ($i = 0; $i -lt $PAGES.Count; $i++) {
        $dot = $ui["Step${i}Dot"]; $num = $ui["Step${i}Num"]; $title = $ui["Step${i}Title"]
        if ($i -lt $current) {
            Set-Color $dot 'Background' '#16A34A'; $num.Text = [string] [char] 0x2713; Set-Color $num 'Foreground' 'White'; Set-Color $title 'Foreground' '#CBD5E1'
        }
        elseif ($i -eq $current) {
            Set-Color $dot 'Background' '#2563EB'; $num.Text = [string] ($i + 1); Set-Color $num 'Foreground' 'White'; Set-Color $title 'Foreground' 'White'
        }
        else {
            Set-Color $dot 'Background' '#1E293B'; $num.Text = [string] ($i + 1); Set-Color $num 'Foreground' '#94A3B8'; Set-Color $title 'Foreground' '#64748B'
        }
    }
    Write-UiLog "page: $Name"
}

# ---------------------------------------------------------------------------
# step 1: connect
# ---------------------------------------------------------------------------

function Update-ConnectCard {
    param($State)
    $app.Device = $State
    switch ($State.State) {
        'Ready' {
            $ui.ConnectTitle.Text = "Connected: $($State.Device)"
            $detail = Format-Plural $State.Folders.Count 'folder' 'folders'
            if ($State.Capacity -gt 0) { $detail = "$(Format-Bytes $State.Capacity) iPhone" + $DOT + $detail }
            $ui.ConnectDetail.Text = $detail + ' found. Press Continue to see what is on it.'
            Set-Color $ui.ConnectIconBack 'Background' '#DCFCE7'; Set-Color $ui.ConnectIcon 'Foreground' '#16A34A'; $ui.ConnectIcon.Text = [string] [char] 0xE73E
            $ui.ConnectBar.Visibility = 'Collapsed'
            $ui.ConnectContinue.IsEnabled = $true
        }
        'Locked' {
            $ui.ConnectTitle.Text = "$($State.Device) found - please unlock it"
            $ui.ConnectDetail.Text = 'Unlock the iPhone and tap Trust if it asks. The photos appear a moment later.'
            Set-Color $ui.ConnectIconBack 'Background' '#FEF3C7'; Set-Color $ui.ConnectIcon 'Foreground' '#B45309'; $ui.ConnectIcon.Text = [string] [char] 0xE72E
            $ui.ConnectBar.Visibility = 'Visible'
            $ui.ConnectContinue.IsEnabled = $false
        }
        'Empty' {
            $ui.ConnectTitle.Text = "$($State.Device) found - no photos visible yet"
            $ui.ConnectDetail.Text = 'Unlock the iPhone and keep it unlocked for a moment. If it stays empty, the photos may only be in iCloud.'
            Set-Color $ui.ConnectIconBack 'Background' '#FEF3C7'; Set-Color $ui.ConnectIcon 'Foreground' '#B45309'; $ui.ConnectIcon.Text = [string] [char] 0xE72E
            $ui.ConnectBar.Visibility = 'Visible'
            $ui.ConnectContinue.IsEnabled = $false
        }
        default {
            $ui.ConnectTitle.Text = 'Looking for your iPhone...'
            $ui.ConnectDetail.Text = 'Plug it in with its cable and unlock it.'
            Set-Color $ui.ConnectIconBack 'Background' '#F1F5F9'; Set-Color $ui.ConnectIcon 'Foreground' '#64748B'; $ui.ConnectIcon.Text = [string] [char] 0xE8EA
            $ui.ConnectBar.Visibility = 'Visible'
            $ui.ConnectContinue.IsEnabled = $false
        }
    }
}

function Start-Analysis {
    param([string] $Kind, [string] $Path = '')
    if ($Kind -eq 'Folder') { Send-Command @{ Name = 'SetSource'; Kind = 'Folder'; Path = $Path } }
    else { Send-Command @{ Name = 'SetSource'; Kind = 'Device' } }
}

# ---------------------------------------------------------------------------
# step 2: analyse and choose
# ---------------------------------------------------------------------------

function Get-DefaultDestination {
    # No silent default: the user chooses where the photos go. Afterwards it is remembered.
    if ($Destination) { return $Destination }
    if ($AutoPilot) { return '' }   # test runs never use a real user's saved destination
    if ($settings.LastDestination -and (Test-Path -LiteralPath $settings.LastDestination)) { return $settings.LastDestination }
    return ''
}

function Test-Inside {
    # Is one of the two folders the same as, or inside, the other?
    param([string] $A, [string] $B)
    $a2 = [System.IO.Path]::GetFullPath($A).TrimEnd('\') + '\'
    $b2 = [System.IO.Path]::GetFullPath($B).TrimEnd('\') + '\'
    return ($a2.StartsWith($b2, [StringComparison]::OrdinalIgnoreCase) -or $b2.StartsWith($a2, [StringComparison]::OrdinalIgnoreCase))
}

function Show-NoDestination {
    $ui.DestText.Text = 'Not chosen yet - choose the folder to save into'
    Set-Color $ui.DestText 'Foreground' $AMBER
    $ui.ChangeDestButton.Content = 'Choose where to save...'
    $ui.ChangeDestButton.Style = $window.FindResource('Primary')
    $ui.ChangeDestButton.Padding = '12,5'; $ui.ChangeDestButton.FontSize = 13
    $ui.OpenDestButton.Visibility = 'Collapsed'
    foreach ($row in $app.Rows) { if ($row.Scanned -and $row.CanSelect) { $row.Status = 'Choose where to save to compare'; $row.StatusColor = $GRAY } }
}

function Set-Destination {
    param([string] $Path, [switch] $ByUser)
    if (-not $Path) { return }
    try { $Path = [System.IO.Path]::GetFullPath($Path).TrimEnd('\'); if ($Path.Length -eq 2) { $Path += '\' } }
    catch { Show-Message "That folder cannot be used: $Path" 'iPhone Transfer' 'Warning'; return }
    # Picked one month folder (like ...\202609_a) as the destination? Each source folder is
    # saved as a sub-folder of the destination, so new files would end up in
    # 202609_a\202609_a. Offer the folder above it instead.
    $leaf = Split-Path -Leaf $Path
    $parent = Split-Path -Parent $Path
    if ($ByUser -and $parent -and ($leaf -match '^\d{6}_{1,2}[a-z]?$' -or $app.RowByName.ContainsKey($leaf))) {
        $question = ("You chose the folder ""{0}"".`r`n`r`nThe app keeps the same folders as the source, so photos from the source folder {0} would go into ""{1}"".`r`n`r`nSave into the folder above it instead?`r`n`r`n    {2}`r`n`r`n(Files already there - in any of its folders - are recognised either way.)" -f $leaf, (Join-Path $Path $leaf), $parent)
        if (Confirm-Action $question 'Choose the main folder?') { $Path = $parent }
    }
    if ($app.SourceKind -eq 'Folder' -and $app.SourcePath -and (Test-Inside $Path $app.SourcePath)) {
        Show-Message 'Please choose a destination outside the folder you are copying from - otherwise every file would look like its own copy.' 'iPhone Transfer' 'Warning'
        return
    }
    # Must be somewhere we can write: try it now rather than at the first file.
    $probeDir = $Path
    while ($probeDir -and -not (Test-Path -LiteralPath $probeDir)) { $probeDir = Split-Path -Parent $probeDir }
    if (-not $probeDir) { Show-Message "That drive is not available: $Path" 'iPhone Transfer' 'Warning'; return }
    try {
        $probe = Join-Path $probeDir ('.iphone-transfer-write-test-' + [guid]::NewGuid().ToString('N'))
        [System.IO.File]::WriteAllText($probe, 'ok'); [System.IO.File]::Delete($probe)
    }
    catch { Show-Message "This app cannot save files in $probeDir.`r`n`r`nPlease choose another folder." 'iPhone Transfer' 'Warning'; return }

    if ($app.Dest -ne $Path) { $app.VerifiedOk = @{}; $app.PartialOk = @{} }   # checks were made against the old destination
    $app.Dest = $Path
    $ui.DestText.Text = $Path
    $ui.DestText.ToolTip = $Path
    Set-Color $ui.DestText 'Foreground' '#0F172A'
    $ui.ChangeDestButton.Content = 'Change...'
    $ui.ChangeDestButton.Style = $window.FindResource('Small')
    $ui.ChangeDestButton.ClearValue([System.Windows.Controls.Control]::PaddingProperty)
    $ui.ChangeDestButton.ClearValue([System.Windows.Controls.Control]::FontSizeProperty)
    $ui.OpenDestButton.Visibility = 'Visible'
    Update-FreeSpace -Force
    foreach ($row in $app.Rows) { if ($row.Scanned) { $row.Status = 'Comparing...'; $row.StatusColor = $GRAY } }
    if ($sync.Busy) { $sync.NewDest = $Path } else { Send-Command @{ Name = 'SetDestination'; Path = $Path } }
    Write-UiLog "destination chosen: $Path"
}

function Update-FreeSpace {
    param([switch] $Force)
    if (-not $Force -and ([DateTime]::UtcNow - $app.LastFreeCheck).TotalSeconds -lt 5) { return }
    $app.LastFreeCheck = [DateTime]::UtcNow
    if (-not $app.Dest) { $app.Free = [int64] -1; $app.Total = [int64] -1; return }
    $root = $app.Dest
    while ($root -and -not (Test-Path -LiteralPath $root)) { $root = Split-Path -Parent $root }
    if (-not $root) { $root = [System.IO.Path]::GetPathRoot($app.Dest) }
    $app.Free = [IPhoneTransferApp.Native]::GetFreeBytes($root)
    $app.Total = [IPhoneTransferApp.Native]::GetTotalBytes($root)
}

function Update-DrivePanel {
    $ui.DrivePanel.Children.Clear()
    $drives = @([System.IO.DriveInfo]::GetDrives() | Where-Object { ($_.DriveType -eq 'Fixed' -or $_.DriveType -eq 'Removable') -and $_.IsReady })
    if ($drives.Count -le 1) { return }
    $label = New-Object System.Windows.Controls.TextBlock
    $label.Text = 'Other drives:'; $label.Foreground = '#64748B'; $label.FontSize = 12; $label.VerticalAlignment = 'Center'; $label.Margin = '0,0,8,0'
    [void] $ui.DrivePanel.Children.Add($label)
    foreach ($d in $drives) {
        $letter = $d.Name.TrimEnd('\')
        if ($app.Dest -and $app.Dest.StartsWith($d.Name, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $button = New-Object System.Windows.Controls.Button
        $button.Style = $window.FindResource('Small')
        $button.Margin = '0,0,6,0'
        $button.Content = '{0} {1} free' -f $letter, (Format-Bytes $d.AvailableFreeSpace)
        $button.Tag = (Join-Path $d.Name 'iPhone Photos')
        $button.ToolTip = "Save to $($button.Tag)"
        $button.Add_Click({ param($s, $e) Invoke-Safely { Set-Destination $s.Tag; Update-DrivePanel } })
        [void] $ui.DrivePanel.Children.Add($button)
    }
    if ($ui.DrivePanel.Children.Count -eq 1) { $ui.DrivePanel.Children.Clear() }
}

function New-Chip {
    param([string] $Text, [string] $Back = '#FFFFFF', [string] $Fore = '#0F172A')
    $border = New-Object System.Windows.Controls.Border
    $border.CornerRadius = '16'; $border.Padding = '12,5'; $border.Margin = '0,0,8,6'
    Set-Color $border 'Background' $Back
    Set-Color $border 'BorderBrush' '#E2E8F0'; $border.BorderThickness = '1'
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Text; $t.FontSize = 13; $t.FontWeight = 'SemiBold'
    Set-Color $t 'Foreground' $Fore
    $border.Child = $t
    return $border
}

function Update-SummaryChips {
    $ui.SummaryChips.Children.Clear()
    $files = 0; $photos = 0; $videos = 0; $bytes = [int64] 0; $read = 0
    foreach ($s in $app.Summaries.Values) { $files += $s.Files; $photos += $s.Photos; $videos += $s.Videos; $bytes += $s.Bytes; $read++ }
    [void] $ui.SummaryChips.Children.Add((New-Chip (Format-Plural $app.Rows.Count 'folder' 'folders')))
    if ($read -gt 0) {
        [void] $ui.SummaryChips.Children.Add((New-Chip (Format-Plural $files 'file' 'files')))
        [void] $ui.SummaryChips.Children.Add((New-Chip ((Format-Plural $photos 'photo' 'photos')) '#F0F9FF' '#075985'))
        [void] $ui.SummaryChips.Children.Add((New-Chip ((Format-Plural $videos 'video' 'videos')) '#FDF4FF' '#86198F'))
        [void] $ui.SummaryChips.Children.Add((New-Chip ((Format-Bytes $bytes) + ' in total') '#F8FAFC' '#334155'))
    }
    if ($app.Capacity -gt 0 -and $app.SourceKind -eq 'Device') {
        [void] $ui.SummaryChips.Children.Add((New-Chip ('iPhone storage ' + (Format-Bytes $app.Capacity)) '#F8FAFC' '#64748B'))
    }

    # File types across everything read so far, biggest first.
    $types = @{}
    foreach ($s in $app.Summaries.Values) {
        foreach ($t in $s.Types) {
            if (-not $types.ContainsKey($t.Ext)) { $types[$t.Ext] = @{ Ext = $t.Ext; Count = 0; Bytes = [int64] 0 } }
            $types[$t.Ext].Count += $t.Count; $types[$t.Ext].Bytes += $t.Bytes
        }
    }
    if ($types.Count -gt 0) {
        $parts = @($types.Values | Sort-Object { - $_.Bytes } | ForEach-Object { '{0} {1} ({2})' -f $_.Ext.TrimStart('.'), (Format-Count $_.Count), (Format-Bytes $_.Bytes) })
        $ui.TypesText.Text = 'File types:  ' + ($parts -join $DOT)
    }
    else { $ui.TypesText.Text = '' }
}

function Format-Types {
    param($Types)
    $parts = @($Types | ForEach-Object { '{0}: {1} ({2})' -f $_.Ext.TrimStart('.'), (Format-Count $_.Count), (Format-Bytes $_.Bytes) })
    if ($parts.Count -eq 0) { return '' }
    return ($parts -join "`r`n")
}

function Update-Row {
    param($Summary)
    $row = $app.RowByName[$Summary.Name]
    if ($null -eq $row) { return }
    $app.Summaries[$Summary.Name] = $Summary
    $row.Scanned = $true
    $row.FileCount = [int64] $Summary.Files
    $row.Bytes = [int64] $Summary.Bytes
    $row.Files = Format-Count $Summary.Files
    $row.Photos = Format-Count $Summary.Photos
    $row.Videos = Format-Count $Summary.Videos
    $row.Other = Format-Count $Summary.Other
    $row.Size = Format-Bytes $Summary.Bytes
    $row.Types = ("{0} - file types`r`n" -f $Summary.Name) + (Format-Types $Summary.Types)
    $dates = Format-Dates $Summary.FirstDate $Summary.LastDate
    if (-not $dates) { $dates = Get-FolderLabel $Summary.Name }
    $row.Dates = $dates

    if ($Summary.Error) {
        $row.Status = 'Could not be read'; $row.StatusColor = $RED; $row.CanSelect = $false; $row.Selected = $false
        $row.Note = 'Unlock the iPhone and press Read again. ' + $Summary.Error
        return
    }
    if ($Summary.Files -eq 0) {
        $row.StatusColor = $GRAY; $row.CanSelect = $false; $row.Selected = $false
        if ($app.SourceKind -eq 'Device') {
            $row.Status = 'Empty on iPhone'
            $row.Note = 'The iPhone lists no files here. Usually it fills in on a later read; if it stays empty, these photos are only in iCloud.'
        }
        else { $row.Status = 'Empty folder'; $row.Note = '' }
        return
    }
    $row.CanSelect = $true
    if ($null -ne $Summary.PresentFiles) {
        $row.PresentFiles = [int64] $Summary.PresentFiles
        $row.FilesToCopy = [int64] ($Summary.Files - $Summary.PresentFiles)
        $row.BytesToCopy = [math]::Max([int64] 0, [int64] ($Summary.Bytes - $Summary.PresentBytes))
        if ($app.VerifiedOk.ContainsKey($Summary.Name)) {
            $row.Status = [string] [char] 0x2713 + ' On this PC, checked'; $row.StatusColor = $GREEN
        }
        elseif ($Summary.PresentFiles -ge $Summary.Files) {
            $row.Status = [string] [char] 0x2713 + ' On this PC'; $row.StatusColor = $GREEN
        }
        elseif ($Summary.PresentFiles -gt 0) {
            $row.Status = 'Partly ({0} of {1})' -f (Format-Count $Summary.PresentFiles), (Format-Count $Summary.Files); $row.StatusColor = $AMBER
        }
        else { $row.Status = 'Not on this PC yet'; $row.StatusColor = $GRAY }
    }
    else {
        $row.FilesToCopy = [int64] $Summary.Files; $row.BytesToCopy = [int64] $Summary.Bytes
        if ($app.Dest) { $row.Status = 'Comparing...' } else { $row.Status = 'Choose where to save to compare' }
        $row.StatusColor = $GRAY
    }
}

function Get-ElsewhereText {
    # The iPhone regroups its folders over time, so earlier copies often sit in a differently
    # named folder on the PC. Say so, so "already there" is not a mystery.
    param($Row)
    $s = $app.Summaries[$Row.Name]
    if ($s -and $s.ElsewhereFiles -gt 0) { return ('{0} found in other folders on this PC. ' -f (Format-Plural $s.ElsewhereFiles 'file' 'files')) }
    return ''
}

function Get-Recommendation {
    # Whole folders only, so a folder is either fully on the PC or not at all. Folders whose
    # copy was interrupted come first, then the oldest - those are usually the ones people
    # want off the phone - for as long as they fit with room to spare.
    $budget = $app.Free - $RESERVE
    $picked = New-Object System.Collections.ArrayList
    $used = [int64] 0
    $skipped = 0
    $candidates = @($app.Rows | Where-Object { $_.Scanned -and $_.CanSelect -and $_.FileCount -gt 0 -and $_.BytesToCopy -gt 0 })
    $ordered = @($candidates | Sort-Object @{ Expression = { if ($_.PresentFiles -gt 0) { 0 } else { 1 } } }, @{ Expression = { $_.Name } })
    $newest = ($app.Rows | Sort-Object Name | Select-Object -Last 1)
    foreach ($row in $app.Rows) { $row.Recommended = $false }
    foreach ($row in $ordered) {
        $note = ''
        if ($app.Free -ge 0 -and ($used + $row.BytesToCopy) -gt $budget) {
            $row.Note = (Get-ElsewhereText $row) + ('Does not fit in the space left on this PC (needs {0}).' -f (Format-Bytes $row.BytesToCopy))
            $skipped++
            continue
        }
        $row.Recommended = $true
        [void] $picked.Add($row)
        $used += $row.BytesToCopy
        if ($row.PresentFiles -gt 0) { $note = 'Recommended - part of it is already on this PC, only the rest is copied.' }
        else { $note = 'Recommended.' }
        if ($newest -and $row.Name -eq $newest.Name -and $app.SourceKind -eq 'Device') { $note += ' Newest folder - new photos may still be added to it.' }
        $row.Note = (Get-ElsewhereText $row) + $note
    }
    foreach ($row in $app.Rows) {
        if ($row.Scanned -and $row.CanSelect -and $row.FileCount -gt 0 -and $row.BytesToCopy -le 0) {
            if ($app.VerifiedOk.ContainsKey($row.Name)) { $row.Note = 'Checked. You can free up its space on the iPhone.' }
            else { $row.Note = (Get-ElsewhereText $row) + 'Nothing to copy. Select it to check it and free up the iPhone.' }
        }
    }
    return @{ Rows = $picked; Bytes = $used; Skipped = $skipped; Budget = $budget }
}

function Update-Recommendation {
    if (-not $app.Dest) {
        $ui.RecommendTitle.Text = 'Choose where to save the photos.'
        $ui.RecommendText.Text = 'Press "Choose where to save..." above. The app then compares this source with that folder - every sub-folder in it - and recommends what to copy.'
        $ui.SelectRecommendedButton.IsEnabled = $false
        return
    }
    if (-not $app.ScanDone) {
        $ui.RecommendTitle.Text = 'Reading your folders...'
        $ui.RecommendText.Text = 'A recommendation appears once every folder has been read. You can already tick folders that are done.'
        $ui.SelectRecommendedButton.IsEnabled = $false
        return
    }
    $rec = Get-Recommendation
    $app.Recommendation = $rec
    $ui.SelectRecommendedButton.IsEnabled = ($rec.Rows.Count -gt 0)
    $readable = @($app.Rows | Where-Object { $_.Scanned -and $_.CanSelect -and $_.FileCount -gt 0 })
    $pending = @($readable | Where-Object { $_.BytesToCopy -gt 0 })
    if ($readable.Count -eq 0) {
        $ui.RecommendTitle.Text = 'No photos found to copy.'
        $ui.RecommendText.Text = 'The folders are empty. If your photos are in iCloud, set the iPhone to "Download and Keep Originals" (Settings > Photos) and try again later.'
    }
    elseif ($pending.Count -eq 0) {
        $ui.RecommendTitle.Text = 'Everything on the iPhone is already on this PC.'
        $ui.RecommendText.Text = 'Select folders and press Check to confirm every file matches - then you can free up space on the iPhone.'
    }
    elseif ($rec.Rows.Count -eq 0) {
        $ui.RecommendTitle.Text = 'Not enough space on this PC for any whole folder.'
        $ui.RecommendText.Text = ('Free up space or choose another drive. The smallest folder still to copy needs {0}; {1} is free.' -f (Format-Bytes (($pending | Measure-Object -Property BytesToCopy -Minimum).Minimum)), (Format-Bytes ([math]::Max([int64] 0, [int64] $app.Free))))
    }
    elseif ($rec.Rows.Count -eq $pending.Count) {
        $ui.RecommendTitle.Text = ('Recommended: everything still to copy fits - {0}, {1}.' -f (Format-Plural $rec.Rows.Count 'folder' 'folders'), (Format-Bytes $rec.Bytes))
        $ui.RecommendText.Text = ('That leaves {0} free on this PC.' -f (Format-Bytes ([math]::Max([int64] 0, [int64] ($app.Free - $rec.Bytes)))))
    }
    else {
        $ui.RecommendTitle.Text = ('Recommended: {0}, {1} - oldest first, chosen to fit with room to spare.' -f (Format-Plural $rec.Rows.Count 'folder' 'folders'), (Format-Bytes $rec.Bytes))
        $ui.RecommendText.Text = ('{0} would not fit as well. Copy these, free up the iPhone, then come back for the rest - or choose a drive with more space.' -f (Format-Plural $rec.Skipped 'other folder' 'other folders'))
    }
}

function Select-Recommended {
    if (-not $app.Recommendation) { return }
    $names = @{}
    foreach ($r in $app.Recommendation.Rows) { $names[$r.Name] = $true }
    foreach ($row in $app.Rows) { if ($row.CanSelect) { $row.Selected = $names.ContainsKey($row.Name) } }
}

function Update-Selection {
    $selected = @($app.Rows | Where-Object { $_.Selected -and $_.CanSelect })
    $files = [int64] 0; $toCopy = [int64] 0; $toCopyFiles = [int64] 0; $total = [int64] 0
    foreach ($r in $selected) { $files += $r.FileCount; $toCopy += $r.BytesToCopy; $toCopyFiles += $r.FilesToCopy; $total += $r.Bytes }

    # free-space bar
    if ($app.Dest) { $ui.SpaceArea.Visibility = 'Visible' }
    if ($app.Total -gt 0 -and $app.Free -ge 0) {
        $used = [double] ($app.Total - $app.Free)
        $need = [double] [math]::Min([int64] $toCopy, [int64] $app.Free)
        $ui.SpaceUsed.Width = New-Object System.Windows.GridLength ([math]::Max(0.001, $used)), 'Star'
        $ui.SpaceNeed.Width = New-Object System.Windows.GridLength ([math]::Max(0.0, $need)), 'Star'
        $ui.SpaceFree.Width = New-Object System.Windows.GridLength ([math]::Max(0.001, $app.Free - $need)), 'Star'
        $fits = ($toCopy + $RESERVE / 4) -le $app.Free
        if ($fits) { Set-Color $ui.SpaceNeedFill 'Background' '#2563EB' } else { Set-Color $ui.SpaceNeedFill 'Background' '#DC2626' }
        $text = 'This PC: {0} free of {1}' -f (Format-Bytes $app.Free), (Format-Bytes $app.Total)
        if ($toCopy -gt 0) {
            if ($fits) { $text += $DOT + ('the selection needs {0}, leaving {1}' -f (Format-Bytes $toCopy), (Format-Bytes ($app.Free - $toCopy))) }
            else { $text += $DOT + ('the selection needs {0} - {1} more than is free' -f (Format-Bytes $toCopy), (Format-Bytes ($toCopy - $app.Free))) }
        }
        $ui.SpaceText.Text = $text
    }
    elseif (-not $app.Dest) { $fits = $true; $ui.SpaceText.Text = 'Choose where to save to see the free space there.'; $ui.SpaceArea.Visibility = 'Collapsed' }
    else { $fits = $true; $ui.SpaceText.Text = 'Free space unknown for this location.' }

    $ui.CompareButton.IsEnabled = ($selected.Count -gt 0) -and [bool] $app.Dest -and -not $sync.Busy -and -not $app.CopyRunning
    if ($selected.Count -eq 0) {
        $ui.SelectionText.Text = 'No folders selected yet'
        $ui.SelectionDetail.Text = 'Tick folders in the list, or use the recommendation above.'
        $ui.StartCopyButton.IsEnabled = $false
        $ui.StartCopyButton.Content = 'Copy selected folders'
        return
    }
    if (-not $app.Dest) {
        $ui.SelectionText.Text = ('{0} selected{1}{2}{3}{4}' -f (Format-Plural $selected.Count 'folder' 'folders'), $DOT, (Format-Plural $files 'file' 'files'), $DOT, (Format-Bytes $total))
        $ui.SelectionDetail.Text = 'Choose where to save (above) - then the app compares and copies only what is not there yet.'
        $ui.StartCopyButton.IsEnabled = $false
        return
    }
    $ui.SelectionText.Text = ('{0} selected{1}{2}{3}{4}' -f (Format-Plural $selected.Count 'folder' 'folders'), $DOT, (Format-Plural $files 'file' 'files'), $DOT, (Format-Bytes $total))
    if ($toCopy -le 0) {
        $ui.SelectionDetail.Text = 'All of it is already on this PC. Press Check to confirm every file matches.'
        $ui.StartCopyButton.Content = 'Check selected folders'
    }
    else {
        $eta = Format-Eta ($toCopy / [math]::Max([double] 1MB, [double] $app.Speed))
        $detail = '{0} ({1}) still to copy{2}{3}' -f (Format-Plural $toCopyFiles 'file' 'files'), (Format-Bytes $toCopy), $DOT, $eta
        if ($toCopyFiles -lt $files) { $detail += $DOT + (Format-Plural ($files - $toCopyFiles) 'file is' 'files are') + ' already here and will be skipped' }
        if (-not $fits) { $detail = 'Not enough free space on this PC for this selection. Untick some folders or choose another drive.' }
        $ui.SelectionDetail.Text = $detail
        $ui.StartCopyButton.Content = 'Copy selected folders'
    }
    $ui.StartCopyButton.IsEnabled = $fits -and $app.Dest -and -not $app.CopyRunning
}

function Update-ScanStatus {
    $p = $sync.Progress
    if ($app.Waiting -or $app.DeviceGone) {
        $ui.ScanStatus.Text = 'The iPhone is disconnected or locked. Plug it in and unlock it - reading continues by itself.'
        Set-Color $ui.ScanStatus 'Foreground' $AMBER
        return
    }
    Set-Color $ui.ScanStatus 'Foreground' '#475569'
    if ($app.Scanning -and $p.Phase -eq 'Scan') {
        $total = [int] $p.ScanTotal; $index = [int] $p.ScanIndex
        $pct = 0; if ($total -gt 0) { $pct = [math]::Max([double] 0, [double] ($index - 1) * 100.0 / $total) }
        $ui.ScanBar.Value = $pct
        $ui.ScanBar.Visibility = 'Visible'
        $elapsed = ''
        if ($p.FolderStarted) {
            $seconds = ([DateTime]::UtcNow - $p.FolderStarted).TotalSeconds
            if ($seconds -ge 5) { $elapsed = ' ({0:0}s)' -f $seconds }
        }
        $ui.ScanStatus.Text = ('Reading folder {0} of {1}: {2}{3}{4}{5} found so far' -f $index, $total, $p.ScanFolder, $elapsed, $DOT, (Format-Plural ([int64] $p.ScanFiles) 'file' 'files'))
        $row = $app.RowByName[[string] $p.ScanFolder]
        if ($row -and -not $row.Scanned) {
            $n = [int64] $p.FolderFiles
            if ($n -gt 0) { $row.Status = 'Reading... ' + (Format-Count $n) } else { $row.Status = 'Reading...' }
        }
    }
    elseif ($app.ScanDone) {
        $ui.ScanBar.Visibility = 'Collapsed'
        $notRead = @($app.Rows | Where-Object { -not $_.Scanned }).Count
        if ($notRead -gt 0) { $ui.ScanStatus.Text = (Format-Plural $notRead 'folder was' 'folders were') + ' not read' }
        else { $ui.ScanStatus.Text = 'All folders read' }
    }
}

# ---------------------------------------------------------------------------
# step 3: copy
# ---------------------------------------------------------------------------

function Start-Copy {
    param([string[]] $Names)
    if (-not $Names -or $Names.Count -eq 0) { return }
    if ($app.CopyRunning -or $app.CheckRunning) { return }
    $app.CopyFolders = $Names
    $app.CopyRunning = $true
    $app.CopyDone = $null
    $app.CopyStats = @{ Copied = 0; Already = 0; Failed = 0 }
    $app.CopyRows.Clear()
    foreach ($n in $Names) {
        $r = New-Object IPhoneTransferApp.Row
        $r.Name = $n; $r.Status = 'Waiting'; $r.StatusColor = $GRAY
        $app.CopyRows.Add($r)
    }
    $ui.CopyTitle.Text = 'Copying to this PC'
    if ($app.SourceKind -eq 'Device') { $ui.CopySub.Text = 'Keep the iPhone plugged in and unlocked. This PC will not go to sleep while copying.' }
    else { $ui.CopySub.Text = 'This PC will not go to sleep while copying.' }
    $ui.CopyPercent.Text = '0%'; $ui.CopyBar.Value = 0; $ui.CopyFileBar.Value = 0
    $ui.CopyAmounts.Text = 'Getting ready...'; $ui.CopyRate.Text = ''; $ui.CopyCurrent.Text = ''; $ui.CopyCurrentPct.Text = ''
    $ui.PauseButton.Visibility = 'Visible'; $ui.StopButton.Visibility = 'Visible'
    $ui.PauseButton.Content = 'Pause'; $ui.PauseButton.IsEnabled = $true; $ui.StopButton.IsEnabled = $true
    $ui.CopyBackButton.Visibility = 'Collapsed'; $ui.CopyRetryButton.Visibility = 'Collapsed'
    $ui.CopyStatCopied.Text = 'Copied 0'; $ui.CopyStatAlready.Text = 'Already on PC 0'; $ui.CopyStatFailed.Text = 'Problems 0'
    $window.TaskbarItemInfo.ProgressState = 'Normal'
    Show-Page 'Copy'
    if ($sync.Busy) { $sync.Cancel = $true }   # stop reading the remaining folders
    Send-Command @{ Name = 'Copy'; Folders = [string[]] $Names }
    Write-UiLog ("copy started: {0}" -f ($Names -join ', '))
}

function Update-CopyLive {
    $p = $sync.Progress
    if (-not $app.CopyRunning -or $p.Phase -ne 'Copy') { return }
    $total = [double] $p.BytesTotal
    $done = [double] $p.BytesDone + [double] $p.CurrentBytes
    $fraction = 0.0
    if ($total -gt 0) { $fraction = [math]::Min(1.0, $done / $total) }
    elseif ([int64] $p.FilesTotal -gt 0) { $fraction = [double] $p.FilesDone / [double] $p.FilesTotal }
    $ui.CopyPercent.Text = '{0}%' -f [int] [math]::Floor($fraction * 100)
    $ui.CopyBar.Value = $fraction * 1000
    $window.TaskbarItemInfo.ProgressValue = $fraction
    $ui.CopyAmounts.Text = '{0} of {1}{2}file {3} of {4}' -f (Format-Bytes $done), (Format-Bytes $total), $DOT, (Format-Count ([math]::Min([int64] $p.FilesDone + 1, [int64] $p.FilesTotal))), (Format-Count ([int64] $p.FilesTotal))
    $rate = ''
    if ([double] $p.Speed -gt 0) { $rate = (Format-Bytes ([double] $p.Speed)) + '/s' }
    if ([double] $p.Eta -ge 0) { $rate += $DOT + (Format-Eta ([double] $p.Eta)) + ' left' }
    if ($p.Paused) { $rate = 'Paused - press Resume to carry on' }
    if ($p.Waiting) { $rate = 'Waiting for the iPhone...' }
    $ui.CopyRate.Text = $rate
    $current = $p.Current
    if ($current) {
        $ui.CopyCurrent.Text = '{0}  ({1}, {2})' -f $current.Name, $current.Folder, (Format-Bytes ([double] $current.Size))
        $filePct = 0.0
        if ([double] $current.Size -gt 0) { $filePct = [math]::Min(1.0, [double] $p.CurrentBytes / [double] $current.Size) }
        $ui.CopyFileBar.Value = $filePct * 1000
        $step = ''
        if ($p.Step) { $step = ' - ' + $p.Step }
        $ui.CopyCurrentPct.Text = ('{0}%{1}' -f [int] ($filePct * 100), $step)
    }
    $title = 'iPhone Transfer - copying {0}%' -f [int] [math]::Floor($fraction * 100)
    if ($window.Title -ne $title) { $window.Title = $title }
}

function Complete-Copy {
    param($Result)
    $app.CopyRunning = $false
    $app.CopyDone = $Result
    $window.Title = 'iPhone Transfer'
    if ($Result.Seconds -gt 30 -and $Result.Speed -gt 1MB) { $app.Speed = [double] $Result.Speed; Save-Settings }
    $ui.CopyStatCopied.Text = 'Copied ' + (Format-Count $Result.Copied)
    $ui.CopyStatAlready.Text = 'Already on PC ' + (Format-Count $Result.Already)
    $ui.CopyStatFailed.Text = 'Problems ' + (Format-Count @($Result.Failed).Count)
    $ui.PauseButton.Visibility = 'Collapsed'; $ui.StopButton.Visibility = 'Collapsed'
    $ui.CopyBackButton.Visibility = 'Visible'
    $ui.CopyCurrent.Text = ''; $ui.CopyCurrentPct.Text = ''; $ui.CopyFileBar.Value = 0

    $failedCount = @($Result.Failed).Count
    if ($Result.Cancelled -or $Result.StopReason) {
        $window.TaskbarItemInfo.ProgressState = 'Paused'
        $ui.CopyRate.Text = ''
        $ui.CopyTitle.Text = 'Copying stopped'
        if ($Result.StopReason) { $ui.CopySub.Text = $Result.StopReason }
        else { $ui.CopySub.Text = ('{0} copied before stopping. Everything copied so far is complete and safe. Press Continue copying to carry on.' -f (Format-Plural $Result.Copied 'file was' 'files were')) }
        $ui.CopyRetryButton.Visibility = 'Visible'
        $ui.CopyRetryButton.Content = 'Continue copying'
        [System.Media.SystemSounds]::Exclamation.Play()
        return
    }
    $window.TaskbarItemInfo.ProgressState = 'None'
    if ($failedCount -gt 0) {
        $ui.CopyTitle.Text = 'Copy finished, with problems'
        $ui.CopySub.Text = ('{0} could not be copied (see the log). Press Try again, or check what was copied.' -f (Format-Plural $failedCount 'file' 'files'))
        $ui.CopyRetryButton.Visibility = 'Visible'
        $ui.CopyRetryButton.Content = 'Try again'
    }
    else {
        $ui.CopyTitle.Text = 'Copy finished'
        $ui.CopySub.Text = ('{0} ({1}) copied. Now every file gets checked.' -f (Format-Plural $Result.Copied 'file' 'files'), (Format-Bytes $Result.CopiedBytes))
    }
    $ui.CopyPercent.Text = '100%'; $ui.CopyBar.Value = 1000
    [System.Media.SystemSounds]::Asterisk.Play()
    # Straight on to the check - that is what makes the copy trustworthy.
    Start-Check -Names $app.CopyFolders -Full $false
}

# ---------------------------------------------------------------------------
# step 4: check
# ---------------------------------------------------------------------------

function Start-Check {
    param([string[]] $Names, [bool] $Full)
    if (-not $Names -or $Names.Count -eq 0) { return }
    $app.CheckFolders = $Names
    if ($app.SourceKind -eq 'Device') { $ui.CheckGrid.Columns[1].Header = 'On the iPhone' } else { $ui.CheckGrid.Columns[1].Header = 'In the source folder' }
    $app.CheckRunning = $true
    $app.CheckDone = $null
    $app.CheckRows.Clear()
    foreach ($n in $Names) {
        $r = New-Object IPhoneTransferApp.Row
        $r.Name = $n; $r.Status = 'Waiting'; $r.StatusColor = $GRAY
        $s = $app.Summaries[$n]
        if ($s) { $r.Phone = '{0}, {1}' -f (Format-Plural $s.Files 'file' 'files'), (Format-Bytes $s.Bytes) }
        $app.CheckRows.Add($r)
    }
    $ui.ProblemsList.Items.Clear()
    $ui.ProblemsExpander.Visibility = 'Collapsed'
    $ui.VerdictCard.Visibility = 'Collapsed'
    $ui.CheckProgressCard.Visibility = 'Visible'
    $ui.CheckPercent.Text = '0%'; $ui.CheckBar.Value = 0
    $ui.CheckStep.Text = 'Getting ready...'; $ui.CheckDetail.Text = ''
    if ($Full) {
        $ui.CheckTitle.Text = 'Full check: reading every file again'
        $ui.CheckSub.Text = ('Every file is read from {0} again and compared, byte for byte, with its copy on this PC.' -f (Get-SourceWord))
    }
    else {
        $ui.CheckTitle.Text = 'Checking every file'
        $ui.CheckSub.Text = ('Each file from {0} is compared with its copy on this PC: name, size, and a digital fingerprint of the content.' -f (Get-SourceWord))
    }
    foreach ($b in 'OpenReportButton', 'FullCheckButton', 'GoDeleteButton') { $ui[$b].IsEnabled = $false }
    $ui.FixButton.Visibility = 'Collapsed'
    $window.TaskbarItemInfo.ProgressState = 'Normal'
    Show-Page 'Check'
    Send-Command @{ Name = 'Verify'; Folders = [string[]] $Names; Full = $Full }
    Write-UiLog ("check started (full={0}): {1}" -f $Full, ($Names -join ', '))
}

function Update-CheckLive {
    $p = $sync.Progress
    if (-not $app.CheckRunning -or $p.Phase -ne 'Verify') { return }
    $total = [double] $p.BytesTotal
    $done = [double] $p.BytesDone + [double] $p.CurrentBytes
    $fraction = 0.0
    if ($total -gt 0) { $fraction = [math]::Min(1.0, $done / $total) }
    $ui.CheckPercent.Text = '{0}%' -f [int] [math]::Floor($fraction * 100)
    $ui.CheckBar.Value = $fraction * 1000
    $window.TaskbarItemInfo.ProgressValue = $fraction
    $ui.CheckStep.Text = [string] $p.Step
    if ($p.Step -eq 'Checking every file') {
        $detail = 'File {0} of {1}' -f (Format-Count ([math]::Min([int64] $p.FilesDone + 1, [int64] $p.FilesTotal))), (Format-Count ([int64] $p.FilesTotal))
        $current = $p.Current
        if ($current) { $detail += $DOT + $current.Folder + '\' + $current.Name }
        if ([double] $p.Eta -ge 0) { $detail += $DOT + (Format-Eta ([double] $p.Eta)) + ' left' }
        $ui.CheckDetail.Text = $detail
    }
    elseif ($p.CurrentFolder) { $ui.CheckDetail.Text = 'Folder ' + $p.CurrentFolder }
}

function Update-CheckRow {
    param($Summary)
    $row = $app.CheckRows | Where-Object { $_.Name -eq $Summary.Name } | Select-Object -First 1
    if (-not $row) { return }
    $row.Phone = '{0}, {1}' -f (Format-Plural $Summary.PhoneFiles 'file' 'files'), (Format-Bytes $Summary.PhoneBytes)
    $row.Laptop = '{0}, {1}' -f (Format-Plural $Summary.PcFiles 'file' 'files'), (Format-Bytes $Summary.PcBytes)
    if (-not $Summary.Readable) { $row.Status = 'Could not read this folder on the iPhone'; $row.StatusColor = $RED }
    elseif ($Summary.PhoneFiles -eq 0) { $row.Status = 'No files on the iPhone'; $row.StatusColor = $GRAY }
    elseif ($Summary.Ok) {
        $row.Status = [string] [char] 0x2713 + (' All {0} match - 100% safe' -f (Format-Count $Summary.OkFiles)); $row.StatusColor = $GREEN
        $app.VerifiedOk[$Summary.Name] = $Summary
        $app.PartialOk.Remove($Summary.Name)
    }
    else {
        $row.Status = ('{0} of {1} match - {2}' -f (Format-Count $Summary.OkFiles), (Format-Count $Summary.PhoneFiles), (Format-Plural $Summary.ProblemCount 'needs attention' 'need attention')); $row.StatusColor = $AMBER
        $app.VerifiedOk.Remove($Summary.Name)
        if ($Summary.DeletableFiles -gt 0) { $app.PartialOk[$Summary.Name] = $Summary } else { $app.PartialOk.Remove($Summary.Name) }
        foreach ($problem in $Summary.Problems) { [void] $ui.ProblemsList.Items.Add(('{0}   -   {1}' -f $problem.Name, $problem.Detail)) }
        if ($Summary.ProblemCount -gt $Summary.Problems.Count) { [void] $ui.ProblemsList.Items.Add(('... and {0} more in the report' -f ($Summary.ProblemCount - $Summary.Problems.Count))) }
        $ui.ProblemsExpander.Visibility = 'Visible'
        $ui.ProblemsExpander.IsExpanded = $true
    }
}

function Complete-Check {
    param($Result)
    $app.CheckRunning = $false
    $app.CheckDone = $Result
    $app.Report = [string] $Result.Report
    $window.TaskbarItemInfo.ProgressState = 'None'
    $ui.CheckProgressCard.Visibility = 'Collapsed'
    $ui.OpenReportButton.IsEnabled = [bool] $app.Report
    $ui.FullCheckButton.IsEnabled = $true
    $okFolders = @($app.CheckFolders | Where-Object { $app.VerifiedOk.ContainsKey($_) -or $app.PartialOk.ContainsKey($_) })
    $ui.GoDeleteButton.IsEnabled = ($okFolders.Count -gt 0)

    $phoneFiles = 0; $okFiles = 0
    foreach ($n in $app.CheckFolders) {
        $s = $app.VerifiedOk[$n]
        if ($s) { $phoneFiles += $s.PhoneFiles; $okFiles += $s.OkFiles }
    }
    $ui.VerdictCard.Visibility = 'Visible'
    if ($Result.AllOk) {
        Set-Color $ui.VerdictCard 'Background' '#F0FDF4'; Set-Color $ui.VerdictCard 'BorderBrush' '#86EFAC'
        Set-Color $ui.VerdictIconBack 'Background' '#16A34A'; $ui.VerdictIcon.Text = [string] [char] 0xE73E
        $ui.VerdictTitle.Text = ('All {0} are safely on this PC.' -f (Format-Plural $okFiles 'file' 'files'))
        Set-Color $ui.VerdictTitle 'Foreground' '#14532D'
        $how = 'Every file was found with the same name and size, and its content matched its fingerprint 100%.'
        if ($Result.Full) { $how = ('Every file was read from {0} again and matched its copy on this PC byte for byte.' -f (Get-SourceWord)) }
        $ui.VerdictText.Text = $how + (' You can now free up the space on {0} with confidence.' -f (Get-SourceWord))
        Set-Color $ui.VerdictText 'Foreground' '#166534'
        $ui.CheckTitle.Text = 'Check complete'
        [System.Media.SystemSounds]::Asterisk.Play()
    }
    else {
        Set-Color $ui.VerdictCard 'Background' '#FFFBEB'; Set-Color $ui.VerdictCard 'BorderBrush' '#FCD34D'
        Set-Color $ui.VerdictIconBack 'Background' '#D97706'; $ui.VerdictIcon.Text = [string] [char] 0xE7BA
        $bad = @($app.CheckRows | Where-Object { $_.StatusColor -ne $GREEN })
        $ui.VerdictTitle.Text = ('{0} not fully on this PC yet.' -f (Format-Plural $bad.Count 'folder is' 'folders are'))
        Set-Color $ui.VerdictTitle 'Foreground' '#78350F'
        $ui.VerdictText.Text = 'Press "Copy the missing files" to try them again (unplug and replug the iPhone first if it stopped sending files). You can already free up everything that matched: problem files - and every file of the photos they belong to - stay on the iPhone.'
        Set-Color $ui.VerdictText 'Foreground' '#92400E'
        $ui.FixButton.Visibility = 'Visible'
        $ui.CheckTitle.Text = 'Check complete - some files need attention'
        [System.Media.SystemSounds]::Exclamation.Play()
    }
    foreach ($n in $app.CheckFolders) {
        $row = $app.RowByName[$n]
        if ($row -and $app.Summaries[$n]) { Update-Row $app.Summaries[$n] }
    }
}

# ---------------------------------------------------------------------------
# step 5: free up
# ---------------------------------------------------------------------------

function Show-DeletePage {
    $app.DeleteRows.Clear()
    $app.DeleteDone = $null
    foreach ($n in ($app.VerifiedOk.Keys | Sort-Object)) {
        $s = $app.VerifiedOk[$n]
        $r = New-Object IPhoneTransferApp.Row
        $r.Name = $n
        $sum = $app.Summaries[$n]
        if ($sum) { $r.Dates = Format-Dates $sum.FirstDate $sum.LastDate }
        $r.Files = Format-Count $s.OkFiles; $r.FileCount = [int64] $s.OkFiles
        $r.Size = Format-Bytes $s.PhoneBytes; $r.Bytes = [int64] $s.PhoneBytes
        $r.Status = [string] [char] 0x2713 + ' Every file checked'; $r.StatusColor = $GREEN
        $r.Selected = $false
        $app.DeleteRows.Add($r)
    }
    foreach ($n in ($app.PartialOk.Keys | Sort-Object)) {
        if ($app.VerifiedOk.ContainsKey($n)) { continue }
        $s = $app.PartialOk[$n]
        $r = New-Object IPhoneTransferApp.Row
        $r.Name = $n
        $sum = $app.Summaries[$n]
        if ($sum) { $r.Dates = Format-Dates $sum.FirstDate $sum.LastDate }
        $r.Files = Format-Count $s.DeletableFiles; $r.FileCount = [int64] $s.DeletableFiles
        $r.Size = Format-Bytes $s.DeletableBytes; $r.Bytes = [int64] $s.DeletableBytes
        $r.Status = ('Partly: {0} stay on the iPhone (files that did not match, and the photos they belong to)' -f (Format-Plural $s.KeptFiles 'file' 'files')); $r.StatusColor = $AMBER
        $r.Selected = $false
        $app.DeleteRows.Add($r)
    }
    $ui.DeleteConfirmCheck.IsChecked = $false
    $ui.DeleteConfirmCheck.IsEnabled = $true
    $ui.DeleteConfirmCheck.Visibility = 'Visible'
    $ui.DeleteProgressCard.Visibility = 'Collapsed'
    $ui.DeleteButton.Visibility = 'Visible'; $ui.FinishButton.Visibility = 'Collapsed'; $ui.DeleteBackButton.Visibility = 'Visible'
    $ui.DeleteTitle.Text = 'Free up space on your iPhone'
    if ($app.SourceKind -eq 'Device') {
        $ui.DeleteSub.Text = 'Only folders where every single file was found on this PC and matched are listed. Tick the ones to remove from the iPhone.'
        $ui.DeleteWarnTitle.Text = 'Deleting from the iPhone cannot be undone from this PC'
        $ui.DeleteConfirmCheck.Content.Text = 'I understand the selected files will be removed from my iPhone. Their copies stay on this PC.'
    }
    else {
        $ui.DeleteSub.Text = 'Only folders where every single file was found in the destination and matched are listed.'
        $ui.DeleteWarnTitle.Text = 'The files go to the Recycle Bin of this PC'
        $ui.DeleteWarnText.Text = 'The copies in the destination are not touched. Files added to a folder after the check are never deleted.'
        $ui.DeleteConfirmCheck.Content.Text = 'I understand the selected files will be removed from the source folder. Their copies stay in the destination.'
    }
    Show-Page 'Delete'
}

function Update-DeleteSelection {
    if ($app.DeleteRunning -or $app.DeleteDone) { return }
    $selected = @($app.DeleteRows | Where-Object { $_.Selected })
    $files = [int64] 0; $bytes = [int64] 0
    foreach ($r in $selected) { $files += $r.FileCount; $bytes += $r.Bytes }
    if ($selected.Count -eq 0) {
        $ui.DeleteSelectionText.Text = 'Tick the folders to remove from the iPhone'
        $ui.DeleteButton.Content = 'Delete from iPhone'
    }
    else {
        $ui.DeleteSelectionText.Text = ('{0} selected{1}{2}{3}frees {4}' -f (Format-Plural $selected.Count 'folder' 'folders'), $DOT, (Format-Plural $files 'file' 'files'), $DOT, (Format-Bytes $bytes))
        $ui.DeleteButton.Content = 'Delete {0} ({1})' -f (Format-Plural $files 'file' 'files'), (Format-Bytes $bytes)
    }
    $ui.DeleteButton.IsEnabled = ($selected.Count -gt 0) -and [bool] $ui.DeleteConfirmCheck.IsChecked
}

function Start-Delete {
    $selected = @($app.DeleteRows | Where-Object { $_.Selected })
    if ($selected.Count -eq 0) { return }
    $files = [int64] 0; $bytes = [int64] 0
    foreach ($r in $selected) { $files += $r.FileCount; $bytes += $r.Bytes }
    $where = 'your iPhone'
    if ($app.SourceKind -ne 'Device') { $where = 'the source folder (to the Recycle Bin)' }
    $text = "Delete {0} ({1}) from {2}?`r`n`r`nFolders: {3}`r`n`r`nEvery one of these files was checked and is safely on this PC in:`r`n{4}`r`n`r`nThis cannot be undone from this PC." -f (Format-Plural $files 'file' 'files'), (Format-Bytes $bytes), $where, (($selected | ForEach-Object { $_.Name }) -join ', '), $app.Dest
    if (-not (Confirm-Action $text 'Delete from iPhone?' 'Warning')) { return }
    $app.DeleteRunning = $true
    foreach ($r in $app.DeleteRows) { $r.CanSelect = $false; if ($r.Selected) { $r.Status = 'Waiting'; $r.StatusColor = $GRAY } }
    $ui.DeleteButton.IsEnabled = $false; $ui.DeleteBackButton.Visibility = 'Collapsed'; $ui.DeleteConfirmCheck.IsEnabled = $false
    $ui.DeleteProgressCard.Visibility = 'Visible'; $ui.DeleteBar.Value = 0; $ui.DeletePercent.Text = '0%'
    Send-Command @{ Name = 'Delete'; Folders = [string[]] @($selected | ForEach-Object { $_.Name }) }
    Write-UiLog ("delete confirmed: {0}" -f (($selected | ForEach-Object { $_.Name }) -join ', '))
}

function Update-DeleteLive {
    $p = $sync.Progress
    if (-not $app.DeleteRunning -or $p.Phase -ne 'Delete') { return }
    $fraction = 0.0
    if ([int64] $p.FilesTotal -gt 0) { $fraction = [math]::Min(1.0, [double] $p.FilesDone / [double] $p.FilesTotal) }
    $ui.DeletePercent.Text = '{0}%' -f [int] ($fraction * 100)
    $ui.DeleteBar.Value = $fraction * 1000
    $name = ''
    if ($p.Current) { $name = $p.Current.Folder + '\' + $p.Current.Name }
    $ui.DeleteDetail.Text = '{0} of {1}{2}{3}' -f (Format-Count ([int64] $p.FilesDone)), (Format-Plural ([int64] $p.FilesTotal) 'file' 'files'), $DOT, $name
}

function Complete-Delete {
    param($Result)
    $app.DeleteRunning = $false
    $app.DeleteDone = $Result
    $ui.DeleteProgressCard.Visibility = 'Collapsed'
    $ui.DeleteButton.Visibility = 'Collapsed'
    $ui.FinishButton.Visibility = 'Visible'
    $ui.DeleteConfirmCheck.IsEnabled = $false
    $where = 'the iPhone'; if ($app.SourceKind -ne 'Device') { $where = 'the source folder' }
    $ui.DeleteTitle.Text = 'Done - {0} freed on {1}' -f (Format-Bytes $Result.DeletedBytes), $where
    $text = '{0} removed from {1}. The copies on this PC are untouched.' -f (Format-Plural $Result.Deleted 'file' 'files'), $where
    if ($Result.Kept -gt 0) { $text += ' ' + (Format-Plural $Result.Kept 'file was' 'files were') + ' kept because they were added or changed after the check.' }
    if ($Result.Failed -gt 0) { $text += ' ' + (Format-Plural $Result.Failed 'file' 'files') + ' could not be deleted - see the activity log.' }
    $ui.DeleteSub.Text = $text
    $ui.DeleteConfirmCheck.Visibility = 'Collapsed'
    if ($app.SourceKind -eq 'Device') { $ui.DeleteSelectionText.Text = 'All done. You can unplug the iPhone now.' }
    else { $ui.DeleteSelectionText.Text = 'All done.' }
    foreach ($n in @($app.DeleteRows | ForEach-Object { $_.Name })) { $app.VerifiedOk.Remove($n); $app.PartialOk.Remove($n) }
    [System.Media.SystemSounds]::Asterisk.Play()
}

# ---------------------------------------------------------------------------
# events from the engine
# ---------------------------------------------------------------------------

function Invoke-EngineEvent {
    param($e)
    switch ($e.Type) {
        'DeviceState' {
            Update-ConnectCard $e
            $app.DeviceGone = ($app.SourceKind -eq 'Device' -and $e.State -ne 'Ready')
        }
        'FolderList' {
            if ($DemoPhone) { $e.Kind = 'Device'; $e.Label = 'Apple iPhone\Internal Storage'; $e.Capacity = [int64] 128GB; $e.LooseFiles = 0 }
            $app.SourceKind = $e.Kind; $app.SourceLabel = $e.Label; $app.Capacity = [int64] $e.Capacity
            $app.Rows.Clear(); $app.RowByName = @{}; $app.Summaries = @{}; $app.VerifiedOk = @{}; $app.PartialOk = @{}
            foreach ($n in $e.Names) {
                $r = New-Object IPhoneTransferApp.Row
                $r.Name = $n; $r.Status = 'Waiting to be read'; $r.StatusColor = $GRAY; $r.CanSelect = $false
                $r.Dates = Get-FolderLabel $n
                $app.Rows.Add($r); $app.RowByName[$n] = $r
            }
            if ($e.Kind -eq 'Device') { $ui.FolderListLabel.Text = 'Folders on the iPhone' } else { $ui.FolderListLabel.Text = 'Folders' }
            if ($e.Kind -eq 'Device') {
                $app.SourcePath = ''
                $ui.AnalyzeTitle.Text = "What's on your iPhone"
                $ui.AnalyzeSub.Text = 'Every folder is being read and compared with the folder you save to. Files already there - in any of its folders - are skipped. All file types are copied, including edits and Live Photo videos.'
                $ui.SourceText.Text = $e.Label
                $ui.UseIPhoneButton.Visibility = 'Collapsed'
            }
            else {
                $app.SourcePath = $e.Label
                $ui.AnalyzeTitle.Text = 'What is in ' + (Split-Path -Leaf $e.Label)
                $ui.AnalyzeSub.Text = 'Every folder is being read and compared with the folder you save to. Files already there - in any of its folders - are skipped.'
                if ($e.LooseFiles -gt 0) { $ui.AnalyzeSub.Text += (' {0} directly in the chosen folder, not in any of its sub-folders, and left out.' -f (Format-Plural $e.LooseFiles 'file is' 'files are')) }
                $ui.SourceText.Text = $e.Label
                $ui.UseIPhoneButton.Visibility = 'Visible'
            }
            $ui.SourceText.ToolTip = $ui.SourceText.Text
            Show-Page 'Analyze'
            Update-SummaryChips
            # The destination is checked again against this source (they must not overlap).
            $wanted = $app.Dest
            if (-not $wanted) { $wanted = Get-DefaultDestination }
            $app.Dest = ''
            if ($wanted) { Set-Destination $wanted }
            if (-not $app.Dest) { Show-NoDestination; Send-Command @{ Name = 'SetDestination'; Path = '' } }
            Update-DrivePanel
            $app.Scanning = $true; $app.ScanDone = $false; $app.AutoSelected = $false
            Send-Command @{ Name = 'Scan'; Folders = [string[]] $e.Names }
        }
        'FolderScanning' {
            $row = $app.RowByName[$e.Name]
            if ($row) { $row.Status = 'Reading...'; $row.StatusColor = $BLUE }
        }
        'FolderScanned' { Update-Row $e; Update-SummaryChips; Update-Recommendation }
        'FolderStatus'  { Update-Row $e; Update-Recommendation }
        'ScanDone' {
            $app.Scanning = $false; $app.ScanDone = $true
            foreach ($row in $app.Rows) { if (-not $row.Scanned) { $row.Status = 'Not read'; $row.StatusColor = $GRAY; $row.Note = 'Press Read again to read it.' } }
            Update-Recommendation
            if ($app.Dest -and -not $app.AutoSelected -and @($app.Rows | Where-Object { $_.Selected }).Count -eq 0) { Select-Recommended; $app.AutoSelected = $true }
            Write-UiLog 'scan complete'
        }
        'Session' {
            $app.Session = $e
            if ($app.ScanDone -and $app.Dest -and -not $app.AutoSelected) {
                Update-Recommendation
                if (@($app.Rows | Where-Object { $_.Selected }).Count -eq 0) { Select-Recommended }
                $app.AutoSelected = $true
            }
            if ($e.State -eq 'copying' -and @($e.Folders).Count -gt 0) {
                $ui.ResumeButton.Visibility = 'Visible'
                $ui.ResumeButton.ToolTip = 'Last copy (' + (@($e.Folders) -join ', ') + ') did not finish. Continue it.'
            }
            else { $ui.ResumeButton.Visibility = 'Collapsed' }
        }
        'CopyPlan' {
            $stats = $app.CopyStats
            $stats.Already = $e.Already
            $ui.CopyStatAlready.Text = 'Already on PC ' + (Format-Count $e.Already)
            foreach ($f in $e.Folders) {
                $row = $app.CopyRows | Where-Object { $_.Name -eq $f.Name } | Select-Object -First 1
                if (-not $row) { continue }
                $row.FilesToCopy = [int64] $f.ToCopy; $row.BytesToCopy = [int64] $f.ToCopyBytes
                $row.Files = '{0} of {1}' -f (Format-Count $f.ToCopy), (Format-Count $f.Total)
                $row.Size = Format-Bytes $f.ToCopyBytes
                if ($f.ToCopy -eq 0) { $row.Status = [string] [char] 0x2713 + ' Already on this PC'; $row.StatusColor = $GREEN; $row.Percent = 100 }
            }
            if ($e.Files -eq 0) { $ui.CopyAmounts.Text = 'Everything is already on this PC.' }
        }
        'CopyFolderProgress' {
            $row = $app.CopyRows | Where-Object { $_.Name -eq $e.Name } | Select-Object -First 1
            if ($row) {
                $pct = 100.0
                if ($e.ToCopyBytes -gt 0) { $pct = [math]::Min(100.0, 100.0 * $e.DoneBytes / $e.ToCopyBytes) }
                elseif ($e.ToCopy -gt 0) { $pct = 100.0 * ($e.Done + $e.Failed) / $e.ToCopy }
                $row.Percent = $pct
                if (($e.Done + $e.Failed) -ge $e.ToCopy) {
                    if ($e.Failed -gt 0) { $row.Status = ('Done - {0} could not be copied' -f (Format-Plural $e.Failed 'file' 'files')); $row.StatusColor = $AMBER }
                    else { $row.Status = [string] [char] 0x2713 + ' Copied'; $row.StatusColor = $GREEN }
                }
                else {
                    $row.Status = 'Copying - {0} of {1}' -f (Format-Count $e.Done), (Format-Count $e.ToCopy); $row.StatusColor = $BLUE
                    if ($e.Failed -gt 0) { $row.Status += (' ({0} failed)' -f $e.Failed) }
                }
            }
            $ui.CopyStatCopied.Text = 'Copied ' + (Format-Count ([int64] $e.TotalCopied))
            $ui.CopyStatFailed.Text = 'Problems ' + (Format-Count ([int64] $e.TotalFailed))
        }
        'Trouble' {
            # Connected, but the phone has stopped handing over files.
            $app.Waiting = [bool] $e.On
            if ($e.On) {
                $ui.WaitingTitle.Text = 'The iPhone has stopped sending files'
                $ui.WaitingText.Text = 'Unplug the iPhone, plug it back in and unlock it - copying then continues by itself. Or press "Try again now". Nothing copied so far is lost; files that failed are tried again at the end.'
                $ui.TryAgainButton.Visibility = 'Visible'
                $ui.WaitingBanner.Visibility = 'Visible'
                $ui.CopyRate.Text = 'Waiting for the iPhone...'
                $window.TaskbarItemInfo.ProgressState = 'Paused'
                [System.Media.SystemSounds]::Exclamation.Play()
            }
            else {
                $ui.WaitingBanner.Visibility = 'Collapsed'; $ui.TryAgainButton.Visibility = 'Collapsed'
                $ui.WaitingTitle.Text = 'The iPhone was disconnected'
                $ui.WaitingText.Text = 'Plug it back in and unlock it - copying continues by itself from where it stopped. Nothing copied so far is lost.'
                $window.TaskbarItemInfo.ProgressState = 'Normal'
            }
        }
        'Waiting' {
            $app.Waiting = [bool] $e.On
            if ($e.On) {
                $ui.WaitingBanner.Visibility = 'Visible'
                $window.TaskbarItemInfo.ProgressState = 'Paused'
                if ($app.Page -eq 'Check') { $ui.CheckStep.Text = 'Waiting for the iPhone - plug it back in and unlock it' }
                [System.Media.SystemSounds]::Exclamation.Play()
            }
            else { $ui.WaitingBanner.Visibility = 'Collapsed'; $window.TaskbarItemInfo.ProgressState = 'Normal' }
        }
        'CopyDone' { Complete-Copy $e }
        'CompareDone' {
            $files = 0; $present = 0; $elsewhere = 0; $missing = 0; $missingBytes = [int64] 0
            foreach ($f in $e.Folders) { $files += $f.Files; $present += $f.Present; $elsewhere += $f.Elsewhere; $missing += $f.Missing; $missingBytes += $f.MissingBytes }
            $app.CompareResult = $e
            $text = "{0} compared with {1}:`r`n`r`n  Already on this PC:  {2}" -f (Format-Plural $files 'file' 'files'), $app.Dest, (Format-Count $present)
            if ($elsewhere -gt 0) { $text += "`r`n     (of these, {0} in a differently named folder)" -f (Format-Count $elsewhere) }
            $text += "`r`n  Not on this PC yet:  {0} ({1})" -f (Format-Count $missing), (Format-Bytes $missingBytes)
            $text += "`r`n`r`nThe report with every file opens now. Press ""Copy selected folders"" to copy only the files that are not there yet."
            Write-UiLog ("compare: {0} files, {1} present, {2} missing" -f $files, $present, $missing)
            if ($e.Report) { Open-Path $e.Report }
            Show-Message $text 'Compare'
        }
        'VerifyPlan' { }
        'FolderVerified' { Update-CheckRow $e }
        'VerifyDone' { Complete-Check $e }
        'FolderDeleted' {
            $row = $app.DeleteRows | Where-Object { $_.Name -eq $e.Name } | Select-Object -First 1
            if ($row) {
                if ($e.Refused) { $row.Status = 'Not deleted - it did not pass the check'; $row.StatusColor = $AMBER }
                else {
                    $s = [string] [char] 0x2713 + (' {0} deleted, {1} freed' -f (Format-Count $e.Deleted), (Format-Bytes $e.DeletedBytes))
                    if ($e.Kept -gt 0) { $s += (', {0} kept' -f $e.Kept) }
                    if ($e.Failed -gt 0) { $s += (', {0} failed' -f $e.Failed) }
                    $row.Status = $s
                    if ($e.Failed -gt 0) { $row.StatusColor = $AMBER } else { $row.StatusColor = $GREEN }
                }
            }
        }
        'DeleteDone' { Complete-Delete $e }
        'Cancelled' {
            if ($e.Command -eq 'Verify') {
                $app.CheckRunning = $false
                $ui.CheckProgressCard.Visibility = 'Collapsed'
                $ui.CheckTitle.Text = 'Check stopped'
                $ui.FullCheckButton.IsEnabled = $true
                $window.TaskbarItemInfo.ProgressState = 'None'
            }
            elseif ($e.Command -eq 'Delete') {
                Complete-Delete @{ Deleted = 0; DeletedBytes = 0; Kept = 0; Failed = 0 }
                $ui.DeleteTitle.Text = 'Deleting stopped'
            }
            elseif ($e.Command -eq 'Scan') { $app.Scanning = $false }
        }
        'Error' {
            Write-UiLog "engine error in $($e.Command): $($e.Message)"
            switch ($e.Command) {
                'SetSource' { Show-Page 'Connect'; Show-Message ("Could not open the source.`r`n`r`n" + $e.Message) 'iPhone Transfer' 'Warning' }
                'Copy' {
                    $app.CopyRunning = $false
                    $ui.CopyTitle.Text = 'Copying stopped because of a problem'
                    $ui.CopySub.Text = $e.Message
                    $ui.PauseButton.Visibility = 'Collapsed'; $ui.StopButton.Visibility = 'Collapsed'
                    $ui.CopyBackButton.Visibility = 'Visible'; $ui.CopyRetryButton.Visibility = 'Visible'; $ui.CopyRetryButton.Content = 'Try again'
                    $window.TaskbarItemInfo.ProgressState = 'Error'
                }
                'Verify' {
                    $app.CheckRunning = $false
                    $ui.CheckProgressCard.Visibility = 'Collapsed'
                    $ui.CheckTitle.Text = 'The check could not finish'
                    $ui.CheckSub.Text = $e.Message
                    $ui.FullCheckButton.IsEnabled = $true
                }
                'Delete' { Complete-Delete @{ Deleted = 0; DeletedBytes = 0; Kept = 0; Failed = 0 }; $ui.DeleteTitle.Text = 'Deleting stopped'; $ui.DeleteSub.Text = $e.Message }
                'Scan' { $app.Scanning = $false; $app.ScanDone = $true; Update-Recommendation }
                default { Show-Message $e.Message 'iPhone Transfer' 'Warning' }
            }
        }
        'EngineCrashed' { Show-Message ("Something went wrong in the background.`r`n`r`n" + $e.Message + "`r`n`r`nPlease close and start the app again. Nothing already copied is lost.") 'iPhone Transfer' 'Error' }
    }
}

# ---------------------------------------------------------------------------
# button handlers
# ---------------------------------------------------------------------------

function Invoke-Safely {
    param([scriptblock] $Action)
    try { & $Action }
    catch {
        Write-UiLog ("window error: {0} {1}" -f $_.Exception.Message, $_.ScriptStackTrace)
        Show-Message ("Something went wrong: " + $_.Exception.Message) 'iPhone Transfer' 'Warning'
    }
}

$ui.ConnectContinue.Add_Click({ Invoke-Safely {
    if ($DemoPhone) { Start-Analysis -Kind 'Folder' -Path $DemoPhone } else { Start-Analysis -Kind 'Device' }
} })
$ui.UseFolderButton.Add_Click({ Invoke-Safely {
    $path = Select-FolderDialog 'Choose the folder to copy from (for example the DCIM folder of an SD card).' ''
    if ($path) { $script:SourceFolder = $path; $sync.Watch = $false; Start-Analysis -Kind 'Folder' -Path $path }
} })
$ui.ChangeSourceButton.Add_Click({ Invoke-Safely {
    if ($sync.Busy -and -not $app.Scanning) { Show-Message 'Please wait until the current step has finished.'; return }
    $path = Select-FolderDialog 'Choose the folder to copy FROM. It can hold month folders, or the photos themselves.' $app.SourcePath
    if (-not $path) { return }
    if ($app.Dest -and (Test-Inside $path $app.Dest)) { Show-Message 'That folder is the same as, or inside, the folder you save to. Please choose another one.' 'iPhone Transfer' 'Warning'; return }
    if ($app.Scanning) { $sync.Cancel = $true }
    $script:SourceFolder = $path; $sync.Watch = $false
    Start-Analysis -Kind 'Folder' -Path $path
} })
$ui.UseIPhoneButton.Add_Click({ Invoke-Safely {
    if ($sync.Busy -and -not $app.Scanning) { Show-Message 'Please wait until the current step has finished.'; return }
    if ($app.Scanning) { $sync.Cancel = $true }
    $script:SourceFolder = ''; $sync.Watch = $true
    if ($app.Device -and $app.Device.State -eq 'Ready') { Start-Analysis -Kind 'Device' }
    else { Show-Page 'Connect' }
} })
$ui.CompareButton.Add_Click({ Invoke-Safely {
    $names = [string[]] @($app.Rows | Where-Object { $_.Selected -and $_.CanSelect } | ForEach-Object { $_.Name })
    if ($names.Count -eq 0 -or -not $app.Dest) { return }
    $ui.CompareButton.IsEnabled = $false
    $ui.SelectionDetail.Text = 'Comparing...'
    Send-Command @{ Name = 'Compare'; Folders = $names }
} })
$ui.ChangeDestButton.Add_Click({ Invoke-Safely {
    $path = Select-FolderDialog 'Choose where to save the photos and videos.' $app.Dest
    if ($path) { Set-Destination $path -ByUser; Update-DrivePanel }
} })
$ui.OpenDestButton.Add_Click({ Invoke-Safely { New-Item -ItemType Directory -Force -Path $app.Dest | Out-Null; Open-Path $app.Dest } })
$ui.SelectRecommendedButton.Add_Click({ Invoke-Safely { Select-Recommended } })
$ui.SelectAllButton.Add_Click({ Invoke-Safely { foreach ($r in $app.Rows) { if ($r.CanSelect) { $r.Selected = $true } } } })
$ui.SelectNoneButton.Add_Click({ Invoke-Safely { foreach ($r in $app.Rows) { $r.Selected = $false } } })
$ui.ResumeButton.Add_Click({ Invoke-Safely {
    $names = @($app.Session.Folders | Where-Object { $app.RowByName.ContainsKey($_) -and $app.RowByName[$_].CanSelect })
    if ($names.Count -eq 0) { Show-Message 'Those folders are not on this iPhone any more.'; return }
    foreach ($r in $app.Rows) { $r.Selected = ($names -contains $r.Name) }
    Start-Copy -Names $names
} })
$ui.StartCopyButton.Add_Click({ Invoke-Safely {
    $names = [string[]] @($app.Rows | Where-Object { $_.Selected -and $_.CanSelect } | ForEach-Object { $_.Name })
    if ($names.Count -eq 0) { return }
    if ($app.Scanning) {
        if (-not (Confirm-Action 'Some folders are still being read. Stop reading them and start copying the selected folders now?')) { return }
    }
    Save-Settings
    Start-Copy -Names $names
} })
$ui.PauseButton.Add_Click({ Invoke-Safely {
    if ($sync.Pause) { $sync.Pause = $false; $ui.PauseButton.Content = 'Pause'; $window.TaskbarItemInfo.ProgressState = 'Normal' }
    else { $sync.Pause = $true; $ui.PauseButton.Content = 'Resume'; $window.TaskbarItemInfo.ProgressState = 'Paused'; $ui.CopyRate.Text = 'Pausing after the current file...' }
} })
$ui.StopButton.Add_Click({ Invoke-Safely {
    if (Confirm-Action 'Stop copying? Everything copied so far is complete and kept. You can continue later from where it stopped.') {
        $sync.Cancel = $true; $sync.Pause = $false
        $ui.StopButton.IsEnabled = $false; $ui.PauseButton.IsEnabled = $false
        $ui.CopyRate.Text = 'Stopping...'
    }
} })
$ui.TryAgainButton.Add_Click({ Invoke-Safely { $sync.TryAgain = $true; $ui.TryAgainButton.Visibility = 'Collapsed'; $ui.CopyRate.Text = 'Trying again...' } })
$ui.CopyBackButton.Add_Click({ Invoke-Safely { Show-Page 'Analyze'; Update-Recommendation } })
$ui.CopyRetryButton.Add_Click({ Invoke-Safely { Start-Copy -Names $app.CopyFolders } })
$ui.OpenReportButton.Add_Click({ Invoke-Safely { Open-Path $app.Report } })
$ui.OpenPhotosButton.Add_Click({ Invoke-Safely { Open-Path $app.Dest } })
$ui.FullCheckButton.Add_Click({ Invoke-Safely {
    if (Confirm-Action ('The full check reads every file from {0} again and compares it byte for byte. It takes about as long as the copy did. Start it?' -f (Get-SourceWord))) {
        Start-Check -Names $app.CheckFolders -Full $true
    }
} })
$ui.FixButton.Add_Click({ Invoke-Safely {
    $names = [string[]] @($app.CheckRows | Where-Object { $_.StatusColor -ne $GREEN } | ForEach-Object { $_.Name })
    Start-Copy -Names $names
} })
$ui.CheckBackButton.Add_Click({ Invoke-Safely { if (-not $app.CheckRunning) { Show-Page 'Analyze'; Update-Recommendation } } })
$ui.GoDeleteButton.Add_Click({ Invoke-Safely { Show-DeletePage } })
$ui.DeleteBackButton.Add_Click({ Invoke-Safely { Show-Page 'Check' } })
$ui.DeleteConfirmCheck.Add_Click({ Invoke-Safely { Update-DeleteSelection } })
$ui.DeleteButton.Add_Click({ Invoke-Safely { Start-Delete } })
$ui.FinishButton.Add_Click({ Invoke-Safely {
    Show-Page 'Analyze'
    foreach ($r in $app.Rows) { $r.Selected = $false }
    if ($app.SourceKind -eq 'Device') { Start-Analysis -Kind 'Device' } else { Start-Analysis -Kind 'Folder' -Path $SourceFolder }
} })
$ui.OpenLogButton.Add_Click({ Invoke-Safely { Open-Path $LogPath } })

$ShortcutPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'iPhone Transfer.lnk'
if (Test-Path -LiteralPath $ShortcutPath) { $ui.ShortcutButton.Visibility = 'Collapsed' }
$ui.ShortcutButton.Add_Click({ Invoke-Safely {
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut($ShortcutPath)
    $link.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $link.Arguments = '-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f (Join-Path $PSScriptRoot 'iPhoneTransfer.ps1')
    $link.WorkingDirectory = $PSScriptRoot
    $link.IconLocation = $IconPath + ',0'
    $link.Description = 'Copy photos and videos off an iPhone, check every file, then free up space'
    $link.WindowStyle = 7
    $link.Save()
    $ui.ShortcutButton.Visibility = 'Collapsed'
    Show-Message 'An "iPhone Transfer" icon is now on your desktop. Double-click it next time.'
} })
$ui.RescanButton.Add_Click({ Invoke-Safely {
    if ($sync.Busy) { Show-Message 'Please wait until the current step has finished.'; return }
    foreach ($r in $app.Rows) { $r.Selected = $false }
    if ($app.SourceKind -eq 'Device') { Start-Analysis -Kind 'Device' } else { Start-Analysis -Kind 'Folder' -Path $SourceFolder }
} })

$window.Add_Closing({
    param($sender, $e)
    if ($app.ForceClose) { return }
    $busyWith = ''
    if ($app.CopyRunning) { $busyWith = 'A copy is running.' }
    elseif ($app.CheckRunning) { $busyWith = 'The check is running.' }
    elseif ($app.DeleteRunning) { $busyWith = 'Files are being deleted from the iPhone.' }
    if ($busyWith) {
        if (-not (Confirm-Action "$busyWith Stop it and close?`r`n`r`nEverything finished so far is kept; you can continue next time.")) { $e.Cancel = $true; return }
    }
    $sync.Cancel = $true
})

# ---------------------------------------------------------------------------
# testing aid: walk through the steps by itself and take screenshots
# ---------------------------------------------------------------------------

$auto = @{ Stage = 'start'; Shots = @{}; Since = [DateTime]::UtcNow; Log = New-Object System.Collections.ArrayList }

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
        $stream = [System.IO.File]::Create((Join-Path $ScreenshotDir "$Name.png"))
        $encoder.Save($stream); $stream.Close()
        # Where every named control is, so a tutorial can point at it.
        $bounds = @{}
        foreach ($key in $ui.Keys) {
            $element = $ui[$key]
            if ($element -isnot [System.Windows.FrameworkElement]) { continue }
            $entry = @{}
            if ($element -is [System.Windows.Controls.TextBlock]) { $entry.Text = $element.Text }
            elseif ($element -is [System.Windows.Controls.ContentControl] -and $element.Content -is [string]) { $entry.Text = $element.Content }
            if ($element.IsVisible -and $element.ActualWidth -gt 0) {
                try {
                    $r = $element.TransformToAncestor($content).TransformBounds((New-Object System.Windows.Rect 0, 0, $element.ActualWidth, $element.ActualHeight))
                    $entry.X = [math]::Round($r.X, 1); $entry.Y = [math]::Round($r.Y, 1); $entry.W = [math]::Round($r.Width, 1); $entry.H = [math]::Round($r.Height, 1)
                }
                catch { }
            }
            if ($entry.Count -gt 0) { $bounds[$key] = $entry }
        }
        [System.IO.File]::WriteAllText((Join-Path $ScreenshotDir "$Name.json"), ($bounds | ConvertTo-Json -Depth 3), (New-Object System.Text.UTF8Encoding($false)))
    }
    catch { Write-UiLog "screenshot failed: $($_.Exception.Message)" }
}

$tut = @{ Stage = 'start'; Since = [DateTime]::UtcNow; Done = @{} }

function Step-Tutorial {
    # Walks the demo through every step, pressing the same buttons a person would, and saves a
    # screenshot (plus where each control is) at each moment the tutorial video explains.
    $elapsed = ([DateTime]::UtcNow - $tut.Since).TotalSeconds
    $go = { param($s) $tut.Stage = $s; $tut.Since = [DateTime]::UtcNow; Write-UiLog "tutorial -> $s" }
    $p = $sync.Progress
    switch ($tut.Stage) {
        'start' {
            if ($elapsed -lt 2) { return }
            Save-Screenshot '01-connect-looking'
            Invoke-EngineEvent @{ Type = 'DeviceState'; State = 'Locked'; Device = 'Apple iPhone' }
            & $go 'locked'
        }
        'locked' {
            if ($elapsed -lt 0.6) { return }
            Save-Screenshot '02-connect-locked'
            $names = [string[]] @(Get-ChildItem -LiteralPath $DemoPhone -Directory | ForEach-Object { $_.Name } | Sort-Object)
            Invoke-EngineEvent @{ Type = 'DeviceState'; State = 'Ready'; Device = 'Apple iPhone'; Storage = 'Internal Storage'; Capacity = [int64] 128GB; Folders = $names }
            & $go 'ready'
        }
        'ready' {
            if ($elapsed -lt 0.6) { return }
            Save-Screenshot '03-connect-ready'
            Invoke-Click $ui.ConnectContinue
            & $go 'scanning'
        }
        'scanning' {
            if ($app.Scanning -and [int] $p.ScanIndex -ge 3 -and -not $tut.Done['scan']) { $tut.Done['scan'] = $true; Save-Screenshot '04-scanning' }
            if ($app.ScanDone -and -not $sync.Busy -and $elapsed -gt 1) { Save-Screenshot '05-choose-destination'; & $go 'dest' }
        }
        'dest' {
            if (-not $tut.Done['dest']) { $tut.Done['dest'] = $true; Set-Destination $Destination; return }
            if ($app.AutoSelected -and -not $sync.Busy -and $elapsed -gt 1.5) {
                Update-Selection
                Save-Screenshot '06-recommended'
                Invoke-Click $ui.CompareButton
                & $go 'compare'
            }
        }
        'compare' {
            if ($app.CompareResult -and -not $sync.Busy -and $elapsed -gt 0.5) { Invoke-Click $ui.StartCopyButton; & $go 'copy' }
        }
        'copy' {
            $done = [double] $p.BytesDone + [double] $p.CurrentBytes
            if ($app.CopyRunning -and [double] $p.BytesTotal -gt 0 -and $done -gt 0.25 * [double] $p.BytesTotal -and [double] $p.Speed -gt 0 -and -not $tut.Done['c1']) {
                $tut.Done['c1'] = $true; Save-Screenshot '07-copying'
                # What the screen looks like while the app waits for an unplugged iPhone.
                Invoke-EngineEvent @{ Type = 'Waiting'; On = $true }
                $ui.CopyRate.Text = 'Waiting for the iPhone...'
                Save-Screenshot '08-disconnected'
                Invoke-EngineEvent @{ Type = 'Waiting'; On = $false }
                $tut.Done['c2'] = $true
                return
            }
            if ($app.Page -eq 'Check') { & $go 'check' }
        }
        'check' {
            if ($app.CheckRunning -and -not $tut.Done['k1'] -and [double] $p.BytesDone -gt 0) { $tut.Done['k1'] = $true; Save-Screenshot '09-checking' }
            if ($app.CheckDone -and -not $app.CheckRunning -and $elapsed -gt 1) { Save-Screenshot '10-checked'; Invoke-Click $ui.GoDeleteButton; & $go 'delete' }
        }
        'delete' {
            if ($elapsed -lt 1) { return }
            Save-Screenshot '11-free-up'
            foreach ($r in $app.DeleteRows) { $r.Selected = $true }
            $ui.DeleteConfirmCheck.IsChecked = $true
            Update-DeleteSelection
            Save-Screenshot '12-free-up-ready'
            Invoke-Click $ui.DeleteButton
            & $go 'deleting'
        }
        'deleting' {
            if ($app.DeleteDone -and $elapsed -gt 1) { Save-Screenshot '13-done'; & $go 'finish' }
        }
        'finish' {
            $tut.Stage = 'closing'
            $app.ForceClose = $true
            $window.Close()
        }
    }
}

function Invoke-Click {
    param($Button)
    $Button.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
}

function Step-AutoPilot {
    $elapsed = ([DateTime]::UtcNow - $auto.Since).TotalSeconds
    $next = { param($s) $auto.Stage = $s; $auto.Since = [DateTime]::UtcNow; [void] $auto.Log.Add("$([DateTime]::Now.ToString('HH:mm:ss')) -> $s") }
    switch ($auto.Stage) {
        'start' {
            if ($elapsed -lt 1.5) { return }
            Save-Screenshot '1-connect'
            if ($SourceFolder) { Start-Analysis -Kind 'Folder' -Path $SourceFolder; & $next 'scan' }
            else { & $next 'connect' }
        }
        'connect' {
            if ($ui.ConnectContinue.IsEnabled -and $elapsed -gt 1) { Save-Screenshot '1-connect-ready'; Invoke-Click $ui.ConnectContinue; & $next 'scan' }
            elseif ($elapsed -gt 120) { & $next 'finish' }
        }
        'scan' {
            if ($app.Page -eq 'Analyze' -and $app.Scanning -and -not $auto.Shots['scanning'] -and $elapsed -gt 1) { Save-Screenshot '2-scanning'; $auto.Shots['scanning'] = $true }
            if ($app.ScanDone -and $elapsed -gt 2 -and -not $sync.Busy) {
                if ($AutoFolders.Count -gt 0) { foreach ($r in $app.Rows) { $r.Selected = ($r.CanSelect -and ($AutoFolders -contains $r.Name)) } }
                Update-Selection
                Save-Screenshot '2-analyze'
                if ($AutoStopAfter -eq 'Analyze') { & $next 'finish'; return }
                if (@($app.Rows | Where-Object { $_.Selected }).Count -eq 0) { [void] $auto.Log.Add('nothing selected'); & $next 'finish'; return }
                if ($AutoCompare -and -not $auto.Shots['compared']) { $auto.Shots['compared'] = $true; Invoke-Click $ui.CompareButton; & $next 'compare'; return }
                Invoke-Click $ui.StartCopyButton
                & $next 'copy'
            }
        }
        'compare' {
            if ($app.CompareResult -and -not $sync.Busy -and $elapsed -gt 1) {
                Save-Screenshot '2-compared'
                if ($AutoStopAfter -eq 'Analyze') { & $next 'finish'; return }
                Invoke-Click $ui.StartCopyButton
                & $next 'copy'
            }
        }
        'copy' {
            if ($app.CopyRunning -and -not $auto.Shots['copying'] -and [double] $sync.Progress.BytesDone -gt 0) { Save-Screenshot '3-copying'; $auto.Shots['copying'] = $true }
            if ($AutoTrouble -and $app.CopyRunning -and $auto.Shots['copying'] -and -not $auto.Shots['trouble']) {
                $auto.Shots['trouble'] = $true
                Invoke-EngineEvent @{ Type = 'Trouble'; On = $true }; Save-Screenshot '3-trouble'; Invoke-EngineEvent @{ Type = 'Trouble'; On = $false }
            }
            # Testing stop / continue: press Stop part-way through, then Continue.
            if ($AutoInterrupt -and -not $auto.Shots['interrupted'] -and $app.CopyRunning -and [double] $sync.Progress.BytesTotal -gt 0 -and
                ([double] $sync.Progress.BytesDone + [double] $sync.Progress.CurrentBytes) -gt 0.3 * [double] $sync.Progress.BytesTotal) {
                $auto.Shots['interrupted'] = $true
                [void] $auto.Log.Add("pressing Stop at $([int64] $sync.Progress.BytesDone + [int64] $sync.Progress.CurrentBytes) of $([int64] $sync.Progress.BytesTotal) bytes")
                Invoke-Click $ui.StopButton
                & $next 'stopped'
                return
            }
            if ($app.CopyDone) {
                if ($AutoStopAfter -eq 'Copy') { Save-Screenshot '3-copied'; & $next 'finish'; return }
                & $next 'check'
            }
        }
        'stopped' {
            if ($app.CopyDone -and $elapsed -gt 1) {
                Save-Screenshot '3-stopped'
                [void] $auto.Log.Add("stopped: copied=$($app.CopyDone.Copied) cancelled=$($app.CopyDone.Cancelled); pressing Continue")
                Invoke-Click $ui.CopyRetryButton
                & $next 'copy'
            }
        }
        'check' {
            if ($app.CheckRunning -and -not $auto.Shots['checking'] -and $elapsed -gt 0.5) { Save-Screenshot '4-checking'; $auto.Shots['checking'] = $true }
            if ($app.CheckDone -and -not $app.CheckRunning -and $elapsed -gt 1) {
                Save-Screenshot '4-checked'
                if ($AutoFullCheck -and -not $auto.Shots['full']) { $auto.Shots['full'] = $true; Invoke-Click $ui.FullCheckButton; & $next 'check'; return }
                if ($AutoStopAfter -eq 'Check') { & $next 'finish'; return }
                if (-not $ui.GoDeleteButton.IsEnabled) { & $next 'finish'; return }
                Invoke-Click $ui.GoDeleteButton
                & $next 'delete'
            }
        }
        'delete' {
            if ($elapsed -lt 1) { return }
            Save-Screenshot '5-delete'
            foreach ($r in $app.DeleteRows) { $r.Selected = $true }
            $ui.DeleteConfirmCheck.IsChecked = $true
            Update-DeleteSelection
            Save-Screenshot '5-delete-ready'
            Invoke-Click $ui.DeleteButton
            & $next 'deleting'
        }
        'deleting' {
            if ($app.DeleteDone -and $elapsed -gt 1) { Save-Screenshot '5-deleted'; & $next 'finish' }
        }
        'finish' {
            if ($ScreenshotDir) {
                $result = @{
                    Stages = @($auto.Log)
                    Copy = $app.CopyDone; Check = $app.CheckDone; Delete = $app.DeleteDone; Compare = $app.CompareResult
                    Rows = @($app.Rows | ForEach-Object { @{ Name = $_.Name; Selected = $_.Selected; Status = $_.Status; Note = $_.Note; Recommended = $_.Recommended } })
                    CheckRows = @($app.CheckRows | ForEach-Object { @{ Name = $_.Name; Phone = $_.Phone; Laptop = $_.Laptop; Status = $_.Status } })
                    DeleteRows = @($app.DeleteRows | ForEach-Object { @{ Name = $_.Name; Status = $_.Status } })
                }
                [System.IO.File]::WriteAllText((Join-Path $ScreenshotDir 'result.json'), ($result | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
            }
            $auto.Stage = 'closing'
            $app.ForceClose = $true
            $window.Close()
        }
    }
}

# ---------------------------------------------------------------------------
# the heartbeat: drain engine events, refresh live numbers
# ---------------------------------------------------------------------------

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(200)
$timer.Add_Tick({
    try {
        $e = $null
        $count = 0
        while ($count -lt 200 -and $sync.Events.TryDequeue([ref] $e)) {
            $count++
            try { Invoke-EngineEvent $e }
            catch { Write-UiLog ("event {0} failed: {1} {2}" -f $e.Type, $_.Exception.Message, $_.ScriptStackTrace) }
        }
        switch ($app.Page) {
            'Analyze' { Update-ScanStatus; Update-FreeSpace; Update-Selection }
            'Copy'    { Update-CopyLive }
            'Check'   { Update-CheckLive }
            'Delete'  { Update-DeleteLive; Update-DeleteSelection }
        }
        if ($Tutorial) { Step-Tutorial }
        elseif ($AutoPilot) { Step-AutoPilot }
    }
    catch { Write-UiLog ("tick failed: {0} {1}" -f $_.Exception.Message, $_.ScriptStackTrace) }
})

# ---------------------------------------------------------------------------
# start
# ---------------------------------------------------------------------------

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$runspace = [runspacefactory]::CreateRunspace()
$runspace.ApartmentState = 'STA'
$runspace.ThreadOptions = 'ReuseThread'
$runspace.Open()
$runspace.SessionStateProxy.SetVariable('sync', $sync)
$worker = [powershell]::Create()
$worker.Runspace = $runspace
[void] $worker.AddScript([System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Engine.ps1')) + "`r`nStart-Engine")
$handle = $worker.BeginInvoke()

Show-Page 'Connect'
if ($DemoPhone) { $sync.Watch = $false; $sync.DemoMode = $true; $sync.DemoScanDelayMs = 12 }
if ($SourceFolder) {
    $ui.ConnectTitle.Text = 'Using a folder on this PC'
    $ui.ConnectDetail.Text = $SourceFolder
}
$app.Dest = ''
$timer.Start()
Write-UiLog ("app started (source folder: '{0}', autopilot: {1})" -f $SourceFolder, [bool] $AutoPilot)
[void] $window.ShowDialog()

# ---------------------------------------------------------------------------
# shut down: let the engine finish cleanly (it removes any half-written file)
# ---------------------------------------------------------------------------

$timer.Stop()
$sync.Cancel = $true
$sync.Quit = $true
[void] $handle.AsyncWaitHandle.WaitOne(15000)
try { $worker.Dispose(); $runspace.Dispose() } catch { }
