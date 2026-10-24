<#
.SYNOPSIS
    Smart Transfer - copies photos, videos and files off an iPhone, an Android phone or any
    folder or drive, checks every file, and only then offers to remove the originals.

.DESCRIPTION
    Works like a kiosk: one question per screen, big choices, Back always bottom left and
    the next step always bottom right. The sidebar shows every answer given so far; click one
    to go back and change it.

      From        iPhone, Android phone, or a folder / drive  (then: connect, or pick the folder)
      Save to     a drive or a folder on this PC
      What        everything new (recommended) or your own choice of folders
      Originals   keep them, or remove them once every copy is proven
      Start       a summary of the answers, each one changeable
      Copy+check  live progress; every file is checked as soon as the copy is done
      Done        the result, and removing the originals if that was asked for

    Start it by double-clicking "Smart Transfer.cmd" next to this folder.

.PARAMETER SourceFolder
    Start with this folder as the source (a folder or drive on this PC).

.PARAMETER Destination
    Start with this destination instead of the last one used.

.PARAMETER AutoPilot
    Testing aid: answer every question by itself and walk through the steps, saving a
    screenshot of each screen to -ScreenshotDir. -AutoStopAfter says where to stop; removing
    the originals automatically is only ever allowed for a folder (-SourceFolder or -DemoPhone).

.PARAMETER DemoPhone
    Testing aid: a folder of month folders plays the part of an iPhone. No phone needed.
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
    [switch] $AutoTrouble,
    [switch] $AutoTour,
    [string] $ScreenshotDir = '',
    [string] $DemoPhone = '',
    [switch] $Tutorial
)

$ErrorActionPreference = 'Stop'
$AutoFolders = @($AutoFolders | ForEach-Object { $_ -split ',' } | Where-Object { $_ })

# The app is started without a console window, so a problem at start-up would otherwise
# vanish without a word. Say what happened instead.
Add-Type -AssemblyName PresentationFramework
trap {
    $message = $_.Exception.Message
    try {
        $dir = Join-Path $env:LOCALAPPDATA 'SmartTransfer\logs'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Add-Content -LiteralPath (Join-Path $dir 'startup-errors.log') -Value ('{0}  {1}  {2}' -f (Get-Date), $message, $_.ScriptStackTrace)
    }
    catch { }
    if (-not $AutoPilot) { [void] [System.Windows.MessageBox]::Show("Smart Transfer stopped because of a problem:`r`n`r`n$message", 'Smart Transfer', 'OK', 'Error') }
    break
}

if ($Tutorial) { throw 'The tutorial recording (tools\make-tutorial.ps1) has not been updated for the step-by-step screens yet.' }
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    throw 'Please start Smart Transfer with "Smart Transfer.cmd" (it needs powershell -STA).'
}
if ($AutoPilot -and $AutoStopAfter -eq 'Delete' -and -not $SourceFolder -and -not $DemoPhone) {
    throw 'Automatic removing is only allowed with -SourceFolder or -DemoPhone - never on a real phone.'
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
if (-not ('IPhoneTransferApp.Native' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'Native.cs') }
$AppTitle = 'Smart Transfer'
. (Join-Path $PSScriptRoot 'Common.ps1')

$Invariant = [System.Globalization.CultureInfo]::InvariantCulture
$DOT = ' ' + [char] 0x00B7 + ' '
$CHECK = [string] [char] 0x2713
$RESERVE = 2GB          # keep this much free on the PC when recommending
$DEFAULT_SPEED = @{ iPhone = [double] 20MB; Android = [double] 20MB; Folder = [double] 80MB }   # bytes per second, until measured

# ---------------------------------------------------------------------------
# settings and logs
# ---------------------------------------------------------------------------

$SettingsDir        = Join-Path $env:APPDATA 'SmartTransfer'
$SettingsPath       = Join-Path $SettingsDir 'settings.json'
$LegacySettingsPath = Join-Path $env:APPDATA 'iPhoneTransfer\settings.json'   # the iPhone-only app before it
$LogDir             = Join-Path $env:LOCALAPPDATA 'SmartTransfer\logs'
$LogPath            = Join-Path $LogDir ('app-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

function Get-Settings {
    # Where each kind of source was last saved to, and how fast it copied.
    $s = @{ Dest = @{}; Speed = @{} }
    foreach ($path in @($LegacySettingsPath, $SettingsPath)) {
        try {
            if (-not (Test-Path -LiteralPath $path)) { continue }
            $j = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            if ($j.LastDestination) { $s.Dest['iPhone'] = [string] $j.LastDestination }
            if ($j.Speed -gt 1MB) { $s.Speed['iPhone'] = [double] $j.Speed }
            foreach ($k in 'iPhone', 'Android', 'Folder') {
                if ($j.Destinations -and $j.Destinations.$k) { $s.Dest[$k] = [string] $j.Destinations.$k }
                if ($j.Speeds -and $j.Speeds.$k -gt 1MB) { $s.Speed[$k] = [double] $j.Speeds.$k }
            }
        }
        catch { }
    }
    return $s
}

function Save-Settings {
    if ($AutoPilot) { return }   # test runs must not change what a real user sees next time
    try {
        New-Item -ItemType Directory -Force -Path $SettingsDir | Out-Null
        $data = @{ Destinations = $settings.Dest; Speeds = $settings.Speed }
        [System.IO.File]::WriteAllText($SettingsPath, ($data | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
    }
    catch { }
}

# ---------------------------------------------------------------------------
# the window
# ---------------------------------------------------------------------------

$xamlText = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Smart Transfer" Width="1180" Height="800" MinWidth="980" MinHeight="680"
        WindowStartupLocation="CenterScreen" FontFamily="Segoe UI" FontSize="14"
        Foreground="#0F172A" Background="#F1F5F9" UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
  <Window.Resources>
__KIOSK_STYLES__
  </Window.Resources>

  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="264"/>
      <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>

    <!-- sidebar: the answers so far -->
    <Border Grid.Column="0" Background="#0F172A">
      <DockPanel Margin="18,26,16,20">
        <StackPanel DockPanel.Dock="Top">
          <StackPanel Orientation="Horizontal" Margin="6,0,0,0">
            <Border Width="40" Height="40" CornerRadius="11" Background="#1D4ED8">
              <TextBlock Style="{StaticResource Icon}" Text="&#xE895;" FontSize="20" Foreground="White" HorizontalAlignment="Center"/>
            </Border>
            <StackPanel Margin="12,0,0,0" VerticalAlignment="Center">
              <TextBlock Text="Smart Transfer" FontSize="18" FontWeight="SemiBold" Foreground="White"/>
              <TextBlock Text="Copy, check, then free up" FontSize="12" Foreground="#94A3B8"/>
            </StackPanel>
          </StackPanel>
          <TextBlock Text="YOUR CHOICES" Foreground="#64748B" FontSize="11" FontWeight="Bold" Margin="16,34,0,8"/>
          <StackPanel x:Name="StageList"/>
        </StackPanel>
        <StackPanel DockPanel.Dock="Bottom" VerticalAlignment="Bottom" Margin="6,0,0,0">
          <Border Background="#1E293B" CornerRadius="10" Padding="14,12" Margin="0,0,0,14">
            <StackPanel>
              <StackPanel Orientation="Horizontal">
                <TextBlock Style="{StaticResource Icon}" Text="&#xEA18;" Foreground="#4ADE80" FontSize="14"/>
                <TextBlock Text="Your files stay with you" Foreground="White" FontSize="12" FontWeight="SemiBold" Margin="8,0,0,0"/>
              </StackPanel>
              <TextBlock Text="Nothing is uploaded. Nothing is removed unless you ask, and only after every file has been checked."
                         Foreground="#94A3B8" FontSize="11" TextWrapping="Wrap" Margin="0,6,0,0"/>
            </StackPanel>
          </Border>
          <Border x:Name="UpdateNotice" Visibility="Collapsed" Background="#78350F" CornerRadius="10" Padding="12,10" Margin="0,0,0,12">
            <TextBlock Text="A newer version of Smart Transfer was installed. Close this window and open the app again to use it." Foreground="#FEF3C7" FontSize="12" TextWrapping="Wrap"/>
          </Border>
          <Button x:Name="ShortcutButton" Content="Add a desktop shortcut" Style="{StaticResource SideLink}" HorizontalAlignment="Left" Margin="0,0,0,8"/>
          <Button x:Name="OpenLogButton" Content="Open the activity log" Style="{StaticResource SideLink}" HorizontalAlignment="Left"/>
        </StackPanel>
      </DockPanel>
    </Border>

    <Grid Grid.Column="1">
      <Grid.RowDefinitions>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <Grid Margin="56,40,56,20">

        <!-- from: what kind of source -->
        <Grid x:Name="PageSource" MaxWidth="920">
          <StackPanel>
            <TextBlock Text="What do you want to copy from?" Style="{StaticResource H1}"/>
            <TextBlock Text="Choose one. You can come back and change any answer later." Style="{StaticResource Sub}"/>
            <UniformGrid x:Name="SourceTiles" Columns="3" Margin="-8,30,-8,0"/>
          </StackPanel>
        </Grid>

        <!-- from: connect the phone, or pick the folder -->
        <ScrollViewer x:Name="PageConnect" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
          <StackPanel MaxWidth="920">
            <TextBlock x:Name="ConnectHeading" Style="{StaticResource H1}"/>
            <TextBlock x:Name="ConnectSubText" Style="{StaticResource Sub}"/>
            <StackPanel x:Name="PhonePanel" Margin="0,28,0,0">
              <Border x:Name="ConnectStatusCard" Style="{StaticResource Card}" Padding="24,20">
                <StackPanel>
                  <Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Border x:Name="ConnectIconBack" Width="60" Height="60" CornerRadius="30" Background="#F1F5F9">
                      <TextBlock x:Name="ConnectIcon" Style="{StaticResource Icon}" Text="&#xE8EA;" FontSize="26" Foreground="#64748B" HorizontalAlignment="Center"/>
                    </Border>
                    <StackPanel Grid.Column="1" Margin="18,0,0,0" VerticalAlignment="Center">
                      <TextBlock x:Name="ConnectTitle" FontSize="19" FontWeight="SemiBold" TextWrapping="Wrap"/>
                      <TextBlock x:Name="ConnectDetail" FontSize="14" Foreground="#64748B" TextWrapping="Wrap" Margin="0,4,0,0"/>
                      <ProgressBar x:Name="ConnectBar" Style="{x:Null}" IsIndeterminate="True" Height="4" Margin="0,12,0,0" Width="320" HorizontalAlignment="Left" Foreground="#2563EB" Background="#E2E8F0" BorderThickness="0"/>
                    </StackPanel>
                  </Grid>
                  <StackPanel x:Name="StorageArea" Visibility="Collapsed" Margin="0,20,0,0">
                    <TextBlock Text="This phone has more than one storage. Which one?" Style="{StaticResource Label}" FontSize="13"/>
                    <UniformGrid x:Name="StoragePanel" Columns="2" Margin="-8,6,-8,0"/>
                  </StackPanel>
                </StackPanel>
              </Border>
              <StackPanel x:Name="ConnectSteps" Margin="0,26,0,0"/>
              <Expander x:Name="ConnectHelp" Margin="0,14,0,0" FontSize="14" Foreground="#334155">
                <TextBlock x:Name="ConnectHelpText" TextWrapping="Wrap" Foreground="#475569" LineHeight="22" Margin="24,8,0,0"/>
              </Expander>
            </StackPanel>
            <StackPanel x:Name="FolderPanel" Margin="0,28,0,0">
              <StackPanel x:Name="FolderTiles"/>
            </StackPanel>
          </StackPanel>
        </ScrollViewer>

        <!-- save to -->
        <ScrollViewer x:Name="PageDest" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
          <StackPanel MaxWidth="920">
            <TextBlock Text="Where should the files go?" Style="{StaticResource H1}"/>
            <TextBlock x:Name="DestSubText" Style="{StaticResource Sub}"/>
            <StackPanel x:Name="DestTiles" Margin="0,28,0,0"/>
          </StackPanel>
        </ScrollViewer>

        <!-- what -->
        <Grid x:Name="PageChoose" MaxWidth="920" Visibility="Collapsed">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <StackPanel Grid.Row="0">
            <TextBlock x:Name="ChooseHeading" Style="{StaticResource H1}"/>
            <TextBlock x:Name="ChooseSubText" Style="{StaticResource Sub}"/>
          </StackPanel>
          <Border x:Name="ScanCard" Grid.Row="1" Style="{StaticResource Card}" Margin="0,24,0,0" Padding="22,18">
            <StackPanel>
              <DockPanel>
                <TextBlock x:Name="ScanPercent" DockPanel.Dock="Right" FontSize="20" FontWeight="SemiBold" Foreground="#1D4ED8" VerticalAlignment="Center"/>
                <StackPanel>
                  <TextBlock x:Name="ScanTitle" FontSize="16" FontWeight="SemiBold"/>
                  <TextBlock x:Name="ScanDetail" Foreground="#64748B" FontSize="13" Margin="0,3,0,0" TextTrimming="CharacterEllipsis"/>
                </StackPanel>
              </DockPanel>
              <ProgressBar x:Name="ScanBar" Height="8" Margin="0,12,0,0" Maximum="100"/>
            </StackPanel>
          </Border>
          <ScrollViewer x:Name="ChoiceView" Grid.Row="2" Margin="0,20,0,0" VerticalScrollBarVisibility="Auto">
            <StackPanel>
              <StackPanel x:Name="ChoiceTiles"/>
              <TextBlock x:Name="ConvertTip" Visibility="Collapsed" Foreground="#92400E" FontSize="13" TextWrapping="Wrap" Margin="4,6,4,0"
                         Text="Your iPhone sends converted copies (JPG photos, H.264 videos) instead of its originals: larger than what the iPhone stores, and re-encoded. For the untouched originals, on the iPhone open Settings &gt; Apps &gt; Photos &gt; Transfer to Mac or PC and choose Keep Originals, then go back one step and connect again."/>
            </StackPanel>
          </ScrollViewer>
          <Border x:Name="ListView" Grid.Row="2" Style="{StaticResource Card}" Margin="0,20,0,0" Padding="0" Visibility="Collapsed">
            <Grid>
              <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
              <DockPanel Margin="18,14,18,8">
                <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                  <Button x:Name="SelectAllButton" Content="Select all" Style="{StaticResource Link}" Margin="0,0,18,0"/>
                  <Button x:Name="SelectNoneButton" Content="Clear" Style="{StaticResource Link}" Margin="0,0,18,0"/>
                  <Button x:Name="CompareButton" Content="See every file" Style="{StaticResource Link}" ToolTip="A report of every file in the ticked folders and where it is on this PC - nothing is copied"/>
                </StackPanel>
                <TextBlock Text="Tick the folders to copy" FontWeight="SemiBold" FontSize="15" VerticalAlignment="Center"/>
              </DockPanel>
              <DataGrid x:Name="FolderGrid" Grid.Row="1" Margin="4,0,4,4">
                <DataGrid.Columns>
                  <DataGridTemplateColumn Header="" Width="48">
                    <DataGridTemplateColumn.CellTemplate>
                      <DataTemplate>
                        <CheckBox IsChecked="{Binding Selected, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" IsEnabled="{Binding CanSelect}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                      </DataTemplate>
                    </DataGridTemplateColumn.CellTemplate>
                  </DataGridTemplateColumn>
                  <DataGridTemplateColumn Header="Folder" Width="2*">
                    <DataGridTemplateColumn.CellTemplate>
                      <DataTemplate>
                        <StackPanel VerticalAlignment="Center" Margin="0,5">
                          <TextBlock Text="{Binding Name}" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
                          <TextBlock Text="{Binding Dates}" Foreground="#64748B" FontSize="12"/>
                        </StackPanel>
                      </DataTemplate>
                    </DataGridTemplateColumn.CellTemplate>
                  </DataGridTemplateColumn>
                  <DataGridTextColumn Header="Size" Binding="{Binding Size}" Width="90"/>
                  <DataGridTextColumn Header="New files" Binding="{Binding Files}" Width="90"/>
                  <DataGridTemplateColumn Header="On this PC" Width="2*">
                    <DataGridTemplateColumn.CellTemplate>
                      <DataTemplate><TextBlock Text="{Binding Status}" Foreground="{Binding StatusColor}" FontWeight="SemiBold" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/></DataTemplate>
                    </DataGridTemplateColumn.CellTemplate>
                  </DataGridTemplateColumn>
                </DataGrid.Columns>
              </DataGrid>
            </Grid>
          </Border>
          <Border x:Name="SpaceCard" Grid.Row="3" Margin="0,16,0,0" Visibility="Collapsed">
            <StackPanel>
              <Grid Height="10">
                <Border CornerRadius="5" Background="#E2E8F0"/>
                <Grid ClipToBounds="True">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition x:Name="SpaceUsed" Width="1*"/>
                    <ColumnDefinition x:Name="SpaceNeed" Width="0*"/>
                    <ColumnDefinition x:Name="SpaceFree" Width="1*"/>
                  </Grid.ColumnDefinitions>
                  <Border Grid.Column="0" Background="#94A3B8" CornerRadius="5,0,0,5"/>
                  <Border x:Name="SpaceNeedFill" Grid.Column="1" Background="#2563EB"/>
                </Grid>
              </Grid>
              <TextBlock x:Name="SpaceText" Margin="0,8,0,0" FontSize="13" Foreground="#475569" TextWrapping="Wrap"/>
            </StackPanel>
          </Border>
        </Grid>

        <!-- originals -->
        <Grid x:Name="PageAfter" MaxWidth="920" Visibility="Collapsed">
          <StackPanel>
            <TextBlock x:Name="AfterHeading" Style="{StaticResource H1}"/>
            <TextBlock Text="Nothing is removed until every copy has been checked - and you confirm first." Style="{StaticResource Sub}"/>
            <UniformGrid x:Name="AfterTiles" Columns="2" Margin="-8,30,-8,0"/>
          </StackPanel>
        </Grid>

        <!-- start: the answers once more -->
        <ScrollViewer x:Name="PageReview" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
          <StackPanel MaxWidth="920">
            <TextBlock Text="Ready to start" Style="{StaticResource H1}"/>
            <TextBlock Text="Here are your choices. Press Change next to any of them to go back." Style="{StaticResource Sub}"/>
            <Border Style="{StaticResource Card}" Padding="0" Margin="0,26,0,0">
              <StackPanel x:Name="ReviewRows"/>
            </Border>
            <Border x:Name="ReviewNoteCard" Margin="0,16,0,0" Background="#EFF6FF" BorderBrush="#BFDBFE" BorderThickness="1" CornerRadius="12" Padding="18,14">
              <DockPanel>
                <TextBlock x:Name="ReviewNoteIcon" DockPanel.Dock="Left" Style="{StaticResource Icon}" Text="&#xE916;" FontSize="18" Foreground="#2563EB" VerticalAlignment="Top" Margin="0,1,12,0"/>
                <TextBlock x:Name="ReviewNote" Foreground="#1E3A8A" FontSize="14" TextWrapping="Wrap"/>
              </DockPanel>
            </Border>
          </StackPanel>
        </ScrollViewer>

        <!-- copy and check -->
        <ScrollViewer x:Name="PageWork" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
          <StackPanel MaxWidth="920">
            <TextBlock x:Name="WorkHeading" Style="{StaticResource H1}"/>
            <TextBlock x:Name="WorkSubText" Style="{StaticResource Sub}"/>
            <Border x:Name="WaitingBanner" Visibility="Collapsed" Margin="0,20,0,0" Background="#FEF3C7" BorderBrush="#FCD34D" BorderThickness="1" CornerRadius="12" Padding="18,14">
              <DockPanel>
                <TextBlock DockPanel.Dock="Left" Style="{StaticResource Icon}" Text="&#xE7BA;" FontSize="22" Foreground="#B45309" VerticalAlignment="Top"/>
                <Button x:Name="TryAgainButton" DockPanel.Dock="Right" Content="Try again now" Style="{StaticResource Secondary}" Padding="14,7" Visibility="Collapsed" VerticalAlignment="Center" Margin="12,0,0,0"/>
                <StackPanel Margin="14,0,0,0">
                  <TextBlock x:Name="WaitingTitle" Text="The phone was disconnected" FontWeight="SemiBold" Foreground="#78350F" FontSize="16"/>
                  <TextBlock x:Name="WaitingText" Foreground="#92400E" FontSize="14" TextWrapping="Wrap" Margin="0,3,0,0"/>
                </StackPanel>
              </DockPanel>
            </Border>
            <Border Style="{StaticResource Card}" Margin="0,22,0,0" Padding="30,24">
              <StackPanel>
                <StackPanel Orientation="Horizontal">
                  <Border x:Name="PhaseCopy" CornerRadius="14" Padding="14,5"><TextBlock x:Name="PhaseCopyText" FontWeight="SemiBold" FontSize="13"/></Border>
                  <TextBlock Style="{StaticResource Icon}" Text="&#xE76C;" Foreground="#94A3B8" FontSize="12" Margin="10,0"/>
                  <Border x:Name="PhaseCheck" CornerRadius="14" Padding="14,5"><TextBlock x:Name="PhaseCheckText" FontWeight="SemiBold" FontSize="13"/></Border>
                </StackPanel>
                <Grid Margin="0,18,0,0">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <TextBlock x:Name="WorkPercent" Text="0%" FontSize="56" FontWeight="SemiBold" Foreground="#1D4ED8" VerticalAlignment="Center"/>
                  <StackPanel Grid.Column="1" Margin="24,0,0,0" VerticalAlignment="Center">
                    <TextBlock x:Name="WorkAmounts" FontSize="17" FontWeight="SemiBold" TextWrapping="Wrap"/>
                    <TextBlock x:Name="WorkRate" Foreground="#475569" FontSize="14" Margin="0,4,0,0"/>
                  </StackPanel>
                </Grid>
                <ProgressBar x:Name="WorkBar" Height="16" Margin="0,18,0,0" Maximum="1000"/>
                <TextBlock x:Name="WorkCurrent" Foreground="#64748B" FontSize="13" Margin="0,14,0,0" TextTrimming="CharacterEllipsis"/>
              </StackPanel>
            </Border>
            <WrapPanel x:Name="WorkStats" Margin="0,16,0,0">
              <Border Background="#F0FDF4" CornerRadius="8" Padding="12,6" Margin="0,0,10,0"><TextBlock x:Name="StatCopied" Foreground="#166534" FontWeight="SemiBold" FontSize="13"/></Border>
              <Border Background="#E2E8F0" CornerRadius="8" Padding="12,6" Margin="0,0,10,0"><TextBlock x:Name="StatAlready" Foreground="#334155" FontWeight="SemiBold" FontSize="13"/></Border>
              <Border Background="#FEF2F2" CornerRadius="8" Padding="12,6"><TextBlock x:Name="StatFailed" Foreground="#991B1B" FontWeight="SemiBold" FontSize="13"/></Border>
            </WrapPanel>
          </StackPanel>
        </ScrollViewer>

        <!-- the result of the check -->
        <ScrollViewer x:Name="PageResult" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
          <StackPanel MaxWidth="920">
            <Border x:Name="VerdictIconBack" Width="76" Height="76" CornerRadius="38" HorizontalAlignment="Left">
              <TextBlock x:Name="VerdictIcon" Style="{StaticResource Icon}" FontSize="34" Foreground="White" HorizontalAlignment="Center"/>
            </Border>
            <TextBlock x:Name="ResultHeading" Style="{StaticResource H1}" Margin="0,22,0,0"/>
            <TextBlock x:Name="ResultText" Style="{StaticResource Sub}"/>
            <Border x:Name="ProblemsCard" Style="{StaticResource Card}" Visibility="Collapsed" Margin="0,22,0,0" Padding="18,14">
              <StackPanel>
                <TextBlock Text="Files that need attention" Style="{StaticResource Label}" FontSize="13"/>
                <ListBox x:Name="ProblemsList" MaxHeight="200" BorderThickness="0" FontSize="12" Margin="0,8,0,0"/>
              </StackPanel>
            </Border>
            <WrapPanel Margin="0,24,0,0">
              <Button x:Name="OpenDestButton" Content="Open the folder" Style="{StaticResource Link}" Margin="0,0,26,10"/>
              <Button x:Name="OpenReportButton" Content="Open the full report" Style="{StaticResource Link}" Margin="0,0,26,10"/>
              <Button x:Name="FullCheckButton" Content="Check again, reading every file from the source (slower)" Style="{StaticResource Link}" Margin="0,0,26,10"/>
              <Button x:Name="FreeAnywayButton" Style="{StaticResource Link}" Margin="0,0,26,10" Visibility="Collapsed"/>
            </WrapPanel>
          </StackPanel>
        </ScrollViewer>

        <!-- removing the originals -->
        <ScrollViewer x:Name="PageFree" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
          <StackPanel MaxWidth="920">
            <TextBlock x:Name="FreeHeading" Style="{StaticResource H1}"/>
            <TextBlock x:Name="FreeSubText" Style="{StaticResource Sub}"/>
            <Border Margin="0,22,0,0" Background="#FFF7ED" BorderBrush="#FDBA74" BorderThickness="1" CornerRadius="12" Padding="18,14">
              <DockPanel>
                <TextBlock DockPanel.Dock="Left" Style="{StaticResource Icon}" Text="&#xE7BA;" FontSize="20" Foreground="#C2410C" VerticalAlignment="Top" Margin="0,2,12,0"/>
                <StackPanel>
                  <TextBlock x:Name="FreeWarnTitle" FontWeight="SemiBold" Foreground="#7C2D12" FontSize="15" TextWrapping="Wrap"/>
                  <TextBlock x:Name="FreeWarnText" Foreground="#9A3412" FontSize="14" TextWrapping="Wrap" Margin="0,4,0,0"/>
                </StackPanel>
              </DockPanel>
            </Border>
            <Border Style="{StaticResource Card}" Margin="0,16,0,0" Padding="24,18">
              <StackPanel>
                <TextBlock x:Name="FreeSummary" FontSize="22" FontWeight="SemiBold" TextWrapping="Wrap"/>
                <TextBlock x:Name="FreeSummaryDetail" FontSize="14" Foreground="#64748B" TextWrapping="Wrap" Margin="0,4,0,0"/>
                <Expander x:Name="FreeFoldersExpander" Header="Choose which folders" Margin="0,14,0,0" FontSize="14" Foreground="#334155">
                  <DataGrid x:Name="DeleteGrid" MaxHeight="260" Margin="0,8,0,0">
                    <DataGrid.Columns>
                      <DataGridTemplateColumn Header="" Width="48">
                        <DataGridTemplateColumn.CellTemplate>
                          <DataTemplate>
                            <CheckBox IsChecked="{Binding Selected, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" IsEnabled="{Binding CanSelect}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                          </DataTemplate>
                        </DataGridTemplateColumn.CellTemplate>
                      </DataGridTemplateColumn>
                      <DataGridTextColumn Header="Folder" Binding="{Binding Name}" Width="2*" FontWeight="SemiBold"/>
                      <DataGridTextColumn Header="Files" Binding="{Binding Files}" Width="80"/>
                      <DataGridTextColumn Header="Size" Binding="{Binding Size}" Width="90"/>
                      <DataGridTemplateColumn Header="Status" Width="3*">
                        <DataGridTemplateColumn.CellTemplate>
                          <DataTemplate><TextBlock Text="{Binding Status}" Foreground="{Binding StatusColor}" FontWeight="SemiBold" VerticalAlignment="Center" TextWrapping="Wrap"/></DataTemplate>
                        </DataGridTemplateColumn.CellTemplate>
                      </DataGridTemplateColumn>
                    </DataGrid.Columns>
                  </DataGrid>
                </Expander>
              </StackPanel>
            </Border>
            <Border x:Name="DeleteProgressCard" Style="{StaticResource Card}" Margin="0,16,0,0" Padding="22,14" Visibility="Collapsed">
              <StackPanel>
                <DockPanel>
                  <TextBlock x:Name="DeletePercent" DockPanel.Dock="Right" Text="0%" FontSize="20" FontWeight="SemiBold" Foreground="#B91C1C"/>
                  <StackPanel>
                    <TextBlock x:Name="DeleteStep" FontWeight="SemiBold" TextWrapping="Wrap"/>
                    <TextBlock x:Name="DeleteDetail" Foreground="#64748B" FontSize="13" Margin="0,2,0,0" TextTrimming="CharacterEllipsis"/>
                  </StackPanel>
                </DockPanel>
                <ProgressBar x:Name="DeleteBar" Height="8" Margin="0,10,0,0" Maximum="1000" Foreground="#DC2626"/>
              </StackPanel>
            </Border>
            <CheckBox x:Name="DeleteConfirmCheck" Margin="2,20,0,0" FontSize="15" VerticalContentAlignment="Center">
              <TextBlock x:Name="DeleteConfirmText" TextWrapping="Wrap" Margin="6,0,0,0"/>
            </CheckBox>
          </StackPanel>
        </ScrollViewer>

        <!-- done -->
        <ScrollViewer x:Name="PageDone" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
          <StackPanel MaxWidth="920">
            <Border x:Name="DoneIconBack" Width="76" Height="76" CornerRadius="38" HorizontalAlignment="Left" Background="#16A34A">
              <TextBlock x:Name="DoneIcon" Style="{StaticResource Icon}" Text="&#xE73E;" FontSize="34" Foreground="White" HorizontalAlignment="Center"/>
            </Border>
            <TextBlock x:Name="DoneHeading" Style="{StaticResource H1}" Margin="0,22,0,0"/>
            <TextBlock x:Name="DoneText" Style="{StaticResource Sub}"/>
            <Border Style="{StaticResource Card}" Margin="0,24,0,0" Padding="0">
              <StackPanel x:Name="DoneFacts"/>
            </Border>
          </StackPanel>
        </ScrollViewer>
      </Grid>

      <!-- Back always bottom left, the next step always bottom right -->
      <Border Grid.Row="1" Background="White" BorderBrush="#E2E8F0" BorderThickness="0,1,0,0" Padding="56,16">
        <Grid>
          <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <Button x:Name="BackButton" Style="{StaticResource Secondary}" MinWidth="120" Padding="22,12" FontSize="15"/>
          <TextBlock x:Name="FooterText" Grid.Column="1" Margin="22,0" VerticalAlignment="Center" Foreground="#475569" FontSize="14" TextWrapping="Wrap"/>
          <StackPanel Grid.Column="2" Orientation="Horizontal">
            <Button x:Name="AltButton" Style="{StaticResource Secondary}" MinWidth="120" Padding="22,12" FontSize="15" Margin="0,0,12,0"/>
            <Button x:Name="NextButton" Style="{StaticResource Primary}" MinWidth="190" Padding="28,12" FontSize="15"/>
          </StackPanel>
        </Grid>
      </Border>
    </Grid>
  </Grid>
</Window>
'@
[xml] $xaml = $xamlText.Replace('__KIOSK_STYLES__', $KioskStyles)

$window = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}
foreach ($node in $xaml.SelectNodes('//*[@*[local-name()="Name"]]')) {
    $name = $node.Attributes | Where-Object { $_.LocalName -eq 'Name' } | Select-Object -First 1 -ExpandProperty Value
    if ($name) { $ui[$name] = $window.FindName($name) }
}
$window.TaskbarItemInfo = New-Object System.Windows.Shell.TaskbarItemInfo
$IconPath = Join-Path $PSScriptRoot 'iPhoneTransfer.ico'
[IPhoneTransferApp.Native]::SetAppId('SmartTransfer.App')
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
$sync.Watch = $false
$sync.WatchKind = 'iPhone'
$sync.NewDest = $null
$sync.TryAgain = $false
$sync.LogPath = $LogPath

$settings = Get-Settings
$app = @{
    Page = 'Source'
    # the answers
    SourceType = ''; FolderPath = ''; Storage = ''; Dest = ''; Choice = ''; After = ''
    # the source as loaded by the engine
    Device = $null; LoadedKey = ''; AwaitingList = $false; SourceKind = ''; Mode = 'Photos'; SourceLabel = ''; UnitName = ''; Capacity = [int64] 0
    Rows = New-Object 'System.Collections.ObjectModel.ObservableCollection[IPhoneTransferApp.Row]'
    RowByName = @{}; Summaries = @{}
    DeleteRows = New-Object 'System.Collections.ObjectModel.ObservableCollection[IPhoneTransferApp.Row]'
    Speed = [double] 20MB
    Scanning = $false; ScanDone = $false; ChooseList = $false; ChoiceDirty = $true; Recommendation = $null
    CopyFolders = @(); CopyStats = $null; CopyRunning = $false; CopyDone = $null; CopyError = ''
    CheckFolders = @(); CheckRunning = $false; CheckDone = $null; CheckStopped = ''; CheckFull = $false; CheckSummaries = @{}
    Report = ''; VerifiedOk = @{}; PartialOk = @{}
    DeleteRunning = $false; DeleteDone = $null
    ResultNext = ''; ResultAlt = ''
    Session = $null; Waiting = $false; DeviceGone = $false; ForceClose = $false; LastFreeCheck = [DateTime]::MinValue
    Free = [int64] -1; Total = [int64] -1
}
$ui.FolderGrid.ItemsSource = $app.Rows
$ui.DeleteGrid.ItemsSource = $app.DeleteRows

$GREEN = '#15803D'; $AMBER = '#B45309'; $RED = '#B91C1C'; $GRAY = '#64748B'; $BLUE = '#1D4ED8'

# ---------------------------------------------------------------------------
# small helpers
# ---------------------------------------------------------------------------

function Write-UiLog { param([string] $Text) $sync.UiLog.Enqueue($Text) }

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

function Send-Command { param([hashtable] $Command) $sync.Commands.Enqueue($Command) }

function Get-SourceWord {
    # How the screens name the source: "the iPhone", "the phone", "the original folder".
    switch ($app.SourceType) {
        'iPhone'  { return 'the iPhone' }
        'Android' { return 'the phone' }
        default   { return 'the original folder' }
    }
}

function Get-SourceWordTitle { $word = Get-SourceWord; return ($word.Substring(0, 1).ToUpperInvariant() + $word.Substring(1)) }

function Test-Phone { return ($app.SourceType -eq 'iPhone' -or $app.SourceType -eq 'Android') }

function Get-UnitName {
    # The folder a folder source lands in: its own name, or for a whole drive "LABEL (E)" -
    # the engine's name once it has opened the source.
    if ($app.UnitName) { return $app.UnitName }
    if (-not $app.FolderPath) { return '' }
    if (Test-DriveRoot $app.FolderPath) {
        $root = [System.IO.Path]::GetPathRoot($app.FolderPath)
        if ($root.StartsWith('\\')) { return (Get-SafeName (Split-Path -Leaf $root.TrimEnd('\'))) }
        $label = ''
        try { $label = (New-Object System.IO.DriveInfo($root)).VolumeLabel } catch { }
        if (-not $label) { $label = 'Drive' }
        return (Get-SafeName ('{0} ({1})' -f $label, $root.TrimEnd('\').TrimEnd(':')))
    }
    return (Split-Path -Leaf $app.FolderPath.TrimEnd('\'))
}

function Get-DestTarget {
    # Where the files actually land: a folder source keeps its own folder inside the destination.
    param([string] $Path = $app.Dest)
    if (-not $Path) { return '' }
    if ($app.SourceType -eq 'Folder') { return [System.IO.Path]::Combine($Path, (Get-UnitName)) }
    return $Path
}

function Get-SourceTitle {
    switch ($app.SourceType) {
        'iPhone'  { if ($app.Device -and $app.Device.Device) { return [string] $app.Device.Device }; return 'iPhone' }
        'Android' { if ($app.Device -and $app.Device.Device) { return [string] $app.Device.Device }; return 'Android phone' }
        'Folder'  { if ($app.FolderPath) { if (Test-DriveRoot $app.FolderPath) { return ('Drive ' + $app.FolderPath.TrimEnd('\')) }; return (Split-Path -Leaf $app.FolderPath.TrimEnd('\')) }; return 'A folder or drive' }
    }
    return ''
}

function Test-Busy { return ($app.CopyRunning -or $app.CheckRunning -or $app.DeleteRunning) }

# ---------------------------------------------------------------------------
# building blocks: big choices, info cards, rows of facts
# ---------------------------------------------------------------------------

function Invoke-Tile {
    # Every big choice and "Change" button lands here as "kind:value".
    param([string] $Action)
    $parts = @($Action -split ':', 2)
    $kind = $parts[0]; $value = ''
    if ($parts.Count -gt 1) { $value = $parts[1] }
    Write-UiLog "choice: $Action"
    switch ($kind) {
        'source'  { Select-SourceType $value }
        'storage' { $app.Storage = $value; Update-ConnectCard $app.Device }
        'folder'  { if ($value -eq '?') { Select-SourceFolder } else { Set-SourcePath $value } }
        'dest'    { if ($value -eq '?') { Select-DestFolder } else { Select-Destination $value } }
        'choice'  { Select-Choice $value }
        'after'   { Select-After $value }
        'goto'    { if (Test-CanGoBack) { Show-Step $value } }
    }
}

# ---------------------------------------------------------------------------
# navigation: one screen at a time, the answers in the sidebar
# ---------------------------------------------------------------------------

$PAGES = @('Source', 'Connect', 'Dest', 'Choose', 'After', 'Review', 'Work', 'Result', 'Free', 'Done')
$STAGES = @(
    @{ Title = 'From';           Pages = @('Source', 'Connect'); Go = 'Source' },
    @{ Title = 'Save to';        Pages = @('Dest');              Go = 'Dest' },
    @{ Title = 'What';           Pages = @('Choose');            Go = 'Choose' },
    @{ Title = 'Originals';      Pages = @('After');             Go = 'After' },
    @{ Title = 'Start';          Pages = @('Review');            Go = 'Review' },
    @{ Title = 'Copy and check'; Pages = @('Work', 'Result');    Go = '' },
    @{ Title = 'Done';           Pages = @('Free', 'Done');      Go = '' }
)
$StageUi = New-Object System.Collections.ArrayList

function Test-CanGoBack {
    # Answers can be changed until the copy starts, and again when it was stopped.
    if (Test-Busy) { return $false }
    $index = [array]::IndexOf($PAGES, $app.Page)
    return ($index -le [array]::IndexOf($PAGES, 'Review') -or ($app.Page -eq 'Work'))
}

function Get-StageAnswer {
    param([int] $Index)
    switch ($Index) {
        0 { if ($app.SourceType) { return (Get-SourceTitle) } }
        1 { if ($app.Dest) { return (Format-ShortPath (Get-DestTarget) 34) } }
        2 {
            $s = Get-SelectionStats
            if ($app.Choice -and $s.Count -gt 0) {
                if ($app.Mode -eq 'Files') { return ('{0} files, {1}' -f (Format-Count $s.Files), (Format-Bytes $s.Bytes)) }
                return ('{0}, {1}' -f (Format-Plural $s.Count 'folder' 'folders'), (Format-Bytes $s.Bytes))
            }
        }
        3 {
            if ($app.After -eq 'Keep') { return 'Keep them' }
            if ($app.After -eq 'Remove') { if ($app.SourceType -eq 'Folder') { return 'Remove them (move)' }; return 'Free up space' }
        }
        5 {
            if ($app.CheckDone -and $app.CheckDone.AllOk) { return 'Every file checked' }
            if ($app.CheckDone) { return 'Some files need attention' }
        }
    }
    return ''
}

function Show-Step {
    param([string] $Name)
    $app.Page = $Name
    foreach ($p in $PAGES) {
        if ($p -eq $Name) { $ui["Page$p"].Visibility = 'Visible' } else { $ui["Page$p"].Visibility = 'Collapsed' }
    }
    switch ($Name) {
        'Source'  { Enter-Source }
        'Connect' { Enter-Connect }
        'Dest'    { Enter-Dest }
        'Choose'  { Enter-Choose }
        'After'   { Enter-After }
        'Review'  { Enter-Review }
        'Work'    { }
        'Result'  { Enter-Result }
        'Free'    { Enter-Free }
        'Done'    { Enter-Done }
    }
    Update-StageList
    Write-UiLog "page: $Name"
}

function Invoke-Back {
    switch ($app.Page) {
        'Connect' { Show-Step 'Source' }
        'Dest'    { Show-Step 'Connect' }
        'Choose'  {
            # From the folder list, Back returns to the suggestions first.
            if ($app.ChooseList) { $app.ChooseList = $false; $app.ChoiceDirty = $true; Enter-Choose }
            else { Show-Step 'Dest' }
        }
        'After'   { Show-Step 'Choose' }
        'Review'  { Show-Step 'After' }
        'Work'    { if (-not (Test-Busy)) { Show-Step 'Review' } }
        'Result'  { }
        'Free'    { if (-not $app.DeleteRunning) { Show-Step 'Result' } }
    }
}

function Invoke-Next {
    switch ($app.Page) {
        'Source'  { if ($app.SourceType) { Show-Step 'Connect' } }
        'Connect' { if ($app.SourceType -eq 'Folder' -and -not $app.FolderPath) { Select-SourceFolder } else { Confirm-Source } }
        'Dest'    { if ($app.Dest) { Show-Step 'Choose' } }
        'Choose'  { Confirm-Choice }
        'After'   { if ($app.After) { Show-Step 'Review' } }
        'Review'  { Start-Transfer }
        'Work'    { Invoke-WorkNext }
        'Result'  { Invoke-ResultAction $app.ResultNext }
        'Free'    { Start-Delete }
        'Done'    { Reset-Transfer }
    }
}

function Invoke-Alt {
    switch ($app.Page) {
        'Work'   { Switch-Pause }
        'Result' { Invoke-ResultAction $app.ResultAlt }
        'Done'   { Open-Destination }
    }
}

function Open-Destination {
    $target = Get-DestTarget
    if ($target -and (Test-Path -LiteralPath $target)) { Open-Path $target } else { Open-Path $app.Dest }
}

# ---------------------------------------------------------------------------
# from: what kind of source
# ---------------------------------------------------------------------------

function Enter-Source {
    $ui.SourceTiles.Children.Clear()
    $choices = @(
        @{ V = 'iPhone';  I = 0xE8EA; T = 'iPhone or iPad';          X = 'Photos and videos';                                          A = '#2563EB'; B = '#DBEAFE' },
        @{ V = 'Android'; I = 0xE8EA; T = 'Android phone or tablet'; X = 'Photos, videos and other files';                             A = '#15803D'; B = '#DCFCE7' },
        @{ V = 'Folder';  I = 0xF12B; T = 'A folder or drive';       X = 'On this PC, a USB stick, an SD card or an external drive';   A = '#B45309'; B = '#FEF3C7' }
    )
    foreach ($c in $choices) {
        [void] $ui.SourceTiles.Children.Add((New-Tile -Action ('source:' + $c.V) -Icon ([string] [char] $c.I) -Title $c.T -Text $c.X -Accent $c.A -AccentBack $c.B -Selected:($app.SourceType -eq $c.V)))
    }
    Set-Footer -Back '' -Next 'Continue' -NextEnabled ([bool] $app.SourceType)
}

function Select-SourceType {
    param([string] $Type)
    if ($Type -ne $app.SourceType) {
        $app.SourceType = $Type
        $app.Device = $null; $app.Storage = ''
        $app.Choice = ''; $app.After = ''
        # A different kind of source usually goes somewhere else: ask again where to save.
        $app.Dest = ''
        $app.Speed = $DEFAULT_SPEED[$Type]
        if ($settings.Speed[$Type]) { $app.Speed = [double] $settings.Speed[$Type] }
        $sync.WatchKind = $Type
        $sync.Watch = ($Type -ne 'Folder' -and -not $DemoPhone)
        if ($DemoPhone -and $Type -eq 'iPhone') { $app.Device = Get-DemoDevice }
    }
    Show-Step 'Connect'
}

# ---------------------------------------------------------------------------
# from: connect the phone, or pick the folder
# ---------------------------------------------------------------------------

function Set-HelpText {
    # Lines of help: each is @(bold start, rest).
    param($Lines)
    $ui.ConnectHelpText.Inlines.Clear()
    $first = $true
    foreach ($line in $Lines) {
        if (-not $first) { $ui.ConnectHelpText.Inlines.Add((New-Object System.Windows.Documents.LineBreak)) }
        $first = $false
        $bold = New-Object System.Windows.Documents.Run $line[0]
        $bold.FontWeight = 'SemiBold'
        $ui.ConnectHelpText.Inlines.Add($bold)
        $ui.ConnectHelpText.Inlines.Add((New-Object System.Windows.Documents.Run (' ' + $line[1])))
    }
}

function Show-ConnectSteps {
    param($Steps)
    $ui.ConnectSteps.Children.Clear()
    $n = 0
    foreach ($step in $Steps) {
        $n++
        $grid = New-Object System.Windows.Controls.Grid
        $grid.Margin = '0,0,0,18'
        foreach ($w in 'Auto', '*') {
            $c = New-Object System.Windows.Controls.ColumnDefinition
            $c.Width = (New-Object System.Windows.GridLengthConverter).ConvertFromString($w)
            [void] $grid.ColumnDefinitions.Add($c)
        }
        $dot = New-Object System.Windows.Controls.Border
        $dot.Width = 34; $dot.Height = 34; $dot.CornerRadius = '17'; $dot.VerticalAlignment = 'Top'
        Set-Color $dot 'Background' '#DBEAFE'
        $num = New-Text -Text ([string] $n) -Size 15 -Color '#1D4ED8' -Weight 'Bold'
        $num.HorizontalAlignment = 'Center'; $num.VerticalAlignment = 'Center'
        $dot.Child = $num
        $texts = New-Object System.Windows.Controls.StackPanel
        $texts.Margin = '16,4,0,0'
        [void] $texts.Children.Add((New-Text -Text $step[0] -Size 16 -Weight 'SemiBold'))
        [void] $texts.Children.Add((New-Text -Text $step[1] -Size 14 -Color '#64748B' -Margin '0,3,0,0'))
        [System.Windows.Controls.Grid]::SetColumn($texts, 1)
        [void] $grid.Children.Add($dot); [void] $grid.Children.Add($texts)
        [void] $ui.ConnectSteps.Children.Add($grid)
    }
}

function Enter-Connect {
    if (Test-Phone) {
        $ui.PhonePanel.Visibility = 'Visible'; $ui.FolderPanel.Visibility = 'Collapsed'
        if ($app.SourceType -eq 'iPhone') {
            $ui.ConnectHeading.Text = 'Connect your iPhone'
            $ui.ConnectSubText.Text = 'It is found by itself as soon as it is plugged in and unlocked.'
            Show-ConnectSteps @(
                @('Plug the iPhone into this PC', 'Use its cable. A USB port directly on the PC is faster and steadier than a hub.'),
                @('Unlock it', 'Enter your passcode so the iPhone shows its home screen.'),
                @('Tap "Trust" if it asks', '"Trust This Computer?" appears the first time. Tap Trust and enter your passcode.'))
            $ui.ConnectHelp.Header = 'The iPhone does not show up?'
            Set-HelpText @(
                @('Install Apple Devices', '(free, from the Microsoft Store). It adds the driver Windows needs to see an iPhone. You do not need to open it or sign in.'),
                @('Unplug and plug back in,', 'then unlock the iPhone and watch for the Trust question.'),
                @('Try another cable or USB port.', 'Some cables only charge.'),
                @('Tapped "Don''t Trust" by mistake?', 'On the iPhone: Settings > General > Transfer or Reset iPhone > Reset > Reset Location & Privacy, then plug in again.'))
        }
        else {
            $ui.ConnectHeading.Text = 'Connect your Android phone'
            $ui.ConnectSubText.Text = 'It is found by itself as soon as it is plugged in, unlocked and set to File transfer.'
            Show-ConnectSteps @(
                @('Plug the phone into this PC', 'Use a cable that carries data - some cables only charge.'),
                @('Unlock it', 'The phone only shares its files while it is unlocked.'),
                @('Choose "File transfer"', 'Swipe down from the top of the phone, tap the USB notification and choose File transfer (on some phones "Transfer files" or "MTP"). Tap Allow if it asks.'))
            $ui.ConnectHelp.Header = 'The phone does not show up?'
            Set-HelpText @(
                @('No USB notification?', 'Try another cable or USB port. Many cables that come with chargers only charge.'),
                @('Shows up, but empty?', 'Unlock the phone, swipe down and choose File transfer again. Samsung phones ask "Allow access to phone data?" - tap Allow.'),
                @('Still nothing?', 'Unplug it, plug it back in and unlock it. On some phones the setting is in Settings > Connected devices > USB.'))
        }
        $ui.ConnectHelp.IsExpanded = $false
        Update-ConnectCard $app.Device
    }
    else {
        $ui.PhonePanel.Visibility = 'Collapsed'; $ui.FolderPanel.Visibility = 'Visible'
        $ui.ConnectHeading.Text = 'Which folder do you want to copy?'
        $ui.ConnectSubText.Text = 'Everything in it is copied - every file and every folder inside, exactly as it is.'
        Show-FolderTiles
        Set-Footer -Next 'Continue' -NextEnabled ([bool] $app.FolderPath)
    }
}

function Get-DemoDevice {
    $names = [string[]] @(Get-ChildItem -LiteralPath $DemoPhone -Directory | ForEach-Object { $_.Name } | Sort-Object)
    return @{ State = 'Ready'; Kind = 'iPhone'; Device = 'Apple iPhone'; Storage = 'Internal Storage'; Capacity = [int64] 128GB; Folders = $names
              Storages = @(@{ Name = 'Internal Storage'; Capacity = [int64] 128GB; Folders = $names }) }
}

function Update-ConnectCard {
    param($State)
    if ($State -and $State.Kind -and $State.Kind -ne $app.SourceType) { return }   # left over from the other kind of phone
    $app.Device = $State
    if ($app.Page -ne 'Connect' -or -not (Test-Phone)) { return }
    $iphone = ($app.SourceType -eq 'iPhone')
    $noun = 'phone'; if ($iphone) { $noun = 'iPhone' }
    $ready = $false
    $ui.StorageArea.Visibility = 'Collapsed'
    $status = 'None'; if ($State) { $status = $State.State }
    switch ($status) {
        'Ready' {
            $ready = $true
            $storage = $app.Storage
            $chosen = @($State.Storages | Where-Object { $_.Name -eq $storage }) | Select-Object -First 1
            if (-not $chosen) { $chosen = @($State.Storages)[0]; if ($chosen) { $app.Storage = $chosen.Name } }
            $ui.ConnectTitle.Text = "Connected: $($State.Device)"
            $detail = ''
            if ($chosen -and $chosen.Capacity -gt 0) { $detail = (Format-Bytes $chosen.Capacity) + ' ' + $noun + '. ' }
            $ui.ConnectDetail.Text = $detail + 'Press Continue.'
            Set-Color $ui.ConnectIconBack 'Background' '#DCFCE7'; Set-Color $ui.ConnectIcon 'Foreground' '#16A34A'; $ui.ConnectIcon.Text = [string] [char] 0xE73E
            $ui.ConnectBar.Visibility = 'Collapsed'
            if (@($State.Storages).Count -gt 1) {
                $ui.StorageArea.Visibility = 'Visible'
                $ui.StoragePanel.Children.Clear()
                foreach ($s in $State.Storages) {
                    $text = ''
                    if ($s.Capacity -gt 0) { $text = Format-Bytes $s.Capacity; if ($s.Free -ge 0) { $text += ', ' + (Format-Bytes $s.Free) + ' free' } }
                    $tile = New-Tile -Action ('storage:' + $s.Name) -Icon ([string] [char] 0xEDA2) -Title $s.Name -Text $text -Wide -Selected:($s.Name -eq $app.Storage)
                    $tile.Margin = '8,8,8,0'
                    [void] $ui.StoragePanel.Children.Add($tile)
                }
            }
        }
        'Locked' {
            if ($iphone) {
                $ui.ConnectTitle.Text = "$($State.Device) found - please unlock it"
                $ui.ConnectDetail.Text = 'Unlock the iPhone and tap Trust if it asks. The photos appear a moment later.'
            }
            else {
                $ui.ConnectTitle.Text = "$($State.Device) found - unlock it and choose File transfer"
                $ui.ConnectDetail.Text = 'Unlock the phone. Still nothing? Swipe down, tap the USB notification and choose File transfer.'
            }
            Set-Color $ui.ConnectIconBack 'Background' '#FEF3C7'; Set-Color $ui.ConnectIcon 'Foreground' '#B45309'; $ui.ConnectIcon.Text = [string] [char] 0xE72E
            $ui.ConnectBar.Visibility = 'Visible'
        }
        'Empty' {
            $ui.ConnectTitle.Text = "$($State.Device) found - nothing visible yet"
            if ($iphone) { $ui.ConnectDetail.Text = 'Unlock the iPhone and keep it unlocked for a moment. If it stays empty, the photos may only be in iCloud.' }
            else { $ui.ConnectDetail.Text = 'Unlock the phone and keep it unlocked for a moment.' }
            Set-Color $ui.ConnectIconBack 'Background' '#FEF3C7'; Set-Color $ui.ConnectIcon 'Foreground' '#B45309'; $ui.ConnectIcon.Text = [string] [char] 0xE72E
            $ui.ConnectBar.Visibility = 'Visible'
        }
        default {
            $ui.ConnectTitle.Text = "Looking for your $noun..."
            if ($iphone) { $ui.ConnectDetail.Text = 'Plug it in with its cable and unlock it.' }
            else { $ui.ConnectDetail.Text = 'Plug it in with a data cable, unlock it and choose File transfer.' }
            Set-Color $ui.ConnectIconBack 'Background' '#F1F5F9'; Set-Color $ui.ConnectIcon 'Foreground' '#64748B'; $ui.ConnectIcon.Text = [string] [char] 0xE8EA
            $ui.ConnectBar.Visibility = 'Visible'
        }
    }
    Set-Footer -Next 'Continue' -NextEnabled $ready
}

function Show-FolderTiles {
    $ui.FolderTiles.Children.Clear()
    if ($app.FolderPath) {
        [void] $ui.FolderTiles.Children.Add((New-Tile -Action ('folder:' + $app.FolderPath) -Icon ([string] [char] 0xF12B) -Title (Get-SourceTitle) -Text $app.FolderPath -Accent '#B45309' -AccentBack '#FEF3C7' -Wide -Selected))
    }
    $title = 'Choose a folder...'
    if ($app.FolderPath) { $title = 'Choose a different folder...' }
    [void] $ui.FolderTiles.Children.Add((New-Tile -Action 'folder:?' -Icon ([string] [char] 0xED25) -Title $title -Text 'Any folder on this PC or on a network drive.' -Accent '#B45309' -AccentBack '#FEF3C7' -Wide))
    # Plugged-in drives, ready to take as a whole: a USB stick, an SD card, a network drive.
    foreach ($d in (Get-UsableDrives @('Removable', 'Network'))) {
        if ($app.FolderPath -and $app.FolderPath.TrimEnd('\') -eq $d.Name.TrimEnd('\')) { continue }
        $used = [double] ($d.TotalSize - $d.AvailableFreeSpace)
        $icon = [char] 0xE88E; if ([string] $d.DriveType -eq 'Network') { $icon = [char] 0xE8CE }
        [void] $ui.FolderTiles.Children.Add((New-Tile -Action ('folder:' + $d.Name) -Icon ([string] $icon) -Title ('Everything on ' + (Get-DriveTitle $d)) -Text ('{0} of files on it' -f (Format-Bytes $used)) -Accent '#475569' -AccentBack '#E2E8F0' -Wide))
    }
}

function Select-SourceFolder {
    $path = Select-FolderDialog 'Choose the folder to copy. Everything in it is copied, including every folder inside.' $app.FolderPath
    if ($path) { Set-SourcePath $path }
}

function Set-SourcePath {
    param([string] $Path)
    try { $full = [System.IO.Path]::GetFullPath($Path) } catch { Show-Message "That folder cannot be used: $Path" 'Smart Transfer' 'Warning'; return }
    if (-not [System.IO.Directory]::Exists($full)) { Show-Message "That folder is not there: $full" 'Smart Transfer' 'Warning'; return }
    if (-not (Test-DriveRoot $full)) { $full = $full.TrimEnd('\') }
    if ($full -ne $app.FolderPath) { $app.UnitName = '' }
    $app.FolderPath = $full
    Confirm-Source
}

function Confirm-Source {
    # The source is settled: read it (again, if it changed) and move on to where to save.
    if ($app.SourceType -eq 'Folder') {
        if (-not $app.FolderPath) { return }
        $key = 'Folder|' + $app.FolderPath
    }
    elseif ($DemoPhone) { $key = 'Demo|' + $DemoPhone }
    else {
        if (-not $app.Device -or $app.Device.State -ne 'Ready') { return }
        $storage = $app.Storage
        if (-not $storage) { $storage = $app.Device.Storage }
        $key = 'Device|{0}|{1}|{2}' -f $app.SourceType, $app.Device.Device, $storage
    }
    if ($key -ne $app.LoadedKey) { Start-Loading $key }
    Show-Step 'Dest'
}

function Start-Loading {
    param([string] $Key)
    if ($sync.Busy) { $sync.Cancel = $true }   # stop reading the previous source
    $app.LoadedKey = $Key
    $app.AwaitingList = $true
    $app.Rows.Clear(); $app.RowByName = @{}; $app.Summaries = @{}; $app.VerifiedOk = @{}; $app.PartialOk = @{}
    $app.Scanning = $true; $app.ScanDone = $false; $app.ChooseList = $false; $app.ChoiceDirty = $true; $app.Choice = ''; $app.Session = $null
    $app.CopyDone = $null; $app.CheckDone = $null; $app.DeleteDone = $null; $app.CheckStopped = ''
    if ($app.SourceType -eq 'Folder') { $app.Mode = 'Files'; Send-Command @{ Name = 'SetSource'; Kind = 'Folder'; Path = $app.FolderPath; Layout = 'Tree' } }
    elseif ($DemoPhone) { $app.Mode = 'Photos'; Send-Command @{ Name = 'SetSource'; Kind = 'Folder'; Path = $DemoPhone; Layout = 'Units' } }
    else { $app.Mode = 'Photos'; Send-Command @{ Name = 'SetSource'; Kind = 'Device'; DeviceKind = $app.SourceType; Storage = $app.Storage } }
    Write-UiLog "loading source: $Key"
}

# ---------------------------------------------------------------------------
# save to
# ---------------------------------------------------------------------------

function Get-DefaultFolderName {
    switch ($app.SourceType) {
        'iPhone'  { return 'iPhone Photos' }
        'Android' { return 'Phone Photos' }
        default   { return '' }   # a folder lands in a folder of its own name anyway
    }
}

function Get-LastDestination {
    if ($Destination) { return $Destination }
    if ($AutoPilot) { return '' }   # test runs never use a real user's saved destination
    $last = $settings.Dest[$app.SourceType]
    if ($last -and (Test-Path -LiteralPath $last)) { return $last }
    return ''
}

function Get-FreeText {
    param([string] $Path)
    $root = $Path
    while ($root -and -not (Test-Path -LiteralPath $root)) { $root = Split-Path -Parent $root }
    if (-not $root) { return '' }
    $free = [IPhoneTransferApp.Native]::GetFreeBytes($root)
    $total = [IPhoneTransferApp.Native]::GetTotalBytes($root)
    if ($free -lt 0) { return '' }
    if ($total -gt 0) { return ('{0} free of {1}' -f (Format-Bytes $free), (Format-Bytes $total)) }
    return ('{0} free' -f (Format-Bytes $free))
}

function Enter-Dest {
    if ($app.SourceType -eq 'Folder') { $ui.DestSubText.Text = ('Pick a drive or a folder. "{0}" is copied into it as a folder of its own.' -f (Get-UnitName)) }
    else { $ui.DestSubText.Text = ('Pick a drive or a folder on this PC. The photos keep the same folders as on {0}.' -f (Get-SourceWord)) }
    $ui.DestTiles.Children.Clear()
    $shown = @{}
    if ($app.Dest) {
        [void] $ui.DestTiles.Children.Add((New-Tile -Action ('dest:' + $app.Dest) -Icon ([string] [char] 0xF12B) -Title (Format-ShortPath (Get-DestTarget) 70) -Text 'Saves here' -Extra (Get-FreeText $app.Dest) -Wide -Selected))
        $shown[$app.Dest.ToLowerInvariant()] = $true
    }
    $last = Get-LastDestination
    if ($last -and -not $shown.ContainsKey($last.ToLowerInvariant())) {
        [void] $ui.DestTiles.Children.Add((New-Tile -Action ('dest:' + $last) -Icon ([string] [char] 0xE81C) -Title 'Same place as last time' -Text (Format-ShortPath (Get-DestTarget $last) 90) -Extra (Get-FreeText $last) -Wide))
        $shown[$last.ToLowerInvariant()] = $true
    }
    foreach ($d in (Get-UsableDrives)) {
        $path = $d.Name
        $folderName = Get-DefaultFolderName
        if ($folderName) { $path = Join-Path $d.Name $folderName }
        if ($shown.ContainsKey($path.ToLowerInvariant())) { continue }
        $used = 0.0; if ($d.TotalSize -gt 0) { $used = [double] ($d.TotalSize - $d.AvailableFreeSpace) / [double] $d.TotalSize }
        $icon = [char] 0xEDA2
        if ([string] $d.DriveType -eq 'Removable') { $icon = [char] 0xE88E } elseif ([string] $d.DriveType -eq 'Network') { $icon = [char] 0xE8CE }
        [void] $ui.DestTiles.Children.Add((New-Tile -Action ('dest:' + $path) -Icon ([string] $icon) -Title (Get-DriveTitle $d) -Text ('Saves to ' + (Get-DestTarget $path)) -Extra ('{0} free of {1}' -f (Format-Bytes $d.AvailableFreeSpace), (Format-Bytes $d.TotalSize)) -Bar $used -Accent '#475569' -AccentBack '#E2E8F0' -Wide))
    }
    [void] $ui.DestTiles.Children.Add((New-Tile -Action 'dest:?' -Icon ([string] [char] 0xED25) -Title 'Choose a folder...' -Text 'Any folder, also on a network drive. You can make a new one there.' -Wide))
    Set-Footer -Next 'Continue' -NextEnabled ([bool] $app.Dest)
}

function Select-DestFolder {
    $start = $app.Dest; if (-not $start) { $start = Get-LastDestination }
    $path = Select-FolderDialog 'Choose where to save the copies.' $start
    if ($path) { Select-Destination $path }
}

function Select-Destination {
    param([string] $Path)
    if (Set-Destination $Path -ByUser) { Show-Step 'Choose' }
    elseif ($app.Page -eq 'Dest') { Enter-Dest }
}

function Test-Inside {
    # Is one of the two folders the same as, or inside, the other?
    param([string] $A, [string] $B)
    $a2 = [System.IO.Path]::GetFullPath($A).TrimEnd('\') + '\'
    $b2 = [System.IO.Path]::GetFullPath($B).TrimEnd('\') + '\'
    return ($a2.StartsWith($b2, [StringComparison]::OrdinalIgnoreCase) -or $b2.StartsWith($a2, [StringComparison]::OrdinalIgnoreCase))
}

function Set-Destination {
    # Returns $true when the folder can be used and is now the destination.
    param([string] $Path, [switch] $ByUser)
    if (-not $Path) { return $false }
    try { $Path = [System.IO.Path]::GetFullPath($Path).TrimEnd('\'); if ($Path.Length -eq 2) { $Path += '\' } }
    catch { Show-Message "That folder cannot be used: $Path" 'Smart Transfer' 'Warning'; return $false }
    # Picked one month folder (like ...\202609_a)? Each source folder is saved as a sub-folder
    # of the destination, so new files would end up in 202609_a\202609_a. Offer the one above.
    $leaf = Split-Path -Leaf $Path
    $parent = Split-Path -Parent $Path
    if ($ByUser -and $app.Mode -eq 'Photos' -and $parent -and ($leaf -match '^\d{6}_{1,2}[a-z]?$' -or $app.RowByName.ContainsKey($leaf))) {
        $question = ("You chose the folder ""{0}"".`r`n`r`nThe folders from {3} are kept as they are, so the photos of {0} would go into ""{1}"".`r`n`r`nSave into the folder above it instead?`r`n`r`n    {2}" -f $leaf, (Join-Path $Path $leaf), $parent, (Get-SourceWord))
        if (Confirm-Action $question 'Choose the main folder?') { $Path = $parent }
    }
    if ($app.SourceType -eq 'Folder' -and $app.FolderPath -and (Test-Inside (Get-DestTarget $Path) $app.FolderPath)) {
        Show-Message ("The copy would land in, or around, the folder you copy from:`r`n`r`n    {0}`r`n`r`nPlease choose somewhere else." -f (Get-DestTarget $Path)) 'Smart Transfer' 'Warning'
        return $false
    }
    if ($DemoPhone -and (Test-Inside $Path $DemoPhone)) { Show-Message 'Please choose a destination outside the demo phone folder.' 'Smart Transfer' 'Warning'; return $false }
    # Must be somewhere we can write: try it now rather than at the first file.
    $probeDir = $Path
    while ($probeDir -and -not (Test-Path -LiteralPath $probeDir)) { $probeDir = Split-Path -Parent $probeDir }
    if (-not $probeDir) { Show-Message "That drive is not available: $Path" 'Smart Transfer' 'Warning'; return $false }
    try {
        $probe = Join-Path $probeDir ('.iphone-transfer-write-test-' + [guid]::NewGuid().ToString('N'))
        [System.IO.File]::WriteAllText($probe, 'ok'); [System.IO.File]::Delete($probe)
    }
    catch { Show-Message "Smart Transfer cannot save files in $probeDir.`r`n`r`nPlease choose another folder." 'Smart Transfer' 'Warning'; return $false }

    if ($app.Dest -ne $Path) { $app.VerifiedOk = @{}; $app.PartialOk = @{}; $app.ChoiceDirty = $true }   # checks were made against the old destination
    $app.Dest = $Path
    Update-FreeSpace -Force
    foreach ($row in $app.Rows) { if ($row.Scanned) { $row.Status = 'Comparing...'; $row.StatusColor = $GRAY } }
    if ($sync.Busy) { $sync.NewDest = $Path } else { Send-Command @{ Name = 'SetDestination'; Path = $Path } }
    Write-UiLog "destination chosen: $Path"
    return $true
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

# ---------------------------------------------------------------------------
# what: the folders, what is new, and the recommendation
# ---------------------------------------------------------------------------

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
    $row.Size = Format-Bytes $Summary.Bytes
    $row.Types = ("{0} - file types`r`n" -f $Summary.Name) + (Format-Types $Summary.Types)
    $dates = Format-Dates $Summary.FirstDate $Summary.LastDate
    if (-not $dates) { $dates = Get-FolderLabel $Summary.Name }
    $media = @()
    if ($Summary.Photos -gt 0) { $media += (Format-Plural $Summary.Photos 'photo' 'photos') }
    if ($Summary.Videos -gt 0) { $media += (Format-Plural $Summary.Videos 'video' 'videos') }
    if ($Summary.Other -gt 0) { $media += (Format-Plural $Summary.Other 'other file' 'other files') }
    $row.Dates = (@($dates) + $media | Where-Object { $_ }) -join $DOT
    $row.Note = $row.Types

    if ($Summary.Error) {
        $row.Status = 'Could not be read'; $row.StatusColor = $RED; $row.CanSelect = $false; $row.Selected = $false
        $row.Note = 'Unlock it and go back one step to read it again. ' + $Summary.Error
        return
    }
    if ($Summary.Files -eq 0) {
        $row.StatusColor = $GRAY; $row.CanSelect = $false; $row.Selected = $false
        $row.Status = 'Empty'
        if ($app.SourceType -eq 'iPhone') { $row.Note = 'The iPhone lists no files here. Usually it fills in on a later read; if it stays empty, these photos are only in iCloud.' }
        return
    }
    $row.CanSelect = $true
    if ($null -ne $Summary.PresentFiles) {
        $row.PresentFiles = [int64] $Summary.PresentFiles
        $row.FilesToCopy = [int64] ($Summary.Files - $Summary.PresentFiles)
        $row.BytesToCopy = [math]::Max([int64] 0, [int64] ($Summary.Bytes - $Summary.PresentBytes))
        if ($row.FilesToCopy -gt 0) { $row.Files = Format-Count $row.FilesToCopy } else { $row.Files = '-' }
        if ($app.VerifiedOk.ContainsKey($Summary.Name)) { $row.Status = $CHECK + ' On this PC, checked'; $row.StatusColor = $GREEN }
        elseif ($Summary.PresentFiles -ge $Summary.Files) { $row.Status = $CHECK + ' On this PC'; $row.StatusColor = $GREEN }
        elseif ($Summary.PresentFiles -gt 0) { $row.Status = 'Partly ({0} of {1})' -f (Format-Count $Summary.PresentFiles), (Format-Count $Summary.Files); $row.StatusColor = $AMBER }
        else { $row.Status = 'Not on this PC yet'; $row.StatusColor = $GRAY }
    }
    else {
        $row.FilesToCopy = [int64] $Summary.Files; $row.BytesToCopy = [int64] $Summary.Bytes
        $row.Files = Format-Count $Summary.Files
        if ($app.Dest) { $row.Status = 'Comparing...' } else { $row.Status = '' }
        $row.StatusColor = $GRAY
    }
    if ($app.Mode -eq 'Files') { $row.Selected = $true }
}

function Test-MediaRow {
    # Mostly photos and videos? On an Android phone those are what is suggested by default.
    param($Row)
    $s = $app.Summaries[$Row.Name]
    if (-not $s) { return $false }
    $media = [int64] $s.Photos + [int64] $s.Videos
    return ($media -gt 0 -and 2 * $media -ge [int64] $s.Files)
}

function Get-Recommendation {
    # Whole folders only, so a folder is either fully on the PC or not at all. Folders whose
    # copy was interrupted come first, then the oldest (iPhone) or the camera first (Android),
    # for as long as they fit with room to spare. On an Android phone only folders that are
    # mostly photos and videos are suggested - Download, Music and the like are left to choose.
    $budget = $app.Free - $RESERVE
    $picked = New-Object System.Collections.ArrayList
    $used = [int64] 0
    $skipped = 0
    $candidates = @($app.Rows | Where-Object { $_.Scanned -and $_.CanSelect -and $_.FileCount -gt 0 -and $_.BytesToCopy -gt 0 })
    if ($app.SourceType -eq 'Android') { $candidates = @($candidates | Where-Object { Test-MediaRow $_ }) }
    $order = @{}; $i = 0
    foreach ($r in $app.Rows) { $order[$r.Name] = $i++ }
    if ($app.SourceType -eq 'Android') { $ordered = @($candidates | Sort-Object @{ Expression = { if ($_.PresentFiles -gt 0) { 0 } else { 1 } } }, @{ Expression = { $order[$_.Name] } }) }
    else { $ordered = @($candidates | Sort-Object @{ Expression = { if ($_.PresentFiles -gt 0) { 0 } else { 1 } } }, @{ Expression = { $_.Name } }) }
    foreach ($row in $ordered) {
        if ($app.Free -ge 0 -and ($used + $row.BytesToCopy) -gt $budget) { $skipped++; continue }
        [void] $picked.Add($row)
        $used += $row.BytesToCopy
    }
    $files = [int64] 0
    foreach ($r in $picked) { $files += $r.FilesToCopy }
    return @{ Rows = $picked; Bytes = $used; Files = $files; Skipped = $skipped; Candidates = $candidates.Count }
}

function Get-ResumeFolders {
    # The copy that was interrupted last time (into this destination, from this source).
    $s = $app.Session
    if (-not $s -or $s.State -ne 'copying' -or @($s.Folders).Count -eq 0) { return @() }
    if ($s.Source -and $app.SourceLabel -and $s.Source -ne $app.SourceLabel) { return @() }
    return @($s.Folders | Where-Object { $app.RowByName.ContainsKey($_) -and $app.RowByName[$_].CanSelect -and $app.RowByName[$_].BytesToCopy -gt 0 })
}

function Get-SelectionStats {
    $selected = @($app.Rows | Where-Object { $_.Selected -and $_.CanSelect })
    $s = @{ Count = $selected.Count; Files = [int64] 0; Bytes = [int64] 0; ToCopy = [int64] 0; ToCopyFiles = [int64] 0; Fits = $true; AllScanned = $true
            Names = [string[]] @($selected | ForEach-Object { $_.Name }) }
    foreach ($r in $selected) {
        $s.Files += $r.FileCount; $s.Bytes += $r.Bytes; $s.ToCopy += $r.BytesToCopy; $s.ToCopyFiles += $r.FilesToCopy
        if (-not $r.Scanned) { $s.AllScanned = $false }
    }
    if ($app.Free -ge 0) { $s.Fits = ($s.ToCopy + $RESERVE / 4) -le $app.Free }
    return $s
}

function Set-Selection {
    param([string[]] $Names)
    foreach ($row in $app.Rows) { if ($row.CanSelect) { $row.Selected = ($Names -contains $row.Name) } else { $row.Selected = $false } }
}

function Select-Recommended {
    $rec = Get-Recommendation
    $app.Recommendation = $rec
    Set-Selection ([string[]] @($rec.Rows | ForEach-Object { $_.Name }))
}

function Enter-Choose {
    $target = Get-DestTarget
    if ($app.Mode -eq 'Files') {
        $ui.ChooseHeading.Text = 'This is what will be copied'
        $ui.ChooseSubText.Text = 'Every file and folder inside is copied. Files that are already there are not copied again.'
    }
    else {
        $ui.ChooseHeading.Text = 'What should be copied?'
        $ui.ChooseSubText.Text = ('Everything on {0} was compared with {1}. Files that are already there are skipped.' -f (Get-SourceWord), (Format-ShortPath $target))
    }
    $app.ChoiceDirty = $true
    Update-ChoosePage
}

function Update-ScanCard {
    $p = $sync.Progress
    if ($app.ScanDone) { $ui.ScanCard.Visibility = 'Collapsed'; return }
    $ui.ScanCard.Visibility = 'Visible'
    if ($app.Waiting -or $app.DeviceGone) {
        $ui.ScanTitle.Text = ('{0} is disconnected or locked' -f (Get-SourceWord))
        $ui.ScanDetail.Text = 'Plug it in and unlock it - reading continues by itself.'
        Set-Color $ui.ScanTitle 'Foreground' $AMBER
        return
    }
    Set-Color $ui.ScanTitle 'Foreground' '#0F172A'
    $files = Format-Plural ([int64] $p.ScanFiles) 'file' 'files'
    if ($app.Mode -eq 'Files') {
        $ui.ScanTitle.Text = ('Reading {0}...' -f (Get-UnitName))
        $ui.ScanDetail.Text = '{0} ({1}) found so far' -f $files, (Format-Bytes ([double] $p.ScanBytes))
        $ui.ScanPercent.Text = ''
        $ui.ScanBar.IsIndeterminate = $false; $ui.ScanBar.Value = 0; $ui.ScanBar.Visibility = 'Collapsed'
        return
    }
    $ui.ScanBar.Visibility = 'Visible'
    $total = [int] $p.ScanTotal; $index = [int] $p.ScanIndex
    $pct = 0.0; if ($total -gt 0) { $pct = [math]::Max([double] 0, [double] ($index - 1) * 100.0 / $total) }
    $ui.ScanBar.Value = $pct
    $ui.ScanPercent.Text = '{0}%' -f [int] $pct
    $ui.ScanTitle.Text = ('Looking at what is on {0}...' -f (Get-SourceWord))
    if ($app.AwaitingList -or $p.Phase -ne 'Scan') { $ui.ScanDetail.Text = 'Opening it...'; return }
    $elapsed = ''
    if ($p.FolderStarted) {
        $seconds = ([DateTime]::UtcNow - $p.FolderStarted).TotalSeconds
        if ($seconds -ge 5) { $elapsed = ' ({0:0}s)' -f $seconds }
    }
    $ui.ScanDetail.Text = ('Folder {0} of {1}: {2}{3}{4}{5} found so far' -f $index, $total, $p.ScanFolder, $elapsed, $DOT, $files)
    $row = $app.RowByName[[string] $p.ScanFolder]
    if ($row -and -not $row.Scanned) {
        $n = [int64] $p.FolderFiles
        if ($n -gt 0) { $row.Status = 'Reading... ' + (Format-Count $n) } else { $row.Status = 'Reading...' }
    }
}

function Show-ChoiceTiles {
    # The suggestions for photos: one click picks one. The folder list is one of them.
    $ui.ChoiceTiles.Children.Clear()
    $noun = 'iPhone'; if ($app.SourceType -eq 'Android') { $noun = 'phone' }
    $drive = [System.IO.Path]::GetPathRoot($app.Dest)
    $custom = { param($Text) New-Tile -Action 'choice:Custom' -Icon ([string] [char] 0xE762) -Title 'Let me choose the folders' -Text $Text -Accent '#475569' -AccentBack '#E2E8F0' -Wide -Selected:($app.Choice -eq 'Custom') }
    if ($app.AwaitingList -or -not $app.ScanDone) {
        $text = 'A suggestion appears once every folder has been read. You can already pick from the folders read so far.'
        [void] $ui.ChoiceTiles.Children.Add((& $custom $text))
        $ui.ConvertTip.Visibility = 'Collapsed'
        return
    }
    $readable = @($app.Rows | Where-Object { $_.Scanned -and $_.CanSelect -and $_.FileCount -gt 0 })
    $pending = @($readable | Where-Object { $_.BytesToCopy -gt 0 })
    $badgeUsed = $false

    $resume = @(Get-ResumeFolders)
    if ($resume.Count -gt 0) {
        $files = [int64] 0; $bytes = [int64] 0
        foreach ($n in $resume) { $files += $app.RowByName[$n].FilesToCopy; $bytes += $app.RowByName[$n].BytesToCopy }
        $names = ($resume | Select-Object -First 4) -join ', '
        if ($resume.Count -gt 4) { $names += (' and {0} more' -f ($resume.Count - 4)) }
        [void] $ui.ChoiceTiles.Children.Add((New-Tile -Action 'choice:Resume' -Icon ([string] [char] 0xE768) -Title 'Finish the copy that was interrupted' -Text $names -Extra ('{0} ({1}) still to copy' -f (Format-Plural $files 'file' 'files'), (Format-Bytes $bytes)) -Badge 'Recommended' -Accent '#15803D' -AccentBack '#DCFCE7' -Wide -Selected:($app.Choice -eq 'Resume')))
        $badgeUsed = $true
        if ($app.Choice -eq 'Resume') { Set-Selection ([string[]] $resume) }
    }

    if ($readable.Count -eq 0) {
        $text = 'The folders are empty.'
        if ($app.SourceType -eq 'iPhone') { $text += ' If your photos are in iCloud, set the iPhone to "Download and Keep Originals" (Settings > Photos) and try again later.' }
        [void] $ui.ChoiceTiles.Children.Add((New-InfoCard -Icon ([string] [char] 0xE946) -Title ('No files found on ' + (Get-SourceWord)) -Text $text -Tone 'blue'))
    }
    elseif ($pending.Count -eq 0) {
        $badge = ''; if (-not $badgeUsed) { $badge = 'Recommended' }
        [void] $ui.ChoiceTiles.Children.Add((New-Tile -Action 'choice:CheckAll' -Icon ([string] [char] 0xE73E) -Title 'Everything is already on this PC' -Text ('Nothing new to copy. Every file gets checked - then you can free up space on the {0} if you want.' -f $noun) -Extra ('{0} in {1}' -f (Format-Plural $readable.Count 'folder' 'folders'), (Format-ShortPath (Get-DestTarget))) -Badge $badge -Accent '#15803D' -AccentBack '#DCFCE7' -Wide -Selected:($app.Choice -eq 'CheckAll')))
        if ($app.Choice -eq 'CheckAll') { Set-Selection ([string[]] @($readable | ForEach-Object { $_.Name })) }
    }
    else {
        $rec = Get-Recommendation
        $app.Recommendation = $rec
        if ($rec.Rows.Count -gt 0) {
            $all = ($rec.Skipped -eq 0)
            if ($app.SourceType -eq 'Android') { if ($all) { $title = 'All new photos and videos' } else { $title = 'The photos and videos that fit' } }
            else { if ($all) { $title = 'Everything new' } else { $title = 'The oldest folders that fit' } }
            $text = '{0} ({1}) not on this PC yet, in {2}.' -f (Format-Plural $rec.Files 'file' 'files'), (Format-Bytes $rec.Bytes), (Format-Plural $rec.Rows.Count 'folder' 'folders')
            $extra = 'Takes ' + (Format-Eta ($rec.Bytes / [math]::Max([double] 1MB, [double] $app.Speed)))
            if ($app.Free -ge 0) { $extra += ('. Leaves {0} free on {1}' -f (Format-Bytes ([math]::Max([int64] 0, [int64] ($app.Free - $rec.Bytes)))), $drive) }
            if (-not $all) { $text += (' {0} would not fit this time - copy these, free up the {1}, then come back for the rest.' -f (Format-Plural $rec.Skipped 'other folder' 'other folders'), $noun) }
            $badge = ''; if (-not $badgeUsed) { $badge = 'Recommended' }
            [void] $ui.ChoiceTiles.Children.Add((New-Tile -Action 'choice:Suggested' -Icon ([string] [char] 0xE735) -Title $title -Text $text -Extra $extra -Badge $badge -Wide -Selected:($app.Choice -eq 'Suggested')))
            if ($app.Choice -eq 'Suggested') { Set-Selection ([string[]] @($rec.Rows | ForEach-Object { $_.Name })) }
        }
        elseif ($rec.Candidates -gt 0) {
            $smallest = ($pending | Measure-Object -Property BytesToCopy -Minimum).Minimum
            [void] $ui.ChoiceTiles.Children.Add((New-InfoCard -Icon ([string] [char] 0xE7BA) -Title ('Not enough space on {0} for any whole folder' -f $drive) -Text ('The smallest folder still to copy needs {0}; {1} is free. Pick another drive, or free up space on this PC.' -f (Format-Bytes $smallest), (Format-Bytes ([math]::Max([int64] 0, [int64] $app.Free)))) -ButtonText 'Pick another place' -ButtonAction 'goto:Dest'))
        }
    }
    [void] $ui.ChoiceTiles.Children.Add((& $custom ('{0} found. Tick the ones you want.' -f (Format-Plural $app.Rows.Count 'folder' 'folders'))))
    Update-ConvertTip
}

function Show-FilesSummary {
    # Files mode has nothing to choose: show what the copy will do.
    $ui.ChoiceTiles.Children.Clear()
    $ui.ConvertTip.Visibility = 'Collapsed'
    $row = @($app.Rows) | Select-Object -First 1
    if (-not $row -or -not $row.Scanned) { return }
    $s = $app.Summaries[$row.Name]
    $target = Get-DestTarget
    if ($s.Error) {
        [void] $ui.ChoiceTiles.Children.Add((New-InfoCard -Icon ([string] [char] 0xE7BA) -Title 'This folder could not be read' -Text ([string] $s.Error) -ButtonText 'Pick another folder' -ButtonAction 'goto:Connect'))
        return
    }
    if ($s.Files -eq 0) {
        [void] $ui.ChoiceTiles.Children.Add((New-InfoCard -Icon ([string] [char] 0xE946) -Title 'This folder is empty' -Text 'There is nothing in it to copy.' -Tone 'blue' -ButtonText 'Pick another folder' -ButtonAction 'goto:Connect'))
        return
    }
    $card = New-Object System.Windows.Controls.Border
    $card.Style = $window.FindResource('Card'); $card.Padding = '0'
    $stack = New-Object System.Windows.Controls.StackPanel
    $types = @($s.Types | Select-Object -First 4 | ForEach-Object { '{0} {1}' -f (Format-Count $_.Count), $_.Ext.TrimStart('.') }) -join ', '
    [void] $stack.Children.Add((New-FactRow -Icon ([string] [char] 0xF12B) -Label 'The folder' -Value ('{0}: {1}, {2}' -f $row.Name, (Format-Plural $s.Files 'file' 'files'), (Format-Bytes $s.Bytes)) -Detail $types -Accent '#B45309' -AccentBack '#FEF3C7'))
    if ($null -ne $s.PresentFiles) {
        if ($row.FilesToCopy -gt 0) {
            $eta = Format-Eta ($row.BytesToCopy / [math]::Max([double] 1MB, [double] $app.Speed))
            [void] $stack.Children.Add((New-FactRow -Icon ([string] [char] 0xE8C8) -Label 'To copy' -Value ('{0} ({1})' -f (Format-Plural $row.FilesToCopy 'file' 'files'), (Format-Bytes $row.BytesToCopy)) -Detail ('Takes {0}.' -f $eta)))
        }
        else {
            [void] $stack.Children.Add((New-FactRow -Icon ([string] [char] 0xE73E) -Label 'To copy' -Value 'Nothing - everything is already there' -Detail 'The next steps check every file.' -Accent '#15803D' -AccentBack '#DCFCE7'))
        }
        if ($s.PresentFiles -gt 0) {
            [void] $stack.Children.Add((New-FactRow -Icon ([string] [char] 0xE73E) -Label 'Already there' -Value (Format-Plural $s.PresentFiles 'file' 'files') -Detail ('Already in ' + (Format-ShortPath $target) + ' with the same name and size, so not copied again.') -Accent '#15803D' -AccentBack '#DCFCE7'))
        }
    }
    else {
        [void] $stack.Children.Add((New-FactRow -Icon ([string] [char] 0xE895) -Label 'To copy' -Value 'Comparing with the destination...' -Detail $target))
    }
    if ($s.Skipped -gt 0) {
        [void] $stack.Children.Add((New-FactRow -Icon ([string] [char] 0xE7BA) -Label 'Left out' -Value (Format-Plural $s.Skipped 'folder could not be opened' 'folders could not be opened') -Detail 'Windows did not allow reading them (no permission). Everything else is copied.' -Accent $AMBER -AccentBack '#FEF3C7'))
    }
    $last = $stack.Children[$stack.Children.Count - 1]
    $last.BorderThickness = '0'
    $card.Child = $stack
    [void] $ui.ChoiceTiles.Children.Add($card)
}

function Update-ConvertTip {
    # Lots of JPGs and next to no HEIC from an iPhone means it converts while sending
    # ("Transfer to Mac or PC: Automatic") - worth saying before anything is copied.
    if ($app.SourceType -ne 'iPhone' -or $DemoPhone) { $ui.ConvertTip.Visibility = 'Collapsed'; return }
    $jpg = 0; $heic = 0
    foreach ($s in $app.Summaries.Values) {
        foreach ($t in $s.Types) {
            if ($t.Ext -in '.JPG', '.JPEG') { $jpg += $t.Count }
            elseif ($t.Ext -in '.HEIC', '.HEIF') { $heic += $t.Count }
        }
    }
    if ($jpg -ge 50 -and $jpg -gt 5 * $heic) { $ui.ConvertTip.Visibility = 'Visible' } else { $ui.ConvertTip.Visibility = 'Collapsed' }
}

function Update-SpaceCard {
    param($Stats)
    if (-not $app.Dest -or $app.Total -le 0 -or $app.Free -lt 0) { $ui.SpaceCard.Visibility = 'Collapsed'; return }
    $ui.SpaceCard.Visibility = 'Visible'
    $toCopy = [int64] $Stats.ToCopy
    $used = [double] ($app.Total - $app.Free)
    $need = [double] [math]::Min([int64] $toCopy, [int64] $app.Free)
    $ui.SpaceUsed.Width = New-Object System.Windows.GridLength ([math]::Max(0.001, $used)), 'Star'
    $ui.SpaceNeed.Width = New-Object System.Windows.GridLength ([math]::Max(0.0, $need)), 'Star'
    $ui.SpaceFree.Width = New-Object System.Windows.GridLength ([math]::Max(0.001, $app.Free - $need)), 'Star'
    if ($Stats.Fits) { Set-Color $ui.SpaceNeedFill 'Background' '#2563EB' } else { Set-Color $ui.SpaceNeedFill 'Background' '#DC2626' }
    $text = '{0} has {1} free of {2}' -f [System.IO.Path]::GetPathRoot($app.Dest), (Format-Bytes $app.Free), (Format-Bytes $app.Total)
    if ($toCopy -gt 0) {
        if ($Stats.Fits) { $text += $DOT + ('this needs {0} (blue)' -f (Format-Bytes $toCopy)) }
        else { $text += $DOT + ('this needs {0} - {1} more than is free' -f (Format-Bytes $toCopy), (Format-Bytes ($toCopy - $app.Free))) }
    }
    $ui.SpaceText.Text = $text
    if ($Stats.Fits) { Set-Color $ui.SpaceText 'Foreground' '#475569' } else { Set-Color $ui.SpaceText 'Foreground' $RED }
}

function Update-ChoosePage {
    if ($app.Page -ne 'Choose') { return }
    Update-ScanCard
    $listMode = ($app.ChooseList -and $app.Mode -ne 'Files')
    if ($listMode) { $ui.ChoiceView.Visibility = 'Collapsed'; $ui.ListView.Visibility = 'Visible' }
    else {
        $ui.ChoiceView.Visibility = 'Visible'; $ui.ListView.Visibility = 'Collapsed'
        if ($app.ChoiceDirty) {
            $app.ChoiceDirty = $false
            if ($app.Mode -eq 'Files') { Show-FilesSummary } else { Show-ChoiceTiles }
        }
    }
    $stats = Get-SelectionStats
    Update-SpaceCard $stats

    $text = ''
    $enabled = $false
    $next = 'Continue'
    if ($app.Mode -eq 'Files') {
        $row = @($app.Rows) | Select-Object -First 1
        $enabled = $app.ScanDone -and $row -and $row.Scanned -and $row.CanSelect -and $stats.Fits -and $stats.Count -gt 0 -and ($null -ne $app.Summaries[$row.Name].PresentFiles)
        if ($app.ScanDone -and -not $stats.Fits) { $text = 'Not enough free space there. Go back and pick another drive.' }
    }
    elseif ($listMode) {
        if ($stats.Count -eq 0) { $text = 'Tick the folders to copy.' }
        else {
            $text = '{0}{1}{2} to copy' -f (Format-Plural $stats.Count 'folder' 'folders'), $DOT, (Format-Bytes $stats.ToCopy)
            if (-not $stats.AllScanned) { $text = 'Some ticked folders are still being read.' }
            elseif (-not $stats.Fits) { $text = 'That does not fit in the free space. Untick some folders.' }
        }
        $enabled = ($stats.Count -gt 0) -and $stats.Fits -and $stats.AllScanned
    }
    else {
        $enabled = [bool] $app.Choice -and $app.Choice -ne 'Custom' -and $stats.Count -gt 0 -and $stats.Fits
        if (-not $app.ScanDone) { $text = '' }
        elseif (-not $app.Choice -or $app.Choice -eq 'Custom') { $text = 'Pick one of the choices above.' }
        if ($app.Choice -eq 'Custom') { $enabled = ($stats.Count -gt 0) -and $stats.Fits -and $stats.AllScanned }
    }
    Set-Footer -Next $next -NextEnabled $enabled -Text $text
}

function Select-Choice {
    param([string] $Value)
    switch ($Value) {
        'Custom' {
            # Start the list from the suggestion, so it only needs adjusting.
            if ($app.Choice -ne 'Custom' -and @($app.Rows | Where-Object { $_.Selected }).Count -eq 0 -and $app.ScanDone) { Select-Recommended }
            $app.Choice = 'Custom'
            $app.ChooseList = $true
            Update-ChoosePage
            return
        }
        'Suggested' { Select-Recommended }
        'Resume'    { Set-Selection ([string[]] @(Get-ResumeFolders)) }
        'CheckAll'  { Set-Selection ([string[]] @($app.Rows | Where-Object { $_.Scanned -and $_.CanSelect -and $_.FileCount -gt 0 } | ForEach-Object { $_.Name })) }
    }
    $app.Choice = $Value
    $app.ChoiceDirty = $true
    $stats = Get-SelectionStats
    if ($stats.Count -gt 0 -and $stats.Fits) { Show-Step 'After' } else { Update-ChoosePage }
}

function Confirm-Choice {
    if ($app.Mode -eq 'Files') { $app.Choice = 'All' }
    elseif ($app.ChooseList) { $app.Choice = 'Custom' }
    $stats = Get-SelectionStats
    if ($stats.Count -eq 0 -or -not $stats.Fits -or -not $stats.AllScanned) { return }
    Show-Step 'After'
}

# ---------------------------------------------------------------------------
# originals: keep them, or remove them once proven
# ---------------------------------------------------------------------------

function Enter-After {
    $ui.AfterTiles.Children.Clear()
    switch ($app.SourceType) {
        'iPhone' {
            $ui.AfterHeading.Text = 'And the photos on the iPhone?'
            $keep = @('Keep them on the iPhone', 'Only copy. Nothing changes on the iPhone.')
            $remove = @('Free up space on the iPhone', 'After the check, every photo and video that is proven to be safely on this PC is removed from the iPhone.')
        }
        'Android' {
            $ui.AfterHeading.Text = 'And the files on the phone?'
            $keep = @('Keep them on the phone', 'Only copy. Nothing changes on the phone.')
            $remove = @('Free up space on the phone', 'After the check, every file that is proven to be safely on this PC is removed from the phone.')
        }
        default {
            $ui.AfterHeading.Text = 'And the original files?'
            $keep = @('Keep them (copy)', ('Only copy. Nothing changes in {0}.' -f (Get-UnitName)))
            $remove = @('Remove them (move)', 'After the check, every file that is proven to be safely copied goes to the Recycle Bin. Emptied folders are removed too.')
        }
    }
    [void] $ui.AfterTiles.Children.Add((New-Tile -Action 'after:Keep' -Icon ([string] [char] 0xE8C8) -Title $keep[0] -Text $keep[1] -Selected:($app.After -eq 'Keep')))
    [void] $ui.AfterTiles.Children.Add((New-Tile -Action 'after:Remove' -Icon ([string] [char] 0xE74D) -Title $remove[0] -Text $remove[1] -Extra 'You confirm before anything is removed.' -Accent '#B91C1C' -AccentBack '#FEE2E2' -Selected:($app.After -eq 'Remove')))
    Set-Footer -Next 'Continue' -NextEnabled ([bool] $app.After)
}

function Select-After {
    param([string] $Value)
    $app.After = $Value
    Show-Step 'Review'
}

# ---------------------------------------------------------------------------
# start: every answer once more, each one changeable
# ---------------------------------------------------------------------------

function Enter-Review {
    $ui.ReviewRows.Children.Clear()
    Update-FreeSpace -Force
    $stats = Get-SelectionStats

    switch ($app.SourceType) {
        'iPhone'  { $icon = [char] 0xE8EA; $detail = [string] $app.SourceLabel }
        'Android' { $icon = [char] 0xE8EA; $detail = [string] $app.SourceLabel }
        default   { $icon = [char] 0xF12B; $detail = $app.FolderPath }
    }
    [void] $ui.ReviewRows.Children.Add((New-FactRow -Icon ([string] $icon) -Label 'From' -Value (Get-SourceTitle) -Detail $detail -Change 'Source'))

    $freeText = Get-FreeText $app.Dest
    [void] $ui.ReviewRows.Children.Add((New-FactRow -Icon ([string] [char] 0xF12B) -Label 'Save to' -Value (Get-DestTarget) -Detail $freeText -Change 'Dest'))

    if ($stats.ToCopyFiles -gt 0) { $value = '{0} ({1}) to copy' -f (Format-Plural $stats.ToCopyFiles 'file' 'files'), (Format-Bytes $stats.ToCopy) }
    else { $value = 'Nothing new to copy - every file gets checked' }
    $parts = @()
    if ($app.Mode -ne 'Files') {
        $names = ($stats.Names | Select-Object -First 4) -join ', '
        if ($stats.Count -gt 4) { $names += (' and {0} more' -f ($stats.Count - 4)) }
        $parts += $names
    }
    $already = $stats.Files - $stats.ToCopyFiles
    if ($already -gt 0) { $parts += ('{0} already there and skipped' -f (Format-Plural $already 'file is' 'files are')) }
    [void] $ui.ReviewRows.Children.Add((New-FactRow -Icon ([string] [char] 0xE8FD) -Label 'What' -Value $value -Detail ($parts -join '. ') -Change 'Choose'))

    if ($app.After -eq 'Remove') {
        $value = 'Remove them after the check'
        if ($app.SourceType -eq 'Folder') { $value = 'Move: remove them after the check' }
        [void] $ui.ReviewRows.Children.Add((New-FactRow -Icon ([string] [char] 0xE74D) -Label 'Originals' -Value $value -Detail 'Only files proven to be safely copied. You confirm first.' -Change 'After' -Accent '#B91C1C' -AccentBack '#FEE2E2' -Last))
    }
    else {
        $value = 'Keep them where they are'
        if (Test-Phone) { $value = 'Keep them on ' + (Get-SourceWord) }
        [void] $ui.ReviewRows.Children.Add((New-FactRow -Icon ([string] [char] 0xE8C8) -Label 'Originals' -Value $value -Detail 'Nothing is removed.' -Change 'After' -Last))
    }

    $note = ''
    if ($stats.ToCopy -gt 0) { $note = 'Takes {0}, then every file is checked. ' -f (Format-Eta ($stats.ToCopy / [math]::Max([double] 1MB, [double] $app.Speed))) }
    $note += 'This PC will not go to sleep meanwhile.'
    if ($app.SourceType -eq 'iPhone') { $note += ' Keep the iPhone plugged in and unlocked.' }
    elseif ($app.SourceType -eq 'Android') { $note += ' Keep the phone plugged in and unlocked.' }
    $ui.ReviewNote.Text = $note
    Set-Color $ui.ReviewNoteCard 'Background' '#EFF6FF'; Set-Color $ui.ReviewNoteCard 'BorderBrush' '#BFDBFE'; Set-Color $ui.ReviewNote 'Foreground' '#1E3A8A'
    if (-not $stats.Fits) {
        $ui.ReviewNote.Text = ('There is not enough free space on {0} for this. Change where to save, or what to copy.' -f [System.IO.Path]::GetPathRoot($app.Dest))
        Set-Color $ui.ReviewNoteCard 'Background' '#FEF2F2'; Set-Color $ui.ReviewNoteCard 'BorderBrush' '#FECACA'; Set-Color $ui.ReviewNote 'Foreground' '#991B1B'
    }
    $next = 'Start copying'
    if ($stats.ToCopyFiles -le 0) { $next = 'Start checking' }
    Set-Footer -Next $next -NextEnabled ($stats.Fits -and $stats.Count -gt 0)
}

function Start-Transfer {
    $stats = Get-SelectionStats
    if ($stats.Count -eq 0 -or -not $stats.Fits) { return }
    $settings.Dest[$app.SourceType] = $app.Dest
    Save-Settings
    if ($stats.ToCopyFiles -le 0) { Start-Check -Names $stats.Names -Full $false }
    else { Start-Copy -Names $stats.Names }
}

# ---------------------------------------------------------------------------
# copy and check
# ---------------------------------------------------------------------------

function Set-Phase {
    param([string] $Phase)
    $active = @('#DBEAFE', '#1D4ED8'); $done = @('#DCFCE7', '#166534'); $todo = @('#F1F5F9', '#94A3B8')
    switch ($Phase) {
        'Copy'  { $c = $active; $k = $todo; $ui.PhaseCopyText.Text = '1  Copy'; $ui.PhaseCheckText.Text = '2  Check' }
        'Check' { $c = $done; $k = $active; $ui.PhaseCopyText.Text = $CHECK + '  Copy'; $ui.PhaseCheckText.Text = '2  Check' }
    }
    Set-Color $ui.PhaseCopy 'Background' $c[0]; Set-Color $ui.PhaseCopyText 'Foreground' $c[1]
    Set-Color $ui.PhaseCheck 'Background' $k[0]; Set-Color $ui.PhaseCheckText 'Foreground' $k[1]
}

function Set-WorkFooter {
    if ($app.CopyRunning) {
        $pause = 'Pause'; if ($sync.Pause) { $pause = 'Resume' }
        Set-Footer -Back '' -Next 'Stop' -NextStyle 'Secondary' -Alt $pause
    }
    elseif ($app.CheckRunning) { Set-Footer -Back '' -Next 'Stop' -NextStyle 'Secondary' }
    else { Set-Footer -Back 'Back to the summary' -Next 'Continue copying' }
}

function Start-Copy {
    param([string[]] $Names)
    if (-not $Names -or $Names.Count -eq 0) { return }
    if (Test-Busy) { return }
    $app.CopyFolders = $Names
    $app.CopyRunning = $true
    $app.CopyDone = $null; $app.CheckDone = $null; $app.CheckStopped = ''; $app.DeleteDone = $null
    $app.CopyStats = @{ Copied = 0; Already = 0; Failed = 0 }
    $ui.WorkHeading.Text = 'Copying'
    if (Test-Phone) { $ui.WorkSubText.Text = ('Keep {0} plugged in and unlocked. This PC will not go to sleep meanwhile.' -f (Get-SourceWord)) }
    else { $ui.WorkSubText.Text = 'This PC will not go to sleep meanwhile. You can pause or stop at any time - nothing copied so far is lost.' }
    Set-Phase 'Copy'
    $ui.WorkPercent.Text = '0%'; $ui.WorkBar.Value = 0
    $ui.WorkAmounts.Text = 'Getting ready...'; $ui.WorkRate.Text = ''; $ui.WorkCurrent.Text = ''
    $ui.WorkStats.Visibility = 'Visible'
    $ui.StatCopied.Text = 'Copied 0'; $ui.StatAlready.Text = 'Already there 0'; $ui.StatFailed.Text = 'Problems 0'
    $ui.WaitingBanner.Visibility = 'Collapsed'
    $window.TaskbarItemInfo.ProgressState = 'Normal'
    $sync.Pause = $false
    Show-Step 'Work'
    Set-WorkFooter
    if ($sync.Busy) { $sync.Cancel = $true }   # stop reading the remaining folders
    Send-Command @{ Name = 'Copy'; Folders = [string[]] $Names }
    Write-UiLog ("copy started: {0}" -f ($Names -join ', '))
}

function Update-WorkLive {
    $p = $sync.Progress
    if ($app.CopyRunning -and $p.Phase -eq 'Copy') { $verb = 'copying' }
    elseif ($app.CheckRunning -and $p.Phase -eq 'Verify') { $verb = 'checking' }
    else { return }
    $total = [double] $p.BytesTotal
    $done = [double] $p.BytesDone + [double] $p.CurrentBytes
    $fraction = 0.0
    if ($total -gt 0) { $fraction = [math]::Min(1.0, $done / $total) }
    elseif ([int64] $p.FilesTotal -gt 0) { $fraction = [double] $p.FilesDone / [double] $p.FilesTotal }
    $ui.WorkPercent.Text = '{0}%' -f [int] [math]::Floor($fraction * 100)
    $ui.WorkBar.Value = $fraction * 1000
    $window.TaskbarItemInfo.ProgressValue = $fraction
    $fileNo = Format-Count ([math]::Min([int64] $p.FilesDone + 1, [int64] $p.FilesTotal))
    if ($verb -eq 'checking' -and $p.Step -ne 'Checking every file') {
        $ui.WorkAmounts.Text = [string] $p.Step
        $ui.WorkRate.Text = ''
        if ($p.CurrentFolder) { $ui.WorkCurrent.Text = 'Folder ' + $p.CurrentFolder }
    }
    else {
        $ui.WorkAmounts.Text = '{0} of {1}{2}file {3} of {4}' -f (Format-Bytes $done), (Format-Bytes $total), $DOT, $fileNo, (Format-Count ([int64] $p.FilesTotal))
        $rate = ''
        if ([double] $p.Speed -gt 0) { $rate = (Format-Bytes ([double] $p.Speed)) + '/s' }
        if ([double] $p.Eta -ge 0) { $rate += $DOT + (Format-Eta ([double] $p.Eta)) + ' left' }
        if ($p.Paused) { $rate = 'Paused - press Resume to carry on' }
        if ($p.Waiting) { $rate = ('Waiting for {0}...' -f (Get-SourceWord)) }
        $ui.WorkRate.Text = $rate
        $current = $p.Current
        if ($current) {
            $step = ''
            if ($p.Step -and $p.Step -ne 'Checking every file') { $step = ' - ' + $p.Step }
            $ui.WorkCurrent.Text = '{0}  ({1}, {2}){3}' -f $current.Name, $current.Folder, (Format-Bytes ([double] $current.Size)), $step
        }
    }
    $title = 'Smart Transfer - {0} {1}%' -f $verb, [int] [math]::Floor($fraction * 100)
    if ($window.Title -ne $title) { $window.Title = $title }
}

function Complete-Copy {
    param($Result)
    $app.CopyRunning = $false
    $app.CopyDone = $Result
    $window.Title = 'Smart Transfer'
    if ($Result.Seconds -gt 30 -and $Result.Speed -gt 1MB) { $app.Speed = [double] $Result.Speed; $settings.Speed[$app.SourceType] = $app.Speed; Save-Settings }
    $ui.StatCopied.Text = 'Copied ' + (Format-Count $Result.Copied)
    $ui.StatAlready.Text = 'Already there ' + (Format-Count $Result.Already)
    $ui.StatFailed.Text = 'Problems ' + (Format-Count @($Result.Failed).Count)
    $ui.WorkCurrent.Text = ''
    if ($Result.Cancelled -or $Result.StopReason) {
        $window.TaskbarItemInfo.ProgressState = 'Paused'
        $ui.WorkRate.Text = ''
        $ui.WorkHeading.Text = 'Copying stopped'
        if ($Result.StopReason) { $ui.WorkSubText.Text = $Result.StopReason }
        else { $ui.WorkSubText.Text = ('{0} copied before stopping. Everything copied so far is complete and safe. Press Continue copying to carry on.' -f (Format-Plural $Result.Copied 'file was' 'files were')) }
        Set-WorkFooter
        Update-StageList
        [System.Media.SystemSounds]::Exclamation.Play()
        return
    }
    $window.TaskbarItemInfo.ProgressState = 'None'
    $ui.WorkPercent.Text = '100%'; $ui.WorkBar.Value = 1000
    # Straight on to the check - that is what makes the copy trustworthy.
    Start-Check -Names $app.CopyFolders -Full $false
}

function Start-Check {
    param([string[]] $Names, [bool] $Full)
    if (-not $Names -or $Names.Count -eq 0) { return }
    $app.CheckFolders = $Names
    $app.CheckRunning = $true
    $app.CheckDone = $null; $app.CheckStopped = ''; $app.CheckFull = $Full; $app.CheckSummaries = @{}
    $ui.ProblemsList.Items.Clear()
    if ($Full) {
        $ui.WorkHeading.Text = 'Full check: reading every file again'
        $ui.WorkSubText.Text = ('Every file is read from {0} again and compared, byte for byte, with its copy.' -f (Get-SourceWord))
    }
    else {
        $ui.WorkHeading.Text = 'Checking every file'
        $ui.WorkSubText.Text = ('Each file from {0} is compared with its copy: name, size, and a digital fingerprint of the content.' -f (Get-SourceWord))
    }
    Set-Phase 'Check'
    if (-not $app.CopyDone) { $ui.WorkStats.Visibility = 'Collapsed' }
    $ui.WorkPercent.Text = '0%'; $ui.WorkBar.Value = 0
    $ui.WorkAmounts.Text = 'Getting ready...'; $ui.WorkRate.Text = ''; $ui.WorkCurrent.Text = ''
    $window.TaskbarItemInfo.ProgressState = 'Normal'
    Show-Step 'Work'
    Set-WorkFooter
    if ($sync.Busy) { $sync.Cancel = $true }
    Send-Command @{ Name = 'Verify'; Folders = [string[]] $Names; Full = $Full }
    Write-UiLog ("check started (full={0}): {1}" -f $Full, ($Names -join ', '))
}

function Update-CheckRow {
    param($Summary)
    $app.CheckSummaries[$Summary.Name] = $Summary
    if ($Summary.Ok) {
        $app.VerifiedOk[$Summary.Name] = $Summary
        $app.PartialOk.Remove($Summary.Name)
    }
    else {
        $app.VerifiedOk.Remove($Summary.Name)
        if ($Summary.DeletableFiles -gt 0) { $app.PartialOk[$Summary.Name] = $Summary } else { $app.PartialOk.Remove($Summary.Name) }
        if (-not $Summary.Readable) { [void] $ui.ProblemsList.Items.Add(('{0}   -   could not be read from {1}' -f $Summary.Name, (Get-SourceWord))) }
        foreach ($problem in $Summary.Problems) { [void] $ui.ProblemsList.Items.Add(('{0}   -   {1}' -f $problem.Name, $problem.Detail)) }
        if ($Summary.ProblemCount -gt $Summary.Problems.Count) { [void] $ui.ProblemsList.Items.Add(('... and {0} more in the report' -f ($Summary.ProblemCount - $Summary.Problems.Count))) }
    }
}

function Complete-Check {
    param($Result)
    $app.CheckRunning = $false
    $app.CheckDone = $Result
    $app.Report = [string] $Result.Report
    $window.TaskbarItemInfo.ProgressState = 'None'
    $window.Title = 'Smart Transfer'
    foreach ($n in $app.CheckFolders) { if ($app.Summaries[$n]) { Update-Row $app.Summaries[$n] } }
    if ($Result.AllOk) { [System.Media.SystemSounds]::Asterisk.Play() } else { [System.Media.SystemSounds]::Exclamation.Play() }
    Show-Step 'Result'
}

function Invoke-WorkNext {
    if ($app.CopyRunning) {
        if (Confirm-Action 'Stop copying? Everything copied so far is complete and kept. You can continue later from where it stopped.') {
            $sync.Cancel = $true; $sync.Pause = $false
            $ui.NextButton.IsEnabled = $false; $ui.AltButton.IsEnabled = $false
            $ui.WorkRate.Text = 'Stopping...'
        }
    }
    elseif ($app.CheckRunning) {
        if (Confirm-Action 'Stop the check? Nothing can be removed until a check has finished.') {
            $sync.Cancel = $true
            $ui.NextButton.IsEnabled = $false
            $ui.WorkRate.Text = 'Stopping...'
        }
    }
    else { Start-Copy -Names $app.CopyFolders }
}

function Switch-Pause {
    if (-not $app.CopyRunning) { return }
    if ($sync.Pause) { $sync.Pause = $false; $window.TaskbarItemInfo.ProgressState = 'Normal' }
    else { $sync.Pause = $true; $window.TaskbarItemInfo.ProgressState = 'Paused'; $ui.WorkRate.Text = 'Pausing after the current file...' }
    Set-WorkFooter
}

# ---------------------------------------------------------------------------
# the result of the check
# ---------------------------------------------------------------------------

function Get-DeletableFolders {
    return @($app.CheckFolders | Where-Object { $app.VerifiedOk.ContainsKey($_) -or $app.PartialOk.ContainsKey($_) })
}

function Set-Verdict {
    param([string] $Tone)
    switch ($Tone) {
        'good'  { Set-Color $ui.VerdictIconBack 'Background' '#16A34A'; $ui.VerdictIcon.Text = [string] [char] 0xE73E }
        'warn'  { Set-Color $ui.VerdictIconBack 'Background' '#D97706'; $ui.VerdictIcon.Text = [string] [char] 0xE7BA }
    }
}

function Enter-Result {
    $deletable = @(Get-DeletableFolders)
    $total = [int64] 0; $ok = [int64] 0
    foreach ($s in $app.CheckSummaries.Values) { $total += $s.PhoneFiles; $ok += $s.OkFiles }
    $ui.ProblemsCard.Visibility = 'Collapsed'
    $ui.OpenReportButton.Visibility = 'Visible'; $ui.OpenReportButton.IsEnabled = [bool] $app.Report
    $ui.FullCheckButton.Visibility = 'Visible'
    $ui.FreeAnywayButton.Visibility = 'Collapsed'
    $target = Get-DestTarget
    $noun = 'iPhone'; if ($app.SourceType -eq 'Android') { $noun = 'phone' }

    if ($app.CheckStopped) {
        Set-Verdict 'warn'
        $ui.ResultHeading.Text = 'The check did not finish'
        $ui.ResultText.Text = $app.CheckStopped + ' Nothing can be removed until a check has finished.'
        $ui.OpenReportButton.Visibility = 'Collapsed'
        $app.ResultNext = 'Recheck'; $app.ResultAlt = 'Done'
        Set-Footer -Back '' -Next 'Check again' -Alt 'Finish for now'
        return
    }
    if ($app.CheckDone.AllOk) {
        Set-Verdict 'good'
        $ui.ResultHeading.Text = ('All {0} are safely copied' -f (Format-Plural $ok 'file' 'files'))
        $how = 'Every copy was read back and matched the fingerprint taken while copying.'
        if ($app.CheckFull) { $how = ('Every file was read from {0} again and matched its copy byte for byte.' -f (Get-SourceWord)) }
        $ui.ResultText.Text = ('They are in {0}. {1}' -f (Format-ShortPath $target 70), $how)
        if ($app.After -eq 'Remove' -and $deletable.Count -gt 0) {
            $app.ResultNext = 'Free'; $app.ResultAlt = 'Done'
            Set-Footer -Back '' -Next 'Next: remove the originals' -Alt 'Keep them after all'
        }
        else {
            $app.ResultNext = 'Done'; $app.ResultAlt = ''
            Set-Footer -Back '' -Next 'Finish'
            if ($deletable.Count -gt 0) {
                if ($app.SourceType -eq 'Folder') { $ui.FreeAnywayButton.Content = 'Remove the originals after all (move)' }
                else { $ui.FreeAnywayButton.Content = ('Free up space on the {0} after all' -f $noun) }
                $ui.FreeAnywayButton.Visibility = 'Visible'
            }
        }
        return
    }
    Set-Verdict 'warn'
    $bad = $total - $ok
    $ui.ResultHeading.Text = ('{0} need attention' -f (Format-Plural $bad 'file' 'files'))
    $text = '{0} of {1} files are safely copied to {2}. The others are listed below.' -f (Format-Count $ok), (Format-Count $total), (Format-ShortPath $target 70)
    if (Test-Phone) { $text += (' If the {0} stopped sending files, unplug it, plug it back in and unlock it before trying again.' -f $noun) }
    $ui.ResultText.Text = $text
    if ($ui.ProblemsList.Items.Count -gt 0) { $ui.ProblemsCard.Visibility = 'Visible' }
    $app.ResultNext = 'Fix'
    if ($app.After -eq 'Remove' -and $deletable.Count -gt 0) { $app.ResultAlt = 'Free'; Set-Footer -Back '' -Next 'Try again' -Alt 'Remove the safe ones' }
    else { $app.ResultAlt = 'Done'; Set-Footer -Back '' -Next 'Try again' -Alt 'Finish for now' }
}

function Invoke-ResultAction {
    param([string] $Action)
    switch ($Action) {
        'Free'    { Show-Step 'Free' }
        'Done'    { Show-Step 'Done' }
        'Fix'     { Start-Copy -Names ([string[]] @($app.CheckFolders | Where-Object { -not $app.VerifiedOk.ContainsKey($_) })) }
        'Recheck' { Start-Check -Names $app.CheckFolders -Full $app.CheckFull }
    }
}

# ---------------------------------------------------------------------------
# removing the originals
# ---------------------------------------------------------------------------

function Enter-Free {
    $app.DeleteRows.Clear()
    $app.DeleteDone = $null
    foreach ($n in (Get-DeletableFolders | Sort-Object)) {
        $r = New-Object IPhoneTransferApp.Row
        $r.Name = $n
        if ($app.VerifiedOk.ContainsKey($n)) {
            $s = $app.VerifiedOk[$n]
            $r.Files = Format-Count $s.OkFiles; $r.FileCount = [int64] $s.OkFiles
            $r.Size = Format-Bytes $s.PhoneBytes; $r.Bytes = [int64] $s.PhoneBytes
            $r.Status = $CHECK + ' Every file checked'; $r.StatusColor = $GREEN
        }
        else {
            $s = $app.PartialOk[$n]
            $r.Files = Format-Count $s.DeletableFiles; $r.FileCount = [int64] $s.DeletableFiles
            $r.Size = Format-Bytes $s.DeletableBytes; $r.Bytes = [int64] $s.DeletableBytes
            $r.Status = ('Partly: {0} stay (files that did not match{1})' -f (Format-Plural $s.KeptFiles 'file' 'files'), $(if ($app.Mode -eq 'Photos') { ', and the photos they belong to' } else { '' })); $r.StatusColor = $AMBER
        }
        $r.Selected = $true
        $app.DeleteRows.Add($r)
    }
    $target = Get-DestTarget
    switch ($app.SourceType) {
        'iPhone' {
            $ui.FreeHeading.Text = 'Free up space on the iPhone'
            $ui.FreeWarnTitle.Text = 'Removing from the iPhone cannot be undone from this PC'
            $ui.FreeWarnText.Text = 'The copies on this PC are not touched. If you use iCloud Photos, removing photos here also removes them from iCloud and your other Apple devices - check Settings > [your name] > iCloud > Photos on the iPhone first. Photos added after the check are never removed.'
            $ui.DeleteConfirmText.Text = 'I understand these files will be removed from my iPhone. Their copies stay on this PC.'
        }
        'Android' {
            $ui.FreeHeading.Text = 'Free up space on the phone'
            $ui.FreeWarnTitle.Text = 'Removing from the phone cannot be undone from this PC'
            $ui.FreeWarnText.Text = 'The copies on this PC are not touched. Photos already backed up to Google Photos stay in your Google Photos account. Files added to the phone after the check are never removed.'
            $ui.DeleteConfirmText.Text = 'I understand these files will be removed from my phone. Their copies stay on this PC.'
        }
        default {
            $ui.FreeHeading.Text = 'Remove the originals'
            $ui.FreeWarnTitle.Text = 'The originals go to the Recycle Bin'
            $ui.FreeWarnText.Text = ('The copies in {0} are not touched. Files added or changed after the check are never removed. Folders left empty are removed too.' -f (Format-ShortPath $target 70))
            $ui.DeleteConfirmText.Text = ('I understand the original files will be moved to the Recycle Bin. Their copies stay in {0}.' -f (Format-ShortPath $target 70))
        }
    }
    $ui.FreeSubText.Text = 'Only files that were checked and matched are removed.'
    if ($app.PartialOk.Count -gt 0) { $ui.FreeSubText.Text += ' Files that did not match stay where they are.' }
    $ui.FreeFoldersExpander.Visibility = 'Visible'
    if ($app.DeleteRows.Count -le 1) { $ui.FreeFoldersExpander.Visibility = 'Collapsed' }
    $ui.FreeFoldersExpander.IsExpanded = $false
    $ui.DeleteConfirmCheck.IsChecked = $false
    $ui.DeleteConfirmCheck.IsEnabled = $true
    $ui.DeleteConfirmCheck.Visibility = 'Visible'
    $ui.DeleteProgressCard.Visibility = 'Collapsed'
    Update-DeleteSelection
}

function Update-DeleteSelection {
    if ($app.DeleteRunning -or $app.DeleteDone -or $app.Page -ne 'Free') { return }
    $selected = @($app.DeleteRows | Where-Object { $_.Selected })
    $files = [int64] 0; $bytes = [int64] 0
    foreach ($r in $selected) { $files += $r.FileCount; $bytes += $r.Bytes }
    if ($selected.Count -eq 0) {
        $ui.FreeSummary.Text = 'Nothing selected'
        $ui.FreeSummaryDetail.Text = 'Tick at least one folder below.'
        $label = 'Remove'
    }
    else {
        $ui.FreeSummary.Text = ('{0} ({1}) will be removed from {2}' -f (Format-Plural $files 'file' 'files'), (Format-Bytes $bytes), (Get-SourceWord))
        $ui.FreeSummaryDetail.Text = ('From {0}: {1}' -f (Format-Plural $selected.Count 'folder' 'folders'), ((($selected | Select-Object -First 5) | ForEach-Object { $_.Name }) -join ', '))
        if ($selected.Count -gt 5) { $ui.FreeSummaryDetail.Text += (' and {0} more' -f ($selected.Count - 5)) }
        $label = 'Remove {0}' -f (Format-Plural $files 'file' 'files')
    }
    $enabled = ($selected.Count -gt 0) -and [bool] $ui.DeleteConfirmCheck.IsChecked
    if ($ui.NextButton.Content -ne $label -or $ui.NextButton.IsEnabled -ne $enabled -or $ui.BackButton.Visibility -ne 'Visible') {
        Set-Footer -Back 'Back' -Next $label -NextEnabled $enabled -NextStyle 'Danger'
    }
}

function Start-Delete {
    $selected = @($app.DeleteRows | Where-Object { $_.Selected })
    if ($selected.Count -eq 0 -or -not $ui.DeleteConfirmCheck.IsChecked) { return }
    $files = [int64] 0; $bytes = [int64] 0
    foreach ($r in $selected) { $files += $r.FileCount; $bytes += $r.Bytes }
    $where = Get-SourceWord
    if ($app.SourceType -eq 'Folder') { $where = 'the original folder (to the Recycle Bin)' }
    $text = "Remove {0} ({1}) from {2}?`r`n`r`nEvery one of these files was checked and is safely in:`r`n{3}`r`n`r`nThis cannot be undone from this PC." -f (Format-Plural $files 'file' 'files'), (Format-Bytes $bytes), $where, (Get-DestTarget)
    if ($app.SourceType -eq 'Folder') { $text = $text.Replace('This cannot be undone from this PC.', 'They can be restored from the Recycle Bin.') }
    if (-not (Confirm-Action $text 'Remove the originals?' 'Warning')) { return }
    $app.DeleteRunning = $true
    foreach ($r in $app.DeleteRows) { $r.CanSelect = $false; if ($r.Selected) { $r.Status = 'Waiting'; $r.StatusColor = $GRAY } }
    $ui.DeleteConfirmCheck.IsEnabled = $false
    $ui.DeleteProgressCard.Visibility = 'Visible'; $ui.DeleteBar.Value = 0; $ui.DeletePercent.Text = '0%'
    $ui.DeleteStep.Text = ('Removing from {0}...' -f (Get-SourceWord)); Set-Color $ui.DeleteStep 'Foreground' '#0F172A'
    Set-Footer -Back '' -Next 'Removing...' -NextEnabled $false -NextStyle 'Danger'
    Update-StageList
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
    param($Result, [string] $Stopped = '')
    $app.DeleteRunning = $false
    $app.DeleteDone = $Result
    $app.DeleteStopped = $Stopped
    foreach ($n in @($app.DeleteRows | ForEach-Object { $_.Name })) { $app.VerifiedOk.Remove($n); $app.PartialOk.Remove($n) }
    $app.LoadedKey = ''   # the source changed: read it again next time
    if ($Result.Deleted -gt 0) { [System.Media.SystemSounds]::Asterisk.Play() }
    Show-Step 'Done'
}

# ---------------------------------------------------------------------------
# done
# ---------------------------------------------------------------------------

function Enter-Done {
    $ui.DoneFacts.Children.Clear()
    $target = Format-ShortPath (Get-DestTarget) 70
    $facts = New-Object System.Collections.ArrayList
    if ($app.CopyDone -and $app.CopyDone.Copied -gt 0) {
        [void] $facts.Add(@([char] 0xE8C8, 'Copied', ('{0} ({1})' -f (Format-Plural $app.CopyDone.Copied 'file' 'files'), (Format-Bytes $app.CopyDone.CopiedBytes)), ('Into ' + $target)))
    }
    if ($app.CheckDone) {
        $total = [int64] 0; $ok = [int64] 0
        foreach ($s in $app.CheckSummaries.Values) { $total += $s.PhoneFiles; $ok += $s.OkFiles }
        if ($app.CheckDone.AllOk) { [void] $facts.Add(@([char] 0xE73E, 'Checked', ('All {0} match' -f (Format-Plural $ok 'file' 'files')), 'Each copy was compared with its original.')) }
        else { [void] $facts.Add(@([char] 0xE7BA, 'Checked', ('{0} of {1} files match' -f (Format-Count $ok), (Format-Count $total)), 'The others are listed in the report - start again later to copy them.')) }
    }
    $d = $app.DeleteDone
    if ($d) {
        $detail = 'From ' + (Get-SourceWord) + '.'
        if ($d.Kept -gt 0) { $detail += ' ' + (Format-Plural $d.Kept 'file was' 'files were') + ' kept because they did not match, or were added or changed after the check.' }
        if ($d.Failed -gt 0) { $detail += ' ' + (Format-Plural $d.Failed 'file' 'files') + ' could not be removed - see the activity log.' }
        [void] $facts.Add(@([char] 0xE74D, 'Removed', ('{0} - {1} freed' -f (Format-Plural $d.Deleted 'file' 'files'), (Format-Bytes $d.DeletedBytes)), $detail))
    }
    for ($i = 0; $i -lt $facts.Count; $i++) {
        $f = $facts[$i]
        [void] $ui.DoneFacts.Children.Add((New-FactRow -Icon ([string] $f[0]) -Label $f[1] -Value $f[2] -Detail $f[3] -Last:($i -eq $facts.Count - 1)))
    }
    if ($facts.Count -eq 0) { $ui.DoneFacts.Parent.Visibility = 'Collapsed' } else { $ui.DoneFacts.Parent.Visibility = 'Visible' }

    Set-Color $ui.DoneIconBack 'Background' '#16A34A'; $ui.DoneIcon.Text = [string] [char] 0xE73E
    if ($app.DeleteStopped) {
        $ui.DoneHeading.Text = 'Removing stopped'
        $ui.DoneText.Text = $app.DeleteStopped
        Set-Color $ui.DoneIconBack 'Background' '#D97706'; $ui.DoneIcon.Text = [string] [char] 0xE7BA
    }
    elseif ($d -and $d.Deleted -gt 0) {
        $ui.DoneHeading.Text = 'Done - {0} freed' -f (Format-Bytes $d.DeletedBytes)
        $ui.DoneText.Text = 'Your files are safely in ' + $target + '.'
    }
    else {
        $ui.DoneHeading.Text = 'All done'
        $ui.DoneText.Text = 'Your files are in ' + $target + '.'
    }
    if ($app.SourceType -eq 'iPhone') { $ui.DoneText.Text += ' You can unplug the iPhone now.' }
    elseif ($app.SourceType -eq 'Android') { $ui.DoneText.Text += ' You can unplug the phone now.' }
    Set-Footer -Back '' -Next 'Start a new transfer' -Alt 'Open the folder'
}

function Reset-Transfer {
    # A fresh start that remembers the kind of source and where it went.
    $app.Choice = ''; $app.After = ''; $app.ChooseList = $false; $app.ChoiceDirty = $true
    $app.CopyDone = $null; $app.CheckDone = $null; $app.DeleteDone = $null; $app.CheckStopped = ''; $app.DeleteStopped = ''
    $app.LoadedKey = ''
    foreach ($r in $app.Rows) { $r.Selected = $false }
    Show-Step 'Source'
}

# ---------------------------------------------------------------------------
# events from the engine
# ---------------------------------------------------------------------------

function Invoke-EngineEvent {
    param($e)
    # While a new source is being opened, results about the previous one are stale.
    if ($app.AwaitingList -and @('FolderScanning', 'FolderScanned', 'FolderStatus', 'ScanDone', 'Session') -contains $e.Type) { return }
    switch ($e.Type) {
        'DeviceState' {
            Update-ConnectCard $e
            $app.DeviceGone = ($app.SourceKind -eq 'Device' -and $e.Kind -eq $app.SourceType -and $e.State -ne 'Ready')
        }
        'FolderList' {
            $app.AwaitingList = $false
            if ($DemoPhone) { $e.Kind = 'Device'; $e.DeviceKind = 'iPhone'; $e.Label = 'Apple iPhone\Internal Storage'; $e.Capacity = [int64] 128GB }
            $app.SourceKind = $e.Kind; $app.Mode = [string] $e.Mode; $app.SourceLabel = $e.Label; $app.Capacity = [int64] $e.Capacity
            if ($app.Mode -eq 'Files') { $app.UnitName = [string] @($e.Names)[0] }
            $app.Rows.Clear(); $app.RowByName = @{}; $app.Summaries = @{}; $app.VerifiedOk = @{}; $app.PartialOk = @{}
            foreach ($n in $e.Names) {
                $r = New-Object IPhoneTransferApp.Row
                $r.Name = $n; $r.Status = 'Waiting to be read'; $r.StatusColor = $GRAY; $r.CanSelect = $false
                $r.Dates = Get-FolderLabel $n
                if ($e.Paths -and $e.Paths[$n] -and $e.Paths[$n] -ne $n) { $r.Note = 'On the phone: ' + $e.Paths[$n] }
                $app.Rows.Add($r); $app.RowByName[$n] = $r
            }
            # The destination is checked again against this source (they must not overlap).
            if ($app.Dest) { $wanted = $app.Dest; $app.Dest = ''; [void] (Set-Destination $wanted) }
            if (-not $app.Dest) { Send-Command @{ Name = 'SetDestination'; Path = '' }; if ($app.Page -eq 'Choose') { Show-Step 'Dest' } }
            $app.Scanning = $true; $app.ScanDone = $false; $app.ChoiceDirty = $true
            Send-Command @{ Name = 'Scan'; Folders = [string[]] $e.Names }
            Update-StageList
        }
        'FolderScanning' {
            $row = $app.RowByName[$e.Name]
            if ($row) { $row.Status = 'Reading...'; $row.StatusColor = $BLUE }
        }
        'FolderScanned' { Update-Row $e; if ($app.Mode -eq 'Files') { $app.ChoiceDirty = $true } }
        'FolderStatus'  { Update-Row $e; $app.ChoiceDirty = $true }
        'ScanDone' {
            $app.Scanning = $false; $app.ScanDone = $true; $app.ChoiceDirty = $true
            foreach ($row in $app.Rows) { if (-not $row.Scanned) { $row.Status = 'Not read'; $row.StatusColor = $GRAY; $row.Note = 'Go back one step and continue again to read it.' } }
            Write-UiLog 'scan complete'
        }
        'Session' { $app.Session = $e; $app.ChoiceDirty = $true }
        'CopyPlan' {
            $app.CopyStats.Already = $e.Already
            $ui.StatAlready.Text = 'Already there ' + (Format-Count $e.Already)
            if ($e.Files -eq 0) { $ui.WorkAmounts.Text = 'Everything is already there.' }
        }
        'CopyFolderProgress' {
            $ui.StatCopied.Text = 'Copied ' + (Format-Count ([int64] $e.TotalCopied))
            $ui.StatFailed.Text = 'Problems ' + (Format-Count ([int64] $e.TotalFailed))
        }
        'Trouble' {
            # Connected, but the phone has stopped handing over files.
            $app.Waiting = [bool] $e.On
            if ($e.On) {
                $ui.WaitingTitle.Text = (Get-SourceWordTitle) + ' has stopped sending files'
                $ui.WaitingText.Text = 'Unplug it, plug it back in and unlock it - it then continues by itself. Or press "Try again now". Nothing done so far is lost.'
                $ui.TryAgainButton.Visibility = 'Visible'
                $ui.WaitingBanner.Visibility = 'Visible'
                $ui.WorkRate.Text = ('Waiting for {0}...' -f (Get-SourceWord))
                if ($app.Page -eq 'Free') { $ui.DeleteStep.Text = 'The phone has stopped answering - unplug it, plug it back in and unlock it. Removing then continues by itself.'; Set-Color $ui.DeleteStep 'Foreground' $AMBER }
                $window.TaskbarItemInfo.ProgressState = 'Paused'
                [System.Media.SystemSounds]::Exclamation.Play()
            }
            else {
                $ui.WaitingBanner.Visibility = 'Collapsed'; $ui.TryAgainButton.Visibility = 'Collapsed'
                $window.TaskbarItemInfo.ProgressState = 'Normal'
            }
        }
        'Waiting' {
            $app.Waiting = [bool] $e.On
            if ($e.On) {
                $ui.WaitingTitle.Text = (Get-SourceWordTitle) + ' was disconnected'
                $ui.WaitingText.Text = 'Plug it back in and unlock it - it continues by itself from where it stopped. Nothing done so far is lost.'
                $ui.TryAgainButton.Visibility = 'Collapsed'
                $ui.WaitingBanner.Visibility = 'Visible'
                $window.TaskbarItemInfo.ProgressState = 'Paused'
                if ($app.Page -eq 'Free') { $ui.DeleteStep.Text = 'Waiting for the phone - plug it back in and unlock it. Removing then continues by itself.'; Set-Color $ui.DeleteStep 'Foreground' $AMBER }
                [System.Media.SystemSounds]::Exclamation.Play()
            }
            else {
                $ui.WaitingBanner.Visibility = 'Collapsed'; $window.TaskbarItemInfo.ProgressState = 'Normal'
                if ($app.Page -eq 'Free') { $ui.DeleteStep.Text = ('Removing from {0}...' -f (Get-SourceWord)); Set-Color $ui.DeleteStep 'Foreground' '#0F172A' }
            }
        }
        'CopyDone' { Complete-Copy $e }
        'CompareDone' {
            $files = 0; $present = 0; $missing = 0; $missingBytes = [int64] 0
            foreach ($f in $e.Folders) { $files += $f.Files; $present += $f.Present; $missing += $f.Missing; $missingBytes += $f.MissingBytes }
            $app.CompareResult = $e
            Write-UiLog ("compare: {0} files, {1} present, {2} missing" -f $files, $present, $missing)
            $ui.CompareButton.IsEnabled = $true
            if ($e.Report) { Open-Path $e.Report }
            else { Show-Message ("{0} compared: {1} already on this PC, {2} ({3}) not yet." -f (Format-Plural $files 'file' 'files'), (Format-Count $present), (Format-Count $missing), (Format-Bytes $missingBytes)) 'Compare' }
        }
        'VerifyPlan' { }
        'FolderVerified' { Update-CheckRow $e }
        'VerifyDone' { Complete-Check $e }
        'FolderDeleted' {
            $row = $app.DeleteRows | Where-Object { $_.Name -eq $e.Name } | Select-Object -First 1
            if ($row) {
                if ($e.Refused) { $row.Status = 'Not removed - it did not pass the check'; $row.StatusColor = $AMBER }
                else {
                    $s = $CHECK + (' {0} removed, {1} freed' -f (Format-Count $e.Deleted), (Format-Bytes $e.DeletedBytes))
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
                $app.CheckStopped = 'The check was stopped before every file was compared.'
                $window.TaskbarItemInfo.ProgressState = 'None'; $window.Title = 'Smart Transfer'
                Show-Step 'Result'
            }
            elseif ($e.Command -eq 'Delete') {
                Complete-Delete @{ Deleted = 0; DeletedBytes = 0; Kept = 0; Failed = 0 } 'Removing was stopped. Everything removed so far is listed in the log; the rest is still there.'
            }
            elseif ($e.Command -eq 'Scan') { $app.Scanning = $false }
        }
        'Error' {
            Write-UiLog "engine error in $($e.Command): $($e.Message)"
            switch ($e.Command) {
                'SetSource' {
                    $app.LoadedKey = ''; $app.AwaitingList = $false
                    Show-Step 'Connect'
                    Show-Message ("Could not open the source.`r`n`r`n" + $e.Message) 'Smart Transfer' 'Warning'
                }
                'Copy' {
                    $app.CopyRunning = $false
                    $ui.WorkHeading.Text = 'Copying stopped because of a problem'
                    $ui.WorkSubText.Text = $e.Message
                    $window.TaskbarItemInfo.ProgressState = 'Error'; $window.Title = 'Smart Transfer'
                    Set-WorkFooter
                    Update-StageList
                }
                'Verify' {
                    $app.CheckRunning = $false
                    $app.CheckStopped = 'The check could not finish: ' + $e.Message
                    $window.Title = 'Smart Transfer'
                    Show-Step 'Result'
                }
                'Delete' { Complete-Delete @{ Deleted = 0; DeletedBytes = 0; Kept = 0; Failed = 0 } ('Removing stopped because of a problem: ' + $e.Message) }
                'Scan' { $app.Scanning = $false; $app.ScanDone = $true; $app.ChoiceDirty = $true }
                'Compare' { $ui.CompareButton.IsEnabled = $true; Show-Message $e.Message 'Smart Transfer' 'Warning' }
                default { Show-Message $e.Message 'Smart Transfer' 'Warning' }
            }
        }
        'EngineCrashed' { Show-Message ("Something went wrong in the background.`r`n`r`n" + $e.Message + "`r`n`r`nPlease close and start the app again. Nothing already copied is lost.") 'Smart Transfer' 'Error' }
    }
}

# ---------------------------------------------------------------------------
# button handlers
# ---------------------------------------------------------------------------

$ui.BackButton.Add_Click({ Invoke-Safely { Invoke-Back } })
$ui.NextButton.Add_Click({ Invoke-Safely { Invoke-Next } })
$ui.AltButton.Add_Click({ Invoke-Safely { Invoke-Alt } })
$ui.SelectAllButton.Add_Click({ Invoke-Safely { foreach ($r in $app.Rows) { if ($r.CanSelect) { $r.Selected = $true } } } })
$ui.SelectNoneButton.Add_Click({ Invoke-Safely { foreach ($r in $app.Rows) { $r.Selected = $false } } })
$ui.CompareButton.Add_Click({ Invoke-Safely {
    $names = [string[]] @($app.Rows | Where-Object { $_.Selected -and $_.CanSelect } | ForEach-Object { $_.Name })
    if ($names.Count -eq 0 -or -not $app.Dest) { Show-Message 'Tick at least one folder first.'; return }
    if ($sync.Busy) { Show-Message 'Please wait until every folder has been read.'; return }
    $ui.CompareButton.IsEnabled = $false
    Send-Command @{ Name = 'Compare'; Folders = $names }
} })
$ui.TryAgainButton.Add_Click({ Invoke-Safely { $sync.TryAgain = $true; $ui.TryAgainButton.Visibility = 'Collapsed'; $ui.WorkRate.Text = 'Trying again...' } })
$ui.OpenReportButton.Add_Click({ Invoke-Safely { Open-Path $app.Report } })
$ui.OpenDestButton.Add_Click({ Invoke-Safely { Open-Destination } })
$ui.FullCheckButton.Add_Click({ Invoke-Safely {
    if (Confirm-Action ('The full check reads every file from {0} again and compares it byte for byte. It takes about as long as the copy did. Start it?' -f (Get-SourceWord))) {
        Start-Check -Names $app.CheckFolders -Full $true
    }
} })
$ui.FreeAnywayButton.Add_Click({ Invoke-Safely { $app.After = 'Remove'; Show-Step 'Free' } })
$ui.DeleteConfirmCheck.Add_Click({ Invoke-Safely { Update-DeleteSelection } })
$ui.OpenLogButton.Add_Click({ Invoke-Safely { Open-Path $LogPath } })

$ShortcutPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Smart Transfer.lnk'
if (Test-Path -LiteralPath $ShortcutPath) { $ui.ShortcutButton.Visibility = 'Collapsed' }
$ui.ShortcutButton.Add_Click({ Invoke-Safely {
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut($ShortcutPath)
    $link.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $link.Arguments = '-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f (Join-Path $PSScriptRoot 'SmartTransfer.ps1')
    $link.WorkingDirectory = $PSScriptRoot
    $link.IconLocation = $IconPath + ',0'
    $link.Description = 'Copy photos, videos and files from a phone or a folder, check every file, then free up space'
    $link.WindowStyle = 7
    $link.Save()
    $ui.ShortcutButton.Visibility = 'Collapsed'
    Show-Message 'A "Smart Transfer" icon is now on your desktop. Double-click it next time.'
} })

# Keyboard: Enter goes on, Escape (or Alt+Left) goes back - like the buttons.
$window.Add_PreviewKeyDown({ param($s, $e)
    if ($e.Key -eq 'Escape' -or ($e.Key -eq 'Left' -and [System.Windows.Input.Keyboard]::Modifiers -eq 'Alt') -or $e.SystemKey -eq 'Left') {
        if ($ui.BackButton.Visibility -eq 'Visible' -and $ui.BackButton.IsEnabled) { $e.Handled = $true; Invoke-Safely { Invoke-Back } }
    }
})

$window.Add_Closing({
    param($s, $e)
    if ($app.ForceClose) { return }
    $busyWith = ''
    if ($app.CopyRunning) { $busyWith = 'A copy is running.' }
    elseif ($app.CheckRunning) { $busyWith = 'The check is running.' }
    elseif ($app.DeleteRunning) { $busyWith = ('Files are being removed from {0}.' -f (Get-SourceWord)) }
    if ($busyWith) {
        if (-not (Confirm-Action "$busyWith Stop it and close?`r`n`r`nEverything finished so far is kept; you can continue next time.")) { $e.Cancel = $true; return }
    }
    $sync.Cancel = $true
})

# ---------------------------------------------------------------------------
# testing aid: answer every question by itself and take screenshots
# ---------------------------------------------------------------------------

$auto = @{ Stage = 'start'; Shots = @{}; Since = [DateTime]::UtcNow; Started = [DateTime]::UtcNow; Log = New-Object System.Collections.ArrayList; Shot = 0 }

function Step-AutoPilot {
    $elapsed = ([DateTime]::UtcNow - $auto.Since).TotalSeconds
    $next = { param($s) $auto.Stage = $s; $auto.Since = [DateTime]::UtcNow; [void] $auto.Log.Add("$([DateTime]::Now.ToString('HH:mm:ss')) -> $s (page $($app.Page))") }
    switch ($auto.Stage) {
        'start' {
            if ($elapsed -lt 1.5) { return }
            Save-Screenshot 'source'
            if ($AutoTour) { & $next 'tour'; return }
            if ($DemoPhone) { Invoke-Tile 'source:iPhone' } else { Invoke-Tile 'source:Folder' }
            & $next 'connect'
        }
        'connect' {
            if ($elapsed -lt 1) { return }
            if (-not $DemoPhone) { $app.FolderPath = ''; Enter-Connect }
            Save-Screenshot 'connect'
            if ($DemoPhone) { Invoke-Click $ui.NextButton } else { Set-SourcePath $SourceFolder }
            & $next 'dest'
        }
        'dest' {
            if ($elapsed -lt 1.5 -or $app.AwaitingList) { return }
            Save-Screenshot 'dest'
            Select-Destination $Destination
            & $next 'choose'
        }
        'choose' {
            if ($app.Scanning -and -not $auto.Shots['scanning'] -and $elapsed -gt 0.5) { Save-Screenshot 'choose-reading'; $auto.Shots['scanning'] = $true }
            if (-not $app.ScanDone -or $sync.Busy -or $elapsed -lt 2) { return }
            Update-ChoosePage
            Save-Screenshot 'choose'
            if ($AutoStopAfter -eq 'Analyze' -and $app.Mode -eq 'Files') { & $next 'finish'; return }
            if ($app.Mode -eq 'Files') { Invoke-Click $ui.NextButton }
            elseif ($AutoFolders.Count -gt 0) {
                Invoke-Tile 'choice:Custom'
                Set-Selection ([string[]] @($app.Rows | Where-Object { $_.CanSelect -and ($AutoFolders -contains $_.Name) } | ForEach-Object { $_.Name }))
                & $next 'list'
                return
            }
            else {
                $first = $ui.ChoiceTiles.Children | Where-Object { $_ -is [System.Windows.Controls.Button] } | Select-Object -First 1
                if ($first) { Invoke-Click $first } else { [void] $auto.Log.Add('nothing to choose'); & $next 'finish'; return }
            }
            & $next 'after'
        }
        'tour' {
            # Each kind of source's first screen, as it looks while waiting (for a design review).
            $kinds = @('Android', 'iPhone', 'Folder')
            if ($elapsed -lt 1.2) { return }
            $i = [int] $auto.Shots['tour']
            if ($i -gt 0) { Save-Screenshot ('connect-' + $kinds[$i - 1].ToLowerInvariant()); if ($i -eq 1) { $ui.ConnectHelp.IsExpanded = $true; $window.UpdateLayout(); Save-Screenshot 'connect-android-help' } }
            if ($i -ge $kinds.Count) { & $next 'finish'; return }
            $auto.Shots['tour'] = $i + 1
            Show-Step 'Source'
            Invoke-Tile ('source:' + $kinds[$i])
            $auto.Since = [DateTime]::UtcNow
        }
        'list' {
            if ($elapsed -lt 1) { return }   # let the list draw its rows first
            Save-Screenshot 'choose-list'
            Invoke-Click $ui.NextButton
            & $next 'after'
        }
        'after' {
            if ($elapsed -lt 1) { return }
            if ($app.Page -ne 'After') { [void] $auto.Log.Add("expected the originals question, on $($app.Page)"); & $next 'finish'; return }
            Save-Screenshot 'originals'
            if ($AutoStopAfter -eq 'Delete') { Invoke-Tile 'after:Remove' } else { Invoke-Tile 'after:Keep' }
            & $next 'review'
        }
        'review' {
            if ($elapsed -lt 1) { return }
            Save-Screenshot 'review'
            # Go back to "Save to" through the sidebar and forward again: the answers must stay.
            Invoke-Click $StageUi[1].Button
            & $next 'back'
        }
        'back' {
            if ($elapsed -lt 1) { return }
            Save-Screenshot 'changed-mind-dest'
            [void] $auto.Log.Add("back on $($app.Page): dest=$($app.Dest) choice=$($app.Choice) after=$($app.After)")
            Invoke-Click $ui.NextButton   # Save to -> What
            Invoke-Click $ui.NextButton   # What -> Originals
            Invoke-Click $ui.NextButton   # Originals -> Start
            & $next 'review2'
        }
        'review2' {
            if ($elapsed -lt 1) { return }
            [void] $auto.Log.Add("forward again on $($app.Page)")
            if ($app.Page -ne 'Review') { & $next 'finish'; return }
            if ($AutoStopAfter -eq 'Analyze') { & $next 'finish'; return }
            Invoke-Click $ui.NextButton
            & $next 'copy'
        }
        'copy' {
            $p = $sync.Progress
            if ($app.CopyRunning -and -not $auto.Shots['copying'] -and [double] $p.BytesDone -gt 0) { Save-Screenshot 'copying'; $auto.Shots['copying'] = $true }
            if ($AutoTrouble -and $app.CopyRunning -and $auto.Shots['copying'] -and -not $auto.Shots['trouble']) {
                $auto.Shots['trouble'] = $true
                Invoke-EngineEvent @{ Type = 'Trouble'; On = $true }; Save-Screenshot 'trouble'; Invoke-EngineEvent @{ Type = 'Trouble'; On = $false }
            }
            if ($AutoInterrupt -and -not $auto.Shots['interrupted'] -and $app.CopyRunning -and [double] $p.BytesTotal -gt 0 -and
                ([double] $p.BytesDone + [double] $p.CurrentBytes) -gt 0.3 * [double] $p.BytesTotal) {
                $auto.Shots['interrupted'] = $true
                [void] $auto.Log.Add("pressing Stop at $([int64] $p.BytesDone + [int64] $p.CurrentBytes) of $([int64] $p.BytesTotal) bytes")
                Invoke-Click $ui.NextButton
                & $next 'stopped'
                return
            }
            if ($app.CheckRunning -and -not $auto.Shots['checking'] -and [double] $p.BytesDone -gt 0) { Save-Screenshot 'checking'; $auto.Shots['checking'] = $true }
            if ($AutoStopAfter -eq 'Copy' -and $app.CopyDone) { & $next 'finish'; return }
            if ($app.Page -eq 'Result' -and -not $app.CheckRunning) { & $next 'result' }
        }
        'stopped' {
            if ($app.CopyDone -and -not $app.CopyRunning -and $elapsed -gt 1) {
                Save-Screenshot 'stopped'
                [void] $auto.Log.Add("stopped: copied=$($app.CopyDone.Copied) cancelled=$($app.CopyDone.Cancelled); pressing Continue")
                Invoke-Click $ui.NextButton
                & $next 'copy'
            }
        }
        'result' {
            if ($elapsed -lt 1) { return }
            Save-Screenshot 'result'
            if ($AutoFullCheck -and -not $auto.Shots['full']) { $auto.Shots['full'] = $true; Start-Check -Names $app.CheckFolders -Full $true; & $next 'copy'; return }
            if ($AutoStopAfter -eq 'Check') { & $next 'finish'; return }
            Invoke-Click $ui.NextButton
            & $next 'free'
        }
        'free' {
            if ($elapsed -lt 1) { return }
            if ($app.Page -ne 'Free') { [void] $auto.Log.Add("expected the remove screen, on $($app.Page)"); & $next 'finish'; return }
            Save-Screenshot 'free'
            $ui.DeleteConfirmCheck.IsChecked = $true
            Update-DeleteSelection
            Save-Screenshot 'free-ready'
            Invoke-Click $ui.NextButton
            & $next 'deleting'
        }
        'deleting' {
            if ($app.Page -eq 'Done' -and $elapsed -gt 1) { Save-Screenshot 'done'; & $next 'finish' }
        }
        'finish' {
            if ($ScreenshotDir) {
                $result = @{
                    Stages = @($auto.Log); Page = $app.Page
                    Copy = $app.CopyDone; Check = $app.CheckDone; Delete = $app.DeleteDone
                    Rows = @($app.Rows | ForEach-Object { @{ Name = $_.Name; Selected = $_.Selected; Status = $_.Status; Files = $_.Files } })
                    CheckSummaries = @($app.CheckSummaries.Values | ForEach-Object { @{ Name = $_.Name; Ok = $_.Ok; Files = $_.PhoneFiles; OkFiles = $_.OkFiles } })
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

# Remember how the app's own files looked at start, to notice an update installed meanwhile.
$AppFiles = @('SmartTransfer.ps1', 'Common.ps1', 'Engine.ps1', 'Native.cs') | ForEach-Object { Join-Path $PSScriptRoot $_ }
$AppStamp = (($AppFiles | ForEach-Object { if (Test-Path -LiteralPath $_) { (Get-Item -LiteralPath $_).LastWriteTimeUtc.Ticks } }) -join ',')
$app.LastUpdateCheck = [DateTime]::UtcNow

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
            'Choose' { Update-FreeSpace; Update-ChoosePage }
            'Work'   { Update-WorkLive }
            'Free'   { Update-DeleteLive; Update-DeleteSelection }
        }
        if (([DateTime]::UtcNow - $app.LastUpdateCheck).TotalSeconds -ge 30) {
            $app.LastUpdateCheck = [DateTime]::UtcNow
            $now = (($AppFiles | ForEach-Object { if (Test-Path -LiteralPath $_) { (Get-Item -LiteralPath $_).LastWriteTimeUtc.Ticks } }) -join ',')
            if ($now -ne $AppStamp) { $ui.UpdateNotice.Visibility = 'Visible' }
        }
        if ($AutoPilot) {
            if (([DateTime]::UtcNow - $auto.Started).TotalMinutes -gt 10 -and $auto.Stage -ne 'closing') { [void] $auto.Log.Add('gave up after 10 minutes'); $auto.Stage = 'finish' }
            Step-AutoPilot
        }
    }
    catch {
        Write-UiLog ("tick failed: {0} {1}" -f $_.Exception.Message, $_.ScriptStackTrace)
        if ($AutoPilot -and $auto.Stage -ne 'closing') { [void] $auto.Log.Add("error in $($auto.Stage): $($_.Exception.Message)"); $auto.Stage = 'finish' }
    }
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

Initialize-StageList
if ($DemoPhone) { $sync.DemoMode = $true; $sync.DemoScanDelayMs = 12 }
if ($AutoPilot) { $sync.NoRecycle = $true }   # test runs remove their own test files for good
if ($SourceFolder -and -not $AutoPilot) { $app.SourceType = 'Folder'; $app.FolderPath = $SourceFolder; $app.Speed = $DEFAULT_SPEED['Folder'] }
Show-Step 'Source'
$timer.Start()
Write-UiLog ("app started (source folder: '{0}', demo phone: '{1}', autopilot: {2})" -f $SourceFolder, $DemoPhone, [bool] $AutoPilot)
[void] $window.ShowDialog()

# ---------------------------------------------------------------------------
# shut down: let the engine finish cleanly (it removes any half-written file)
# ---------------------------------------------------------------------------

$timer.Stop()
$sync.Cancel = $true
$sync.Quit = $true
[void] $handle.AsyncWaitHandle.WaitOne(15000)
try { $worker.Dispose(); $runspace.Dispose() } catch { }
