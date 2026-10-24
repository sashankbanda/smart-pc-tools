<#
.SYNOPSIS
    Smart Cleanup - finds what can go to free up space (duplicates, junk, temporary files,
    old installers and downloads, very large files, empty folders, the Recycle Bin), shows
    where the space goes, and tidies up a messy folder by sorting its files into folders.

.DESCRIPTION
    The same kiosk-style window as Smart Transfer: one question per screen, Back bottom left,
    the next step bottom right, every answer in the sidebar - click one to change it.

      Free up space   where to look  ->  looking  ->  what to remove  ->  clean up  ->  done
      Organize        which folder   ->  how      ->  what will happen ->  done (with Undo)

    Nothing is removed or moved before you have seen exactly what and said yes. Removed files
    go to the Recycle Bin; only temporary files and the Recycle Bin itself are gone for good.

    Start it by double-clicking "Smart Cleanup.cmd" next to this folder.

.PARAMETER Folder
    Testing aid together with -AutoPilot: the folder to analyse or organize. The autopilot
    never looks anywhere else, never touches the Recycle Bin or temp folders, and removes its
    test files for good instead of filling the Recycle Bin.

.PARAMETER AutoTask
    Testing aid: Clean (analyse, then clean up what is recommended) or Organize (sort by
    type, then undo).
#>

[CmdletBinding()]
param(
    [string] $Folder = '',
    [switch] $AutoPilot,
    [ValidateSet('Clean', 'Organize')]
    [string] $AutoTask = 'Clean',
    [string] $AutoDownloads = '',
    [string] $ScreenshotDir = ''
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework
trap {
    $message = $_.Exception.Message
    try {
        $dir = Join-Path $env:LOCALAPPDATA 'SmartTransfer\logs'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Add-Content -LiteralPath (Join-Path $dir 'startup-errors.log') -Value ('{0}  cleanup  {1}  {2}' -f (Get-Date), $message, $_.ScriptStackTrace)
    }
    catch { }
    if (-not $AutoPilot) { [void] [System.Windows.MessageBox]::Show("Smart Cleanup stopped because of a problem:`r`n`r`n$message", 'Smart Cleanup', 'OK', 'Error') }
    break
}

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    throw 'Please start Smart Cleanup with "Smart Cleanup.cmd" (it needs powershell -STA).'
}
if ($AutoPilot -and -not $Folder) { throw 'The autopilot needs -Folder: it never looks at real files.' }

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
if (-not ('SmartCleanup.Analyzer' -as [type])) {
    if ('IPhoneTransferApp.Native' -as [type]) { throw 'Start Smart Cleanup in its own window ("Smart Cleanup.cmd").' }
    Add-Type -Path (Join-Path $PSScriptRoot 'Native.cs'), (Join-Path $PSScriptRoot 'Analyzer.cs')
}
$AppTitle = 'Smart Cleanup'
. (Join-Path $PSScriptRoot 'Common.ps1')

$Invariant = [System.Globalization.CultureInfo]::InvariantCulture
$DOT = ' ' + [char] 0x00B7 + ' '
$CHECK = [string] [char] 0x2713

# ---------------------------------------------------------------------------
# settings and log
# ---------------------------------------------------------------------------

$SettingsDir  = Join-Path $env:APPDATA 'SmartTransfer'
$SettingsPath = Join-Path $SettingsDir 'cleanup.json'
$LogDir       = Join-Path $env:LOCALAPPDATA 'SmartTransfer\logs'
$LogPath      = Join-Path $LogDir ('cleanup-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogWriter = New-Object System.IO.StreamWriter($LogPath, $true, (New-Object System.Text.UTF8Encoding($false)))
$LogWriter.AutoFlush = $true

function Write-UiLog { param([string] $Text) try { $LogWriter.WriteLine(('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text)) } catch { } }

function Get-Settings {
    $s = @{ LastSortLog = ''; LastSortFolder = '' }
    try {
        if (Test-Path -LiteralPath $SettingsPath) {
            $j = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json
            if ($j.LastSortLog) { $s.LastSortLog = [string] $j.LastSortLog; $s.LastSortFolder = [string] $j.LastSortFolder }
        }
    }
    catch { }
    return $s
}

function Save-Settings {
    if ($AutoPilot) { return }
    try {
        New-Item -ItemType Directory -Force -Path $SettingsDir | Out-Null
        [System.IO.File]::WriteAllText($SettingsPath, ($settings | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
    }
    catch { }
}

# ---------------------------------------------------------------------------
# the window
# ---------------------------------------------------------------------------

$xamlText = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Smart Cleanup" Width="1180" Height="800" MinWidth="980" MinHeight="680"
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
            <Border Width="40" Height="40" CornerRadius="11" Background="#0F766E">
              <TextBlock Style="{StaticResource Icon}" Text="&#xE9F9;" FontSize="20" Foreground="White" HorizontalAlignment="Center"/>
            </Border>
            <StackPanel Margin="12,0,0,0" VerticalAlignment="Center">
              <TextBlock Text="Smart Cleanup" FontSize="18" FontWeight="SemiBold" Foreground="White"/>
              <TextBlock Text="Find, free up, tidy up" FontSize="12" Foreground="#94A3B8"/>
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
                <TextBlock Text="You stay in control" Foreground="White" FontSize="12" FontWeight="SemiBold" Margin="8,0,0,0"/>
              </StackPanel>
              <TextBlock Text="Nothing is removed or moved until you have seen it and said yes. Windows and your programs are never touched."
                         Foreground="#94A3B8" FontSize="11" TextWrapping="Wrap" Margin="0,6,0,0"/>
            </StackPanel>
          </Border>
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

        <!-- what would you like to do -->
        <Grid x:Name="PageTask" MaxWidth="920">
          <StackPanel>
            <TextBlock Text="What would you like to do?" Style="{StaticResource H1}"/>
            <TextBlock Text="Nothing is removed or moved until you have seen exactly what will happen and said yes." Style="{StaticResource Sub}"/>
            <UniformGrid x:Name="TaskTiles" Columns="2" Margin="-8,30,-8,0"/>
          </StackPanel>
        </Grid>

        <!-- free up space: where to look -->
        <ScrollViewer x:Name="PageScope" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
          <StackPanel MaxWidth="920">
            <TextBlock Text="Where should I look?" Style="{StaticResource H1}"/>
            <TextBlock Text="Your own files are the best place to start. A whole drive also shows how much Windows and your programs take." Style="{StaticResource Sub}"/>
            <StackPanel x:Name="ScopeTiles" Margin="0,28,0,0"/>
          </StackPanel>
        </ScrollViewer>

        <!-- looking -->
        <ScrollViewer x:Name="PageScan" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
          <StackPanel MaxWidth="920">
            <TextBlock Text="Looking at your files" Style="{StaticResource H1}"/>
            <TextBlock x:Name="ScanSubText" Style="{StaticResource Sub}"/>
            <Border Style="{StaticResource Card}" Margin="0,26,0,0" Padding="30,26">
              <StackPanel>
                <TextBlock x:Name="ScanPhase" FontSize="17" FontWeight="SemiBold"/>
                <TextBlock x:Name="ScanCount" FontSize="40" FontWeight="SemiBold" Foreground="#0F766E" Margin="0,10,0,0"/>
                <ProgressBar x:Name="ScanBusyBar" Style="{x:Null}" IsIndeterminate="True" Height="6" Margin="0,16,0,0" Foreground="#0F766E" Background="#E2E8F0" BorderThickness="0"/>
                <ProgressBar x:Name="ScanBar" Height="12" Margin="0,16,0,0" Maximum="1000" Foreground="#0F766E" Visibility="Collapsed"/>
                <TextBlock x:Name="ScanCurrent" Foreground="#64748B" FontSize="13" Margin="0,14,0,0" TextTrimming="CharacterEllipsis"/>
              </StackPanel>
            </Border>
          </StackPanel>
        </ScrollViewer>

        <!-- what can go -->
        <Grid x:Name="PageFindings" MaxWidth="920" Visibility="Collapsed">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <StackPanel>
            <TextBlock x:Name="FindHeading" Style="{StaticResource H1}"/>
            <TextBlock x:Name="FindSubText" Style="{StaticResource Sub}"/>
          </StackPanel>
          <ScrollViewer x:Name="FindScroll" Grid.Row="1" Margin="0,22,0,0" VerticalScrollBarVisibility="Auto">
            <StackPanel>
              <StackPanel x:Name="CategoryList"/>
              <TextBlock x:Name="UsageHeading" Text="WHERE YOUR SPACE GOES" Foreground="#64748B" FontSize="12" FontWeight="Bold" Margin="4,18,0,4"/>
              <TextBlock x:Name="UsageNote" Foreground="#64748B" FontSize="13" TextWrapping="Wrap" Margin="4,0,0,10"/>
              <Border Style="{StaticResource Card}" Padding="22,14">
                <StackPanel x:Name="UsageList"/>
              </Border>
            </StackPanel>
          </ScrollViewer>
        </Grid>

        <!-- one kind of suggestion, file by file -->
        <Grid x:Name="PageDetails" MaxWidth="920" Visibility="Collapsed">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <StackPanel>
            <TextBlock x:Name="DetailHeading" Style="{StaticResource H1}"/>
            <TextBlock x:Name="DetailText" Style="{StaticResource Sub}"/>
          </StackPanel>
          <Border Grid.Row="1" Style="{StaticResource Card}" Margin="0,20,0,0" Padding="0">
            <Grid>
              <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
              <DockPanel Margin="18,14,18,8">
                <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                  <Button x:Name="DetailAllButton" Content="Tick all" Style="{StaticResource Link}" Margin="0,0,18,0"/>
                  <Button x:Name="DetailNoneButton" Content="Untick all" Style="{StaticResource Link}" Margin="0,0,18,0"/>
                  <Button x:Name="DetailShowButton" Content="Show in its folder" Style="{StaticResource Link}"/>
                </StackPanel>
                <TextBlock Text="Tick what may go. Double-click a file to see it in its folder." FontSize="14" Foreground="#475569" VerticalAlignment="Center"/>
              </DockPanel>
              <DataGrid x:Name="DetailGrid" Grid.Row="1" Margin="4,0,4,4">
                <DataGrid.Columns>
                  <DataGridTemplateColumn Header="" Width="48">
                    <DataGridTemplateColumn.CellTemplate>
                      <DataTemplate>
                        <CheckBox IsChecked="{Binding Selected, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                      </DataTemplate>
                    </DataGridTemplateColumn.CellTemplate>
                  </DataGridTemplateColumn>
                  <DataGridTemplateColumn Header="File" Width="3*">
                    <DataGridTemplateColumn.CellTemplate>
                      <DataTemplate>
                        <StackPanel VerticalAlignment="Center" Margin="0,5" ToolTip="{Binding Path}">
                          <TextBlock Text="{Binding Name}" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
                          <TextBlock Text="{Binding Folder}" Foreground="#64748B" FontSize="12" TextTrimming="CharacterEllipsis"/>
                        </StackPanel>
                      </DataTemplate>
                    </DataGridTemplateColumn.CellTemplate>
                  </DataGridTemplateColumn>
                  <DataGridTextColumn Header="Size" Binding="{Binding SizeText}" Width="90"/>
                  <DataGridTextColumn Header="Changed" Binding="{Binding DateText}" Width="100"/>
                  <DataGridTemplateColumn Header="Why" Width="3*">
                    <DataGridTemplateColumn.CellTemplate>
                      <DataTemplate><TextBlock Text="{Binding Reason}" Foreground="#475569" TextWrapping="Wrap" VerticalAlignment="Center" ToolTip="{Binding Reason}"/></DataTemplate>
                    </DataGridTemplateColumn.CellTemplate>
                  </DataGridTemplateColumn>
                </DataGrid.Columns>
              </DataGrid>
            </Grid>
          </Border>
        </Grid>

        <!-- the last look before cleaning up -->
        <ScrollViewer x:Name="PageConfirm" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
          <StackPanel MaxWidth="920">
            <TextBlock x:Name="ConfirmHeading" Style="{StaticResource H1}"/>
            <TextBlock Text="This is what will be removed. Press Change next to anything to go back." Style="{StaticResource Sub}"/>
            <Border Style="{StaticResource Card}" Padding="0" Margin="0,26,0,0">
              <StackPanel x:Name="ConfirmRows"/>
            </Border>
            <Border x:Name="ConfirmNoteCard" Margin="0,16,0,0" Background="#EFF6FF" BorderBrush="#BFDBFE" BorderThickness="1" CornerRadius="12" Padding="18,14">
              <DockPanel>
                <TextBlock DockPanel.Dock="Left" Style="{StaticResource Icon}" Text="&#xE946;" FontSize="18" Foreground="#2563EB" VerticalAlignment="Top" Margin="0,1,12,0"/>
                <TextBlock x:Name="ConfirmNote" Foreground="#1E3A8A" FontSize="14" TextWrapping="Wrap"/>
              </DockPanel>
            </Border>
            <CheckBox x:Name="ConfirmCheck" Margin="2,20,0,0" FontSize="15" VerticalContentAlignment="Center" Visibility="Collapsed">
              <TextBlock x:Name="ConfirmCheckText" TextWrapping="Wrap" Margin="6,0,0,0"/>
            </CheckBox>
          </StackPanel>
        </ScrollViewer>

        <!-- working: cleaning up, sorting, putting back -->
        <ScrollViewer x:Name="PageWork" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
          <StackPanel MaxWidth="920">
            <TextBlock x:Name="WorkHeading" Style="{StaticResource H1}"/>
            <TextBlock x:Name="WorkSubText" Style="{StaticResource Sub}"/>
            <Border Style="{StaticResource Card}" Margin="0,26,0,0" Padding="30,26">
              <StackPanel>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <TextBlock x:Name="WorkPercent" Text="0%" FontSize="56" FontWeight="SemiBold" Foreground="#0F766E" VerticalAlignment="Center"/>
                  <TextBlock x:Name="WorkAmounts" Grid.Column="1" Margin="24,0,0,0" FontSize="17" FontWeight="SemiBold" VerticalAlignment="Center" TextWrapping="Wrap"/>
                </Grid>
                <ProgressBar x:Name="WorkBar" Height="16" Margin="0,18,0,0" Maximum="1000" Foreground="#0F766E"/>
                <TextBlock x:Name="WorkCurrent" Foreground="#64748B" FontSize="13" Margin="0,14,0,0" TextTrimming="CharacterEllipsis"/>
              </StackPanel>
            </Border>
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
            <Border x:Name="DoneFactsCard" Style="{StaticResource Card}" Margin="0,24,0,0" Padding="0">
              <StackPanel x:Name="DoneFacts"/>
            </Border>
            <StackPanel x:Name="DoneExtra" Margin="0,16,0,0"/>
          </StackPanel>
        </ScrollViewer>

        <!-- organize: which folder -->
        <ScrollViewer x:Name="PageOrgFolder" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
          <StackPanel MaxWidth="920">
            <TextBlock Text="Which folder should be tidied up?" Style="{StaticResource H1}"/>
            <TextBlock Text="The files lying loose in it are sorted into folders. Folders already in it stay exactly as they are." Style="{StaticResource Sub}"/>
            <StackPanel x:Name="OrgFolderTiles" Margin="0,28,0,0"/>
          </StackPanel>
        </ScrollViewer>

        <!-- organize: how -->
        <Grid x:Name="PageOrgHow" MaxWidth="920" Visibility="Collapsed">
          <StackPanel>
            <TextBlock Text="How should the files be sorted?" Style="{StaticResource H1}"/>
            <TextBlock x:Name="OrgHowSubText" Style="{StaticResource Sub}"/>
            <UniformGrid x:Name="OrgHowTiles" Columns="3" Margin="-8,30,-8,0"/>
          </StackPanel>
        </Grid>

        <!-- organize: what will happen -->
        <ScrollViewer x:Name="PageOrgPreview" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
          <StackPanel MaxWidth="920">
            <TextBlock x:Name="OrgPreviewHeading" Style="{StaticResource H1}"/>
            <TextBlock x:Name="OrgPreviewSubText" Style="{StaticResource Sub}"/>
            <Border x:Name="OrgGroupsCard" Style="{StaticResource Card}" Padding="0" Margin="0,26,0,0">
              <StackPanel x:Name="OrgGroups"/>
            </Border>
            <Border Margin="0,16,0,0" Background="#EFF6FF" BorderBrush="#BFDBFE" BorderThickness="1" CornerRadius="12" Padding="18,14">
              <DockPanel>
                <TextBlock DockPanel.Dock="Left" Style="{StaticResource Icon}" Text="&#xE7A7;" FontSize="18" Foreground="#2563EB" VerticalAlignment="Top" Margin="0,1,12,0"/>
                <TextBlock x:Name="OrgNote" Foreground="#1E3A8A" FontSize="14" TextWrapping="Wrap"/>
              </DockPanel>
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
[IPhoneTransferApp.Native]::SetAppId('SmartTransfer.Cleanup')
$IconPath = Join-Path $PSScriptRoot 'iPhoneTransfer.ico'
if (Test-Path -LiteralPath $IconPath) {
    try { $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create((New-Object System.Uri $IconPath)) } catch { }
}

# ---------------------------------------------------------------------------
# state
# ---------------------------------------------------------------------------

$settings = Get-Settings
$app = @{
    Page = 'Task'; Task = ''
    Scope = ''; ScopeTitle = ''; Analyzer = $null; Category = $null
    Cleaner = $null; Recycled = [int64] 0
    OrgFolder = ''; OrgMode = ''; OrgPlan = $null; Org = $null; OrgUndo = $false; OrgLog = ''
    ForceClose = $false
}
$StageUi = New-Object System.Collections.ArrayList
$GREEN = '#15803D'; $AMBER = '#B45309'; $RED = '#B91C1C'; $GRAY = '#64748B'; $TEAL = '#0F766E'

$CLEAN_STAGES = @(
    @{ Title = 'What';     Pages = @('Task');                Go = 'Task' },
    @{ Title = 'Where';    Pages = @('Scope');               Go = 'Scope' },
    @{ Title = 'Look';     Pages = @('Scan');                Go = '' },
    @{ Title = 'Choose';   Pages = @('Findings', 'Details'); Go = 'Findings' },
    @{ Title = 'Clean up'; Pages = @('Confirm', 'Work');     Go = 'Confirm' },
    @{ Title = 'Done';     Pages = @('Done');                Go = '' }
)
$ORG_STAGES = @(
    @{ Title = 'What';   Pages = @('Task');       Go = 'Task' },
    @{ Title = 'Folder'; Pages = @('OrgFolder');  Go = 'OrgFolder' },
    @{ Title = 'How';    Pages = @('OrgHow');     Go = 'OrgHow' },
    @{ Title = 'Check';  Pages = @('OrgPreview'); Go = 'OrgPreview' },
    @{ Title = 'Done';   Pages = @('Work', 'Done'); Go = '' }
)
$STAGES = $CLEAN_STAGES
$PAGES = @('Task', 'Scope', 'Scan', 'Findings', 'Details', 'Confirm', 'Work', 'Done', 'OrgFolder', 'OrgHow', 'OrgPreview')

# Known folders of this user.
function Get-KnownFolder {
    param([string] $Name)
    switch ($Name) {
        'Downloads' {
            try { $p = (New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path; if ($p) { return $p } } catch { }
            return (Join-Path $env:USERPROFILE 'Downloads')
        }
        'Documents' { return [Environment]::GetFolderPath('MyDocuments') }
        'Pictures'  { return [Environment]::GetFolderPath('MyPictures') }
        'Videos'    { return [Environment]::GetFolderPath('MyVideos') }
        'Music'     { return [Environment]::GetFolderPath('MyMusic') }
        default     { return [Environment]::GetFolderPath($Name) }
    }
}
$MyFolderNames = @('Desktop', 'Documents', 'Downloads', 'Pictures', 'Videos', 'Music')

# ---------------------------------------------------------------------------
# navigation
# ---------------------------------------------------------------------------

function Test-Busy {
    return (($app.Cleaner -and -not $app.Cleaner.Done) -or ($app.Org -and -not $app.Org.Done))
}

function Test-CanGoBack {
    if (Test-Busy) { return $false }
    return (@('Work', 'Done') -notcontains $app.Page)
}

function Get-StageAnswer {
    param([int] $Index)
    if ($app.Task -eq 'Organize') {
        switch ($Index) {
            0 { return 'Organize a folder' }
            1 { if ($app.OrgFolder) { return (Format-ShortPath $app.OrgFolder 34) } }
            2 { switch ($app.OrgMode) { 'Type' { return 'By type' } 'Date' { return 'By date' } 'TypeDate' { return 'By type, then year' } } }
            3 { if ($app.OrgPlan) { return (Format-Plural $app.OrgPlan.Moves.Count 'file' 'files') } }
        }
        return ''
    }
    switch ($Index) {
        0 { if ($app.Task) { return 'Free up space' } }
        1 { return $app.ScopeTitle }
        3 {
            $a = $app.Analyzer
            if ($a -and $a.Done -and $app.Page -ne 'Scan') {
                $s = Get-Selection
                return ('{0}, {1}' -f (Format-Plural $s.Count 'item' 'items'), (Format-Bytes $s.Bytes))
            }
        }
    }
    return ''
}

function Show-Step {
    param([string] $Name)
    # Leaving the analysis half-way stops it.
    if ($app.Page -eq 'Scan' -and $Name -ne 'Findings' -and $app.Analyzer -and -not $app.Analyzer.Done) { $app.Analyzer.Cancel = $true }
    $app.Page = $Name
    foreach ($p in $PAGES) {
        if ($p -eq $Name) { $ui["Page$p"].Visibility = 'Visible' } else { $ui["Page$p"].Visibility = 'Collapsed' }
    }
    switch ($Name) {
        'Task'       { Enter-Task }
        'Scope'      { Enter-Scope }
        'Scan'       { }
        'Findings'   { Enter-Findings }
        'Details'    { Enter-Details }
        'Confirm'    { Enter-Confirm }
        'Work'       { }
        'Done'       { }
        'OrgFolder'  { Enter-OrgFolder }
        'OrgHow'     { Enter-OrgHow }
        'OrgPreview' { Enter-OrgPreview }
    }
    Update-StageList
    Write-UiLog "page: $Name"
}

function Invoke-Back {
    switch ($app.Page) {
        'Scope'      { Show-Step 'Task' }
        'Scan'       { Show-Step 'Scope' }
        'Findings'   { Show-Step 'Scope' }
        'Details'    { Show-Step 'Findings' }
        'Confirm'    { Show-Step 'Findings' }
        'OrgFolder'  { Show-Step 'Task' }
        'OrgHow'     { Show-Step 'OrgFolder' }
        'OrgPreview' { Show-Step 'OrgHow' }
    }
}

function Invoke-Next {
    switch ($app.Page) {
        'Task'       { if ($app.Task -eq 'Organize') { Show-Step 'OrgFolder' } elseif ($app.Task) { Show-Step 'Scope' } }
        'Scope'      { if ($app.Scope) { Start-Analysis } }
        'Scan'       { Show-Step 'Scope' }   # Stop
        'Findings'   { if ((Get-Selection).Count -gt 0) { Show-Step 'Confirm' } }
        'Details'    { Show-Step 'Findings' }
        'Confirm'    { Start-Clean }
        'Done'       { Reset-All }
        'OrgFolder'  { if ($app.OrgFolder) { Show-Step 'OrgHow' } }
        'OrgHow'     { if ($app.OrgMode) { Show-Step 'OrgPreview' } }
        'OrgPreview' { Start-Sort }
    }
}

function Invoke-Alt {
    switch ($app.Page) {
        'Done' {
            if ($app.Task -eq 'Organize') { if (-not $app.OrgUndo -and $app.OrgLog) { Start-Undo $app.OrgLog } else { Open-Path $app.OrgFolder } }
            else { Start-Analysis }   # look again
        }
    }
}

function Invoke-Tile {
    param([string] $Action)
    $parts = @($Action -split ':', 2)
    $kind = $parts[0]; $value = ''
    if ($parts.Count -gt 1) { $value = $parts[1] }
    Write-UiLog "choice: $Action"
    switch ($kind) {
        'task'      { Select-Task $value }
        'undo-last' { Start-Undo $settings.LastSortLog }
        'scope'     { Select-Scope $value }
        'cat'       { Switch-Category $value }
        'cat-open'  { $app.Category = Get-Category $value; Show-Step 'Details' }
        'goto'      { if (Test-CanGoBack) { Show-Step $value } }
        'orgfolder' { Select-OrgFolder $value }
        'orghow'    { $app.OrgMode = $value; Show-Step 'OrgPreview' }
        'empty-bin' { Clear-RecycleBins }
        'storage'   { if (-not $AutoPilot) { Start-Process 'ms-settings:storagesense' } }
    }
}

# ---------------------------------------------------------------------------
# what would you like to do
# ---------------------------------------------------------------------------

function Enter-Task {
    $ui.TaskTiles.Children.Clear()
    $undo = ($settings.LastSortLog -and (Test-Path -LiteralPath $settings.LastSortLog))
    if ($undo) { $ui.TaskTiles.Columns = 3 } else { $ui.TaskTiles.Columns = 2 }
    [void] $ui.TaskTiles.Children.Add((New-Tile -Action 'task:Clean' -Icon ([string] [char] 0xE9D9) -Title 'Free up space' -Text 'See where your space goes, and what can go: duplicates, junk, leftovers, old downloads.' -Accent $TEAL -AccentBack '#CCFBF1' -Selected:($app.Task -eq 'Clean')))
    [void] $ui.TaskTiles.Children.Add((New-Tile -Action 'task:Organize' -Icon ([string] [char] 0xF0E2) -Title 'Organize a folder' -Text 'Sort the loose files of a messy folder - like Downloads or the Desktop - into folders.' -Accent '#7C3AED' -AccentBack '#EDE9FE' -Selected:($app.Task -eq 'Organize')))
    if ($undo) {
        [void] $ui.TaskTiles.Children.Add((New-Tile -Action 'undo-last' -Icon ([string] [char] 0xE7A7) -Title 'Undo the last sorting' -Text ('Put the files sorted in {0} back where they were.' -f (Split-Path -Leaf $settings.LastSortFolder)) -Accent '#475569' -AccentBack '#E2E8F0'))
    }
    Set-Footer -Back '' -Next 'Continue' -NextEnabled ([bool] $app.Task)
}

function Select-Task {
    param([string] $Task)
    if ($Task -ne $app.Task) {
        $app.Task = $Task
        if ($Task -eq 'Organize') { $script:STAGES = $ORG_STAGES } else { $script:STAGES = $CLEAN_STAGES }
        Initialize-StageList
    }
    if ($Task -eq 'Organize') { Show-Step 'OrgFolder' } else { Show-Step 'Scope' }
}

function Reset-All {
    $app.Task = ''; $app.Scope = ''; $app.ScopeTitle = ''; $app.Analyzer = $null; $app.Cleaner = $null
    $app.OrgFolder = ''; $app.OrgMode = ''; $app.OrgPlan = $null; $app.Org = $null; $app.OrgLog = ''; $app.OrgUndo = $false
    $script:STAGES = $CLEAN_STAGES
    Initialize-StageList
    Show-Step 'Task'
}

# ---------------------------------------------------------------------------
# free up space: where to look
# ---------------------------------------------------------------------------

function Get-MyFolders { return @($MyFolderNames | ForEach-Object { Get-KnownFolder $_ } | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique) }

function Enter-Scope {
    $ui.ScopeTiles.Children.Clear()
    if (-not $AutoPilot) {
        $names = (@(Get-MyFolders) | ForEach-Object { Split-Path -Leaf $_ }) -join ', '
        [void] $ui.ScopeTiles.Children.Add((New-Tile -Action 'scope:mine' -Icon ([string] [char] 0xF12B) -Title 'My files' -Text $names -Extra 'Plus the temporary files and the Recycle Bin. Quick, and the safest place to start.' -Badge 'Recommended' -Accent $TEAL -AccentBack '#CCFBF1' -Wide -Selected:($app.Scope -eq 'mine')))
        foreach ($d in (Get-UsableDrives @('Fixed', 'Removable'))) {
            $used = 0.0; if ($d.TotalSize -gt 0) { $used = [double] ($d.TotalSize - $d.AvailableFreeSpace) / [double] $d.TotalSize }
            $icon = [char] 0xEDA2; if ([string] $d.DriveType -eq 'Removable') { $icon = [char] 0xE88E }
            [void] $ui.ScopeTiles.Children.Add((New-Tile -Action ('scope:' + $d.Name) -Icon ([string] $icon) -Title ('Everything on ' + (Get-DriveTitle $d)) -Text ('{0} free of {1}' -f (Format-Bytes $d.AvailableFreeSpace), (Format-Bytes $d.TotalSize)) -Bar $used -Accent '#475569' -AccentBack '#E2E8F0' -Wide -Selected:($app.Scope -eq $d.Name)))
        }
    }
    elseif ($app.Scope) {
        [void] $ui.ScopeTiles.Children.Add((New-Tile -Action ('scope:' + $app.Scope) -Icon ([string] [char] 0xF12B) -Title (Split-Path -Leaf $app.Scope) -Text $app.Scope -Wide -Selected))
    }
    [void] $ui.ScopeTiles.Children.Add((New-Tile -Action 'scope:?' -Icon ([string] [char] 0xED25) -Title 'Choose a folder...' -Text 'Any folder on this PC, a USB stick or a network drive.' -Wide))
    Set-Footer -Next 'Continue' -NextEnabled ([bool] $app.Scope)
}

function Select-Scope {
    param([string] $Value)
    if ($Value -eq '?') {
        $start = ''; if ($app.Scope -and $app.Scope -ne 'mine') { $start = $app.Scope }
        $Value = Select-FolderDialog 'Choose the folder to look at. Every folder inside it is looked at too.' $start
        if (-not $Value) { return }
    }
    $app.Scope = $Value
    Start-Analysis
}

function Start-Analysis {
    $a = New-Object SmartCleanup.Analyzer
    $windows = [System.IO.Path]::GetPathRoot($env:WINDIR)
    foreach ($p in @($env:WINDIR, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, (Join-Path $env:USERPROFILE 'AppData'), $env:LOCALAPPDATA, $env:APPDATA)) {
        if ($p) { $a.ProtectedRoots.Add($p) }
    }
    $a.KeepFolders.Add($env:USERPROFILE.TrimEnd('\') + '\')   # the folders right inside the profile
    foreach ($p in (Get-MyFolders)) { $a.KeepFolders.Add($p) }
    if ($env:OneDrive) { $a.KeepFolders.Add($env:OneDrive) }
    foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
        if ([string] $d.DriveType -eq 'Removable' -or [string] $d.DriveType -eq 'Network') { $a.PermanentDrives.Add($d.Name) }
    }
    $a.Downloads = Get-KnownFolder 'Downloads'
    $a.Desktop = Get-KnownFolder 'Desktop'
    if ($AutoDownloads) { $a.Downloads = $AutoDownloads }

    if ($app.Scope -eq 'mine') {
        foreach ($p in (Get-MyFolders)) { $a.Roots.Add($p) }
        foreach ($t in @([System.IO.Path]::GetTempPath(), (Join-Path $env:WINDIR 'Temp'))) { if (Test-Path -LiteralPath $t) { $a.TempRoots.Add($t) } }
        foreach ($d in (Get-UsableDrives @('Fixed'))) { $a.RecycleDrives.Add($d.Name) }
        $app.ScopeTitle = 'My files'
    }
    else {
        $a.Roots.Add($app.Scope)
        if (Test-DriveRoot $app.Scope) {
            $app.ScopeTitle = 'Everything on ' + $app.Scope.TrimEnd('\')
            if (-not $AutoPilot) {
                $a.RecycleDrives.Add($app.Scope)
                if ($app.Scope.TrimEnd('\') -eq $windows.TrimEnd('\')) {
                    foreach ($t in @([System.IO.Path]::GetTempPath(), (Join-Path $env:WINDIR 'Temp'))) { if (Test-Path -LiteralPath $t) { $a.TempRoots.Add($t) } }
                }
            }
        }
        else { $app.ScopeTitle = Format-ShortPath $app.Scope 34 }
    }
    $app.Analyzer = $a
    $app.Category = $null
    $a.Start()
    Write-UiLog ("analysis started: {0}" -f (@($a.Roots) -join '; '))
    if (Test-DriveRoot $app.Scope) { $ui.ScanSubText.Text = 'A whole drive takes a few minutes. Nothing is changed while looking.' }
    else { $ui.ScanSubText.Text = 'This takes a moment. Nothing is changed while looking.' }
    $ui.ScanBusyBar.Visibility = 'Visible'; $ui.ScanBar.Visibility = 'Collapsed'
    Show-Step 'Scan'
    Set-Footer -Back 'Back' -Next 'Stop' -NextStyle 'Secondary'
}

function Update-ScanLive {
    $a = $app.Analyzer
    if (-not $a) { return }
    $ui.ScanPhase.Text = [string] $a.Phase + '...'
    $ui.ScanCount.Text = '{0} files{1}{2}' -f (Format-Count $a.Files), $DOT, (Format-Bytes $a.Bytes)
    $ui.ScanCurrent.Text = [string] $a.Current
    if ($a.Phase -eq 'Finding duplicate files' -and $a.HashTotal -gt 0) {
        $ui.ScanBusyBar.Visibility = 'Collapsed'; $ui.ScanBar.Visibility = 'Visible'
        $ui.ScanBar.Value = [math]::Min(1000, 1000.0 * $a.HashDone / $a.HashTotal)
    }
    if ($a.Done) {
        Write-UiLog ("analysis done: {0} files, {1}, phase {2}, error '{3}'" -f $a.Files, (Format-Bytes $a.Bytes), $a.Phase, $a.Error)
        if ($a.Error) { Show-Message ("Looking at the files stopped because of a problem:`r`n`r`n" + $a.Error) $AppTitle 'Warning'; Show-Step 'Scope'; return }
        if ($a.Phase -eq 'Stopped') { return }
        [System.Media.SystemSounds]::Asterisk.Play()
        Show-Step 'Findings'
    }
}

# ---------------------------------------------------------------------------
# what can go
# ---------------------------------------------------------------------------

function Get-Category { param([string] $Key) return ($app.Analyzer.Categories | Where-Object { $_.Key -eq $Key } | Select-Object -First 1) }

function Get-Selection {
    $s = @{ Count = 0; Bytes = [int64] 0; Items = New-Object System.Collections.ArrayList }
    if (-not $app.Analyzer) { return $s }
    foreach ($c in $app.Analyzer.Categories) {
        foreach ($i in $c.Items) { if ($i.Selected) { $s.Count++; $s.Bytes += $i.Size; [void] $s.Items.Add($i) } }
    }
    return $s
}

function Switch-Category {
    # One click ticks the whole kind - or unticks it when all of it is ticked.
    param([string] $Key)
    $c = Get-Category $Key
    if (-not $c) { return }
    if (-not $c.CanToggleAll) { $app.Category = $c; Show-Step 'Details'; return }
    $all = ($c.SelectedCount -eq $c.Items.Count)
    foreach ($i in $c.Items) { $i.Selected = -not $all }
    Enter-Findings
}

function New-CheckCircle {
    # Ticked, partly ticked or not: a big round tick box, easy to hit.
    param([string] $State)
    $b = New-Object System.Windows.Controls.Border
    $b.Width = 30; $b.Height = 30; $b.CornerRadius = '15'; $b.VerticalAlignment = 'Center'; $b.Margin = '0,0,16,0'
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Style = $window.FindResource('Icon'); $t.FontSize = 14; $t.HorizontalAlignment = 'Center'
    Set-Color $t 'Foreground' 'White'
    switch ($State) {
        'all'  { Set-Color $b 'Background' $TEAL; $t.Text = [string] [char] 0xE73E }
        'some' { Set-Color $b 'Background' $TEAL; $t.Text = [string] [char] 0xE738 }
        default { Set-Color $b 'Background' 'White'; $b.BorderThickness = '2'; Set-Color $b 'BorderBrush' '#CBD5E1' }
    }
    $b.Child = $t
    return $b
}

function New-CategoryCard {
    param($Category)
    $c = $Category
    $count = $c.Items.Count; $sel = $c.SelectedCount
    $state = 'none'; if ($sel -eq $count) { $state = 'all' } elseif ($sel -gt 0) { $state = 'some' }
    $button = New-Object System.Windows.Controls.Button
    $button.Style = $window.FindResource('Tile')
    $button.Margin = '0,0,0,12'; $button.Padding = '20,16'
    $button.CommandParameter = 'cat:' + $c.Key
    if ($sel -gt 0) { $button.Tag = 'selected' }
    $grid = New-Object System.Windows.Controls.Grid
    foreach ($w in 'Auto', 'Auto', '*', 'Auto') {
        $col = New-Object System.Windows.Controls.ColumnDefinition
        $col.Width = (New-Object System.Windows.GridLengthConverter).ConvertFromString($w)
        [void] $grid.ColumnDefinitions.Add($col)
    }
    if ($c.CanToggleAll) { $check = New-CheckCircle $state } else { $check = New-Object System.Windows.Controls.Border; $check.Width = 30; $check.Margin = '0,0,16,0' }
    $accent = $TEAL; $back = '#CCFBF1'
    if ($c.Permanent) { $accent = '#B91C1C'; $back = '#FEE2E2' }
    elseif (-not $c.Recommended) { $accent = '#475569'; $back = '#E2E8F0' }
    $circle = New-IconCircle -Icon $c.Icon -Size 48 -Accent $accent -Back $back
    [System.Windows.Controls.Grid]::SetColumn($circle, 1)
    $texts = New-Object System.Windows.Controls.StackPanel
    $texts.Margin = '16,0,12,0'; $texts.VerticalAlignment = 'Center'
    $titleRow = New-Object System.Windows.Controls.DockPanel
    if ($c.Recommended) { $badge = New-Badge 'Recommended'; [System.Windows.Controls.DockPanel]::SetDock($badge, 'Right'); [void] $titleRow.Children.Add($badge) }
    $size = Format-Bytes $c.TotalBytes
    if ($c.Key -eq 'empty') { $size = Format-Plural $count 'folder' 'folders' }
    [void] $titleRow.Children.Add((New-Text -Text ('{0}  {1}' -f $c.Title, $size) -Size 17 -Weight 'SemiBold'))
    [void] $texts.Children.Add($titleRow)
    [void] $texts.Children.Add((New-Text -Text $c.Text -Size 13 -Color '#64748B' -Margin '0,4,0,0'))
    if ($sel -eq 0) { $state = '{0} - none ticked' -f (Format-Plural $count 'item' 'items') }
    elseif ($sel -eq $count) { $state = 'All {0} ticked' -f (Format-Plural $count 'item' 'items') }
    else { $state = '{0} of {1} ticked ({2})' -f (Format-Count $sel), (Format-Count $count), (Format-Bytes $c.SelectedBytes) }
    [void] $texts.Children.Add((New-Text -Text $state -Size 13 -Color '#334155' -Weight 'SemiBold' -Margin '0,6,0,0'))
    [System.Windows.Controls.Grid]::SetColumn($texts, 2)
    $see = New-Object System.Windows.Controls.Button
    $see.Style = $window.FindResource('Secondary'); $see.Padding = '14,7'; $see.FontSize = 13; $see.VerticalAlignment = 'Center'
    $see.Content = 'See the files'
    if ($c.Key -eq 'recycle') { $see.Content = 'See the drives' }
    if (-not $c.CanToggleAll) { $see.Content = 'Choose files' }
    $see.CommandParameter = 'cat-open:' + $c.Key
    $see.Add_Click({ param($s, $e) $e.Handled = $true; Invoke-Safely { Invoke-Tile ([string] $s.CommandParameter) } })
    [System.Windows.Controls.Grid]::SetColumn($see, 3)
    foreach ($el in $check, $circle, $texts, $see) { [void] $grid.Children.Add($el) }
    $button.Content = $grid
    $button.Add_Click({ param($s, $e) Invoke-Safely { Invoke-Tile ([string] $s.CommandParameter) } })
    return $button
}

function New-UsageRow {
    # One bar of "where your space goes": the name and size in text ink, a single-hue bar
    # (grey for what belongs to Windows and programs, which is never touched).
    param($Usage, [double] $Max, [double] $Total)
    $grid = New-Object System.Windows.Controls.Grid
    $grid.Margin = '0,5'
    $grid.Background = [System.Windows.Media.Brushes]::Transparent
    foreach ($w in '200', '*', '96') {
        $col = New-Object System.Windows.Controls.ColumnDefinition
        $col.Width = (New-Object System.Windows.GridLengthConverter).ConvertFromString($w)
        [void] $grid.ColumnDefinitions.Add($col)
    }
    $name = New-Text -Text $Usage.Name -Size 14
    $name.TextTrimming = 'CharacterEllipsis'; $name.TextWrapping = 'NoWrap'; $name.VerticalAlignment = 'Center'
    $track = New-Object System.Windows.Controls.Grid
    $track.Height = 10; $track.Margin = '12,0'; $track.VerticalAlignment = 'Center'
    $fraction = 0.0; if ($Max -gt 0) { $fraction = [math]::Max(0.004, [double] $Usage.Bytes / $Max) }
    foreach ($w in @($fraction, (1.0 - $fraction))) {
        $col = New-Object System.Windows.Controls.ColumnDefinition
        $col.Width = New-Object System.Windows.GridLength ([math]::Max(0.0, $w)), 'Star'
        [void] $track.ColumnDefinitions.Add($col)
    }
    $bar = New-Object System.Windows.Controls.Border
    $bar.CornerRadius = '4'
    if ($Usage.System) { Set-Color $bar 'Background' '#94A3B8' } else { Set-Color $bar 'Background' $TEAL }
    [void] $track.Children.Add($bar)
    [System.Windows.Controls.Grid]::SetColumn($track, 1)
    $size = New-Text -Text (Format-Bytes $Usage.Bytes) -Size 14 -Color '#334155' -Weight 'SemiBold'
    $size.HorizontalAlignment = 'Right'; $size.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($size, 2)
    foreach ($el in $name, $track, $size) { [void] $grid.Children.Add($el) }
    $pct = 0; if ($Total -gt 0) { $pct = [math]::Round(100.0 * $Usage.Bytes / $Total) }
    $tip = '{0}{1}{2} files, {3} ({4}% of it all)' -f $Usage.Path, "`r`n", (Format-Count $Usage.Files), (Format-Bytes $Usage.Bytes), $pct
    if ($Usage.System) { $tip += "`r`nWindows or programs - never touched here" }
    $grid.ToolTip = $tip
    return $grid
}

function Show-Usage {
    $ui.UsageList.Children.Clear()
    $a = $app.Analyzer
    $list = @($a.Usage | Where-Object { $_.Bytes -gt 0 })
    $total = [double] 0; foreach ($u in $list) { $total += $u.Bytes }
    $top = @($list | Select-Object -First 8)
    $rest = @($list | Select-Object -Skip 8)
    if ($rest.Count -gt 0) {
        $other = New-Object SmartCleanup.Usage
        $other.Name = 'Everything else'; $other.Path = ('{0} more folders' -f $rest.Count)
        foreach ($u in $rest) { $other.Bytes += $u.Bytes; $other.Files += $u.Files }
        $top += $other
    }
    $max = [double] 0; foreach ($u in $top) { if ($u.Bytes -gt $max) { $max = $u.Bytes } }
    foreach ($u in $top) { [void] $ui.UsageList.Children.Add((New-UsageRow $u $max $total)) }
    $note = '{0} in {1} looked at.' -f (Format-Bytes $total), (Format-Plural $a.Files 'file' 'files')
    if (@($top | Where-Object { $_.System }).Count -gt 0) { $note += ' Grey: Windows and programs - never touched here.' }
    if ($a.OnlineOnlyFiles -gt 0) { $note += (' {0} only in the cloud (OneDrive) take no space here and are left out.' -f (Format-Plural $a.OnlineOnlyFiles 'file is' 'files are')) }
    if ($a.Denied -gt 0) { $note += (' {0} could not be opened (no permission).' -f (Format-Plural $a.Denied 'folder' 'folders')) }
    $ui.UsageNote.Text = $note
    $visible = 'Visible'; if ($top.Count -eq 0) { $visible = 'Collapsed' }
    $ui.UsageHeading.Visibility = $visible; $ui.UsageList.Parent.Visibility = $visible
}

function Enter-Findings {
    $a = $app.Analyzer
    $ui.CategoryList.Children.Clear()
    $found = @($a.Categories | Where-Object { $_.Items.Count -gt 0 })
    foreach ($c in $found) { [void] $ui.CategoryList.Children.Add((New-CategoryCard $c)) }
    $sel = Get-Selection
    $possible = [int64] 0; foreach ($c in $found) { $possible += $c.TotalBytes }
    if ($found.Count -eq 0) {
        $ui.FindHeading.Text = 'Nothing to clean up here'
        $ui.FindSubText.Text = 'No duplicates, junk or leftovers found. Below is where the space goes.'
        [void] $ui.CategoryList.Children.Add((New-InfoCard -Icon ([string] [char] 0xE73E) -Title 'All tidy' -Text 'Windows'' own files (updates, older versions of Windows) are cleaned up by Windows itself.' -Tone 'green' -ButtonText 'Open Storage settings' -ButtonAction 'storage:'))
    }
    elseif ($sel.Count -gt 0) {
        $ui.FindHeading.Text = 'You can free up ' + (Format-Bytes $sel.Bytes)
        $ui.FindSubText.Text = 'The ticked suggestions are safe to remove. Click a suggestion to tick or untick it, or See the files to choose file by file.'
        if ($possible -gt $sel.Bytes) { $ui.FindSubText.Text += (' Up to {0} more if you choose from the rest.' -f (Format-Bytes ($possible - $sel.Bytes))) }
    }
    else {
        $ui.FindHeading.Text = 'Nothing ticked yet'
        $ui.FindSubText.Text = ('Up to {0} could go. Click a suggestion to tick it.' -f (Format-Bytes $possible))
    }
    Show-Usage
    $next = 'Clean up'
    if ($sel.Bytes -gt 0) { $next = 'Clean up ' + (Format-Bytes $sel.Bytes) }
    Set-Footer -Next $next -NextEnabled ($sel.Count -gt 0) -Text ('{0} ticked' -f (Format-Plural $sel.Count 'item' 'items'))
}

function Enter-Details {
    $c = $app.Category
    $ui.DetailHeading.Text = $c.Title
    $ui.DetailText.Text = $c.Text
    $ui.DetailGrid.ItemsSource = $null
    $ui.DetailGrid.ItemsSource = $c.Items
    Update-DetailsFooter
}

function Update-DetailsFooter {
    $c = $app.Category
    if (-not $c) { return }
    $text = '{0} of {1} ticked{2}{3}' -f (Format-Count $c.SelectedCount), (Format-Count $c.Items.Count), $DOT, (Format-Bytes $c.SelectedBytes)
    if ($ui.FooterText.Text -ne $text -or $ui.NextButton.Content -ne 'Done') { Set-Footer -Next 'Done' -Text $text }
}

function Show-InFolder {
    param($Item)
    if (-not $Item -or $AutoPilot) { return }
    if ($Item.IsRecycleBin) { Start-Process 'shell:RecycleBinFolder'; return }
    if (Test-Path -LiteralPath $Item.Path) { Start-Process explorer.exe ('/select,"{0}"' -f $Item.Path) }
}

# ---------------------------------------------------------------------------
# clean up
# ---------------------------------------------------------------------------

function Enter-Confirm {
    $ui.ConfirmRows.Children.Clear()
    $sel = Get-Selection
    $chosen = @($app.Analyzer.Categories | Where-Object { $_.SelectedCount -gt 0 })
    $recycled = [int64] 0; $gone = [int64] 0; $permanentFiles = 0; $emptiesBin = $false
    for ($n = 0; $n -lt $chosen.Count; $n++) {
        $c = $chosen[$n]
        $where = 'To the Recycle Bin - you can put it back'
        $hard = @($c.Items | Where-Object { $_.Selected -and $_.Permanent })
        if ($c.Key -eq 'recycle') { $where = 'Emptied - this cannot be undone'; $emptiesBin = $true }
        elseif ($c.Key -eq 'temp') { $where = 'Removed for good - nothing needs them' }
        elseif ($hard.Count -gt 0) { $where = ('{0} on a drive without a Recycle Bin: removed for good' -f (Format-Plural $hard.Count 'file is' 'files are')); $permanentFiles += $hard.Count }
        foreach ($i in $c.Items) { if ($i.Selected) { if ($i.Permanent) { $gone += $i.Size } else { $recycled += $i.Size } } }
        $value = '{0}, {1}' -f (Format-Plural $c.SelectedCount 'item' 'items'), (Format-Bytes $c.SelectedBytes)
        if ($c.Key -eq 'empty') { $value = Format-Plural $c.SelectedCount 'empty folder' 'empty folders' }
        $accent = $TEAL; $back = '#CCFBF1'
        if ($c.Permanent -or $hard.Count -gt 0) { $accent = '#B91C1C'; $back = '#FEE2E2' }
        [void] $ui.ConfirmRows.Children.Add((New-FactRow -Icon $c.Icon -Label $c.Title -Value $value -Detail $where -Change 'Findings' -Accent $accent -AccentBack $back -Last:($n -eq $chosen.Count - 1)))
    }
    $ui.ConfirmHeading.Text = 'Clean up ' + (Format-Bytes $sel.Bytes) + '?'
    $note = ''
    if ($recycled -gt 0) { $note = ('{0} goes to the Recycle Bin, so anything can still be put back. Windows gives that space back once the Recycle Bin is emptied - the next screen offers that. ' -f (Format-Bytes $recycled)) }
    if ($gone -gt 0) { $note += ('{0} is removed for good.' -f (Format-Bytes $gone)) }
    $note += ' Every file is checked once more just before it goes: anything that changed in the meantime stays.'
    $ui.ConfirmNote.Text = $note.Trim()
    $ui.ConfirmCheck.IsChecked = $false
    if ($permanentFiles -gt 0) {
        $ui.ConfirmCheck.Visibility = 'Visible'
        $ui.ConfirmCheckText.Text = ('I understand that {0} cannot be put back.' -f (Format-Plural $permanentFiles 'file on a drive without a Recycle Bin' 'files on drives without a Recycle Bin'))
    }
    else { $ui.ConfirmCheck.Visibility = 'Collapsed' }
    $app.ConfirmEmptiesBin = $emptiesBin
    Update-ConfirmFooter
}

function Update-ConfirmFooter {
    $sel = Get-Selection
    $ok = ($sel.Count -gt 0) -and ($ui.ConfirmCheck.Visibility -ne 'Visible' -or [bool] $ui.ConfirmCheck.IsChecked)
    Set-Footer -Next ('Clean up ' + (Format-Bytes $sel.Bytes)) -NextEnabled $ok -NextStyle 'Danger'
}

function Start-Clean {
    $sel = Get-Selection
    if ($sel.Count -eq 0) { return }
    if ($app.ConfirmEmptiesBin -and -not (Confirm-Action "Empty the Recycle Bin?`r`n`r`nThe files in it cannot be put back afterwards." 'Empty the Recycle Bin?' 'Warning')) { return }
    $c = New-Object SmartCleanup.Cleaner
    $c.NoRecycle = [bool] $AutoPilot
    foreach ($i in $sel.Items) { $c.Items.Add($i) }
    $app.Cleaner = $c
    $c.Start()
    Write-UiLog ("clean-up started: {0} items, {1}" -f $sel.Count, (Format-Bytes $sel.Bytes))
    $ui.WorkHeading.Text = 'Cleaning up'
    $ui.WorkSubText.Text = 'Every file is checked once more just before it goes.'
    $ui.WorkPercent.Text = '0%'; $ui.WorkBar.Value = 0; $ui.WorkAmounts.Text = ''; $ui.WorkCurrent.Text = ''
    Show-Step 'Work'
    Set-Footer -Back '' -Next 'Cleaning up...' -NextEnabled $false
}

function Update-CleanLive {
    $c = $app.Cleaner
    $fraction = 0.0; if ($c.Total -gt 0) { $fraction = [double] $c.DoneCount / [double] $c.Total }
    $ui.WorkPercent.Text = '{0}%' -f [int] [math]::Floor($fraction * 100)
    $ui.WorkBar.Value = $fraction * 1000
    $ui.WorkAmounts.Text = '{0} of {1}' -f (Format-Count $c.DoneCount), (Format-Plural $c.Total 'item' 'items')
    $ui.WorkCurrent.Text = [string] $c.Current
    if ($c.Done) { Complete-Clean }
}

function Complete-Clean {
    $c = $app.Cleaner
    Write-UiLog ("clean-up done: recycled {0}, freed {1}, error '{2}'" -f (Format-Bytes $c.Recycled), (Format-Bytes $c.Freed), $c.Error)
    foreach ($i in $c.Items) { if ($i.Status -notmatch '^(In the Recycle Bin|Removed|Emptied)$') { Write-UiLog ("  {0}: {1}" -f $i.Path, $i.Status) } }
    $app.Recycled = [int64] $c.Recycled
    $ui.DoneFacts.Children.Clear(); $ui.DoneExtra.Children.Clear()
    $rows = @()
    foreach ($cat in $app.Analyzer.Categories) {
        if (-not $c.Results.ContainsKey($cat.Key)) { continue }
        $r = $c.Results[$cat.Key]
        $value = '{0} removed, {1}' -f (Format-Count $r[0]), (Format-Bytes $r[1])
        if ($cat.Key -eq 'recycle') { $value = 'Emptied, {0} given back' -f (Format-Bytes $r[1]) }
        if ($cat.Key -eq 'empty') { $value = Format-Plural $r[0] 'empty folder removed' 'empty folders removed' }
        $detail = @()
        if ($r[2] -gt 0) { $detail += ('{0} because they changed or moved in the meantime' -f (Format-Plural $r[2] 'item was kept' 'items were kept')) }
        if ($r[3] -gt 0) { $detail += ('{0} (in use by a program?)' -f (Format-Plural $r[3] 'item could not be removed' 'items could not be removed')) }
        $rows += , @($cat, $value, ($detail -join '. '))
    }
    for ($n = 0; $n -lt $rows.Count; $n++) {
        [void] $ui.DoneFacts.Children.Add((New-FactRow -Icon $rows[$n][0].Icon -Label $rows[$n][0].Title -Value $rows[$n][1] -Detail $rows[$n][2] -Accent $TEAL -AccentBack '#CCFBF1' -Last:($n -eq $rows.Count - 1)))
    }
    $ui.DoneFactsCard.Visibility = $(if ($rows.Count -gt 0) { 'Visible' } else { 'Collapsed' })
    $total = [int64] $c.Recycled + [int64] $c.Freed
    $ui.DoneHeading.Text = 'Done - {0} cleaned up' -f (Format-Bytes $total)
    if ($c.Freed -gt 0 -and $c.Recycled -gt 0) { $ui.DoneText.Text = '{0} is free again right away; {1} is in the Recycle Bin.' -f (Format-Bytes $c.Freed), (Format-Bytes $c.Recycled) }
    elseif ($c.Recycled -gt 0) { $ui.DoneText.Text = 'Everything removed is in the Recycle Bin, so you can still put it back.' }
    else { $ui.DoneText.Text = 'That space is free again.' }
    if ($c.Error) { $ui.DoneText.Text += ' It stopped early: ' + $c.Error }
    Set-Color $ui.DoneIconBack 'Background' '#16A34A'; $ui.DoneIcon.Text = [string] [char] 0xE73E
    if ($c.Recycled -gt 0) {
        [void] $ui.DoneExtra.Children.Add((New-InfoCard -Icon ([string] [char] 0xE74D) -Title ('{0} is now in the Recycle Bin' -f (Format-Bytes $c.Recycled)) -Text 'Windows gives the space back once the Recycle Bin is emptied. Until then, you can put anything back from it.' -Tone 'blue' -ButtonText 'Empty the Recycle Bin now' -ButtonAction 'empty-bin:'))
    }
    [void] $ui.DoneExtra.Children.Add((New-InfoCard -Icon ([string] [char] 0xE946) -Title 'Windows'' own files' -Text 'Update leftovers and older versions of Windows are cleaned up by Windows itself, in Storage settings.' -Tone 'blue' -ButtonText 'Open Storage settings' -ButtonAction 'storage:'))
    [System.Media.SystemSounds]::Asterisk.Play()
    Show-Step 'Done'
    Set-Footer -Back '' -Next 'Start over' -Alt 'Look again'
}

function Clear-RecycleBins {
    if (-not (Confirm-Action "Empty the Recycle Bin?`r`n`r`nThe files in it - also what was removed just now - cannot be put back afterwards." 'Empty the Recycle Bin?' 'Warning')) { return }
    if ($AutoPilot) { Write-UiLog 'would empty the Recycle Bin (not in a test run)'; return }
    $window.Cursor = [System.Windows.Input.Cursors]::Wait
    $freed = [int64] 0
    try {
        foreach ($d in (Get-UsableDrives @('Fixed'))) {
            $before = [SmartCleanup.RecycleBin]::Size($d.Name)[0]
            if ($before -le 0) { continue }
            [SmartCleanup.RecycleBin]::EmptyBin($d.Name)
            $after = [math]::Max([int64] 0, [SmartCleanup.RecycleBin]::Size($d.Name)[0])
            $freed += [math]::Max([int64] 0, $before - $after)
        }
    }
    finally { $window.Cursor = $null }
    Write-UiLog ("emptied the Recycle Bin: {0}" -f (Format-Bytes $freed))
    $ui.DoneExtra.Children.RemoveAt(0)
    $ui.DoneExtra.Children.Insert(0, (New-InfoCard -Icon ([string] [char] 0xE73E) -Title ('Recycle Bin emptied - {0} given back' -f (Format-Bytes $freed)) -Tone 'green'))
}

# ---------------------------------------------------------------------------
# organize a folder
# ---------------------------------------------------------------------------

function Get-LooseCount {
    param([string] $Path)
    try { return @((New-Object System.IO.DirectoryInfo($Path)).GetFiles() | Where-Object { -not ($_.Attributes -band [System.IO.FileAttributes]::Hidden) }).Count } catch { return 0 }
}

function Enter-OrgFolder {
    $ui.OrgFolderTiles.Children.Clear()
    $shown = @{}
    if ($app.OrgFolder) {
        [void] $ui.OrgFolderTiles.Children.Add((New-Tile -Action ('orgfolder:' + $app.OrgFolder) -Icon ([string] [char] 0xF12B) -Title (Split-Path -Leaf $app.OrgFolder) -Text $app.OrgFolder -Extra (Format-Plural (Get-LooseCount $app.OrgFolder) 'loose file' 'loose files') -Accent '#7C3AED' -AccentBack '#EDE9FE' -Wide -Selected))
        $shown[$app.OrgFolder.ToLowerInvariant()] = $true
    }
    if (-not $AutoPilot) {
        foreach ($n in 'Downloads', 'Desktop', 'Documents') {
            $p = Get-KnownFolder $n
            if (-not $p -or -not (Test-Path -LiteralPath $p) -or $shown.ContainsKey($p.ToLowerInvariant())) { continue }
            $icon = [char] 0xF12B; if ($n -eq 'Downloads') { $icon = [char] 0xE896 } elseif ($n -eq 'Desktop') { $icon = [char] 0xE7F4 }
            [void] $ui.OrgFolderTiles.Children.Add((New-Tile -Action ('orgfolder:' + $p) -Icon ([string] $icon) -Title $n -Text (Format-Plural (Get-LooseCount $p) 'loose file' 'loose files') -Accent '#7C3AED' -AccentBack '#EDE9FE' -Wide))
        }
    }
    [void] $ui.OrgFolderTiles.Children.Add((New-Tile -Action 'orgfolder:?' -Icon ([string] [char] 0xED25) -Title 'Choose a folder...' -Text 'Any folder on this PC.' -Wide))
    Set-Footer -Next 'Continue' -NextEnabled ([bool] $app.OrgFolder)
}

function Select-OrgFolder {
    param([string] $Value)
    if ($Value -eq '?') {
        $Value = Select-FolderDialog 'Choose the folder to tidy up. Its loose files are sorted into folders.' $app.OrgFolder
        if (-not $Value) { return }
    }
    if ($Value -ne $app.OrgFolder) { $app.OrgPlan = $null }
    $app.OrgFolder = $Value
    Show-Step 'OrgHow'
}

function Enter-OrgHow {
    $ui.OrgHowTiles.Children.Clear()
    $ui.OrgHowSubText.Text = ('{0} in {1}. You can undo it afterwards.' -f (Format-Plural (Get-LooseCount $app.OrgFolder) 'loose file' 'loose files'), (Split-Path -Leaf $app.OrgFolder))
    $year = (Get-Date).ToString('yyyy', $Invariant); $month = (Get-Date).ToString('MM MMMM', $Invariant)
    [void] $ui.OrgHowTiles.Children.Add((New-Tile -Action 'orghow:Type' -Icon ([string] [char] 0xF0E2) -Title 'By type' -Text 'Pictures, Videos, Music, Documents, Archives, Installers, Code, Other.' -Extra 'Pictures\holiday.jpg' -Badge 'Most popular' -Accent '#7C3AED' -AccentBack '#EDE9FE' -Selected:($app.OrgMode -eq 'Type')))
    [void] $ui.OrgHowTiles.Children.Add((New-Tile -Action 'orghow:Date' -Icon ([string] [char] 0xE787) -Title 'By date' -Text 'A folder per year, and one per month inside it - by when each file last changed.' -Extra "$year\$month\holiday.jpg" -Accent '#7C3AED' -AccentBack '#EDE9FE' -Selected:($app.OrgMode -eq 'Date')))
    [void] $ui.OrgHowTiles.Children.Add((New-Tile -Action 'orghow:TypeDate' -Icon ([string] [char] 0xE8CB) -Title 'By type, then year' -Text 'Like by type, with a folder per year inside each.' -Extra "Pictures\$year\holiday.jpg" -Accent '#7C3AED' -AccentBack '#EDE9FE' -Selected:($app.OrgMode -eq 'TypeDate')))
    Set-Footer -Next 'Continue' -NextEnabled ([bool] $app.OrgMode)
}

function Enter-OrgPreview {
    $plan = [SmartCleanup.Organizer]::Plan($app.OrgFolder, $app.OrgMode)
    $app.OrgPlan = $plan
    $ui.OrgGroups.Children.Clear()
    $leaf = Split-Path -Leaf $app.OrgFolder
    if ($plan.Moves.Count -eq 0) {
        $ui.OrgPreviewHeading.Text = 'Nothing to sort'
        $ui.OrgPreviewSubText.Text = ('There are no loose files in {0} to sort.' -f $leaf)
        $ui.OrgGroupsCard.Visibility = 'Collapsed'
    }
    else {
        $ui.OrgPreviewHeading.Text = '{0} go into {1}' -f (Format-Plural $plan.Moves.Count 'file' 'files'), (Format-Plural $plan.Groups.Count 'folder' 'folders')
        $ui.OrgPreviewSubText.Text = ('Inside {0}. Folders that are already there are used; a file never replaces another one with the same name.' -f (Format-ShortPath $app.OrgFolder 70))
        $ui.OrgGroupsCard.Visibility = 'Visible'
        for ($n = 0; $n -lt $plan.Groups.Count; $n++) {
            $g = $plan.Groups[$n]
            $examples = $g.Examples
            if ($g.Files -gt 3) { $examples += (' and {0} more' -f ($g.Files - 3)) }
            [void] $ui.OrgGroups.Children.Add((New-FactRow -Icon $g.Icon -Label '' -Value ('{0}  -  {1}, {2}' -f $g.Name, (Format-Plural $g.Files 'file' 'files'), (Format-Bytes $g.Bytes)) -Detail $examples -Accent '#7C3AED' -AccentBack '#EDE9FE' -Last:($n -eq $plan.Groups.Count - 1)))
        }
    }
    $note = 'You can undo the whole sorting afterwards with one click.'
    if ($plan.Skipped -gt 0) { $note = ('{0} stay where they are: shortcuts, hidden files and unfinished downloads. ' -f (Format-Plural $plan.Skipped 'file' 'files')) + $note }
    $ui.OrgNote.Text = $note
    Set-Footer -Next ('Sort ' + (Format-Plural $plan.Moves.Count 'file' 'files')) -NextEnabled ($plan.Moves.Count -gt 0)
}

function Start-Sort {
    $plan = $app.OrgPlan
    if (-not $plan -or $plan.Moves.Count -eq 0) { return }
    $log = Join-Path $app.OrgFolder ('.smart-organizer\sorted-{0}.txt' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $app.Org = $plan; $app.OrgLog = $log; $app.OrgUndo = $false
    $plan.Start($log)
    Write-UiLog ("sorting {0} files in {1} ({2})" -f $plan.Moves.Count, $app.OrgFolder, $app.OrgMode)
    $ui.WorkHeading.Text = 'Sorting the files'
    $ui.WorkSubText.Text = 'Every move is written down, so it can be undone.'
    $ui.WorkPercent.Text = '0%'; $ui.WorkBar.Value = 0; $ui.WorkAmounts.Text = ''; $ui.WorkCurrent.Text = ''
    Show-Step 'Work'
    Set-Footer -Back '' -Next 'Sorting...' -NextEnabled $false
}

function Start-Undo {
    param([string] $Log)
    if (-not $Log -or -not (Test-Path -LiteralPath $Log)) { Show-Message 'There is nothing to undo any more.'; return }
    if ($app.Task -ne 'Organize') { $app.Task = 'Organize'; $script:STAGES = $ORG_STAGES; Initialize-StageList }
    if (-not $app.OrgFolder) { $app.OrgFolder = Split-Path -Parent (Split-Path -Parent $Log) }
    $app.Org = [SmartCleanup.Organizer]::Undo($Log)
    $app.OrgUndo = $true; $app.OrgLog = $Log
    Write-UiLog "undoing the sorting: $Log"
    $ui.WorkHeading.Text = 'Putting the files back'
    $ui.WorkSubText.Text = 'Every file goes back where it was. Folders the sorting made are removed when they are empty again.'
    $ui.WorkPercent.Text = ''; $ui.WorkBar.Value = 0; $ui.WorkAmounts.Text = ''; $ui.WorkCurrent.Text = ''
    Show-Step 'Work'
    Set-Footer -Back '' -Next 'Putting back...' -NextEnabled $false
}

function Update-OrgLive {
    $o = $app.Org
    $total = [math]::Max(1, $o.Moves.Count)
    if ($app.OrgUndo) { $ui.WorkAmounts.Text = '{0} put back' -f (Format-Plural $o.MovedCount 'file' 'files') }
    else {
        $fraction = [double] ($o.MovedCount + $o.Failed) / $total
        $ui.WorkPercent.Text = '{0}%' -f [int] [math]::Floor($fraction * 100)
        $ui.WorkBar.Value = $fraction * 1000
        $ui.WorkAmounts.Text = '{0} of {1} sorted' -f (Format-Count $o.MovedCount), (Format-Count $o.Moves.Count)
    }
    $ui.WorkCurrent.Text = [string] $o.Current
    if ($o.Done) { Complete-Org }
}

function Complete-Org {
    $o = $app.Org
    $ui.DoneFacts.Children.Clear(); $ui.DoneExtra.Children.Clear()
    Set-Color $ui.DoneIconBack 'Background' '#16A34A'; $ui.DoneIcon.Text = [string] [char] 0xE73E
    if ($app.OrgUndo) {
        Write-UiLog ("undo done: {0} back, {1} failed, error '{2}'" -f $o.MovedCount, $o.Failed, $o.Error)
        $settings.LastSortLog = ''; $settings.LastSortFolder = ''; Save-Settings
        $ui.DoneHeading.Text = 'Back as it was'
        $ui.DoneText.Text = ('{0} back where they were in {1}.' -f (Format-Plural $o.MovedCount 'file is' 'files are'), (Format-ShortPath $app.OrgFolder 70))
        if ($o.Failed -gt 0) { $ui.DoneText.Text += (' {0} could not be put back - moved or in use.' -f (Format-Plural $o.Failed 'file' 'files')) }
        $ui.DoneFactsCard.Visibility = 'Collapsed'
        Show-Step 'Done'
        Set-Footer -Back '' -Next 'Start over' -Alt 'Open the folder'
        return
    }
    Write-UiLog ("sorting done: {0} moved, {1} failed, error '{2}'" -f $o.MovedCount, $o.Failed, $o.Error)
    $settings.LastSortLog = $app.OrgLog; $settings.LastSortFolder = $app.OrgFolder; Save-Settings
    $ui.DoneHeading.Text = 'Sorted {0}' -f (Format-Plural $o.MovedCount 'file' 'files')
    $ui.DoneText.Text = ('{0} is tidy. Changed your mind? Undo puts every file back.' -f (Format-ShortPath $app.OrgFolder 70))
    if ($o.Failed -gt 0) { $ui.DoneText.Text += (' {0} stayed where they were (in use by a program?).' -f (Format-Plural $o.Failed 'file' 'files')) }
    for ($n = 0; $n -lt $o.Groups.Count; $n++) {
        $g = $o.Groups[$n]
        [void] $ui.DoneFacts.Children.Add((New-FactRow -Icon $g.Icon -Label '' -Value ('{0}  -  {1}' -f $g.Name, (Format-Plural $g.Files 'file' 'files')) -Accent '#7C3AED' -AccentBack '#EDE9FE' -Last:($n -eq $o.Groups.Count - 1)))
    }
    $ui.DoneFactsCard.Visibility = $(if ($o.Groups.Count -gt 0) { 'Visible' } else { 'Collapsed' })
    [System.Media.SystemSounds]::Asterisk.Play()
    Show-Step 'Done'
    Set-Footer -Back '' -Next 'Start over' -Alt 'Undo'
}

# ---------------------------------------------------------------------------
# buttons
# ---------------------------------------------------------------------------

$ui.BackButton.Add_Click({ Invoke-Safely { Invoke-Back } })
$ui.NextButton.Add_Click({ Invoke-Safely { Invoke-Next } })
$ui.AltButton.Add_Click({ Invoke-Safely { Invoke-Alt } })
$ui.OpenLogButton.Add_Click({ Invoke-Safely { Open-Path $LogPath } })
$ui.DetailAllButton.Add_Click({ Invoke-Safely { foreach ($i in $app.Category.Items) { $i.Selected = $true } } })
$ui.DetailNoneButton.Add_Click({ Invoke-Safely { foreach ($i in $app.Category.Items) { $i.Selected = $false } } })
$ui.DetailShowButton.Add_Click({ Invoke-Safely { Show-InFolder $ui.DetailGrid.SelectedItem } })
$ui.DetailGrid.Add_MouseDoubleClick({ Invoke-Safely { Show-InFolder $ui.DetailGrid.SelectedItem } })
$ui.ConfirmCheck.Add_Click({ Invoke-Safely { Update-ConfirmFooter } })

$window.Add_PreviewKeyDown({ param($s, $e)
    if ($e.Key -eq 'Escape' -or $e.SystemKey -eq 'Left') {
        if ($ui.BackButton.Visibility -eq 'Visible' -and $ui.BackButton.IsEnabled) { $e.Handled = $true; Invoke-Safely { Invoke-Back } }
    }
})

$window.Add_Closing({
    param($s, $e)
    if ($app.ForceClose) { return }
    if (Test-Busy) {
        if (-not (Confirm-Action 'It is still working. Stop and close? Everything done so far stays done.')) { $e.Cancel = $true; return }
    }
    if ($app.Analyzer) { $app.Analyzer.Cancel = $true }
    if ($app.Cleaner) { $app.Cleaner.Cancel = $true }
})

# ---------------------------------------------------------------------------
# testing aid: answer every question by itself and take screenshots
# ---------------------------------------------------------------------------

$auto = @{ Stage = 'start'; Since = [DateTime]::UtcNow; Started = [DateTime]::UtcNow; Log = New-Object System.Collections.ArrayList; Shot = 0 }

function Step-AutoPilot {
    $elapsed = ([DateTime]::UtcNow - $auto.Since).TotalSeconds
    $next = { param($s) $auto.Stage = $s; $auto.Since = [DateTime]::UtcNow; [void] $auto.Log.Add("$([DateTime]::Now.ToString('HH:mm:ss')) -> $s (page $($app.Page))") }
    switch ($auto.Stage) {
        'start' {
            if ($elapsed -lt 1.5) { return }
            Save-Screenshot 'task'
            if ($AutoTask -eq 'Organize') { Invoke-Tile 'task:Organize'; & $next 'orgfolder' }
            else { $app.Scope = $Folder; Invoke-Tile 'task:Clean'; & $next 'scope' }
        }
        'scope' {
            if ($elapsed -lt 1) { return }
            Save-Screenshot 'scope'
            Invoke-Tile ('scope:' + $Folder)
            & $next 'scan'
        }
        'scan' {
            if ($app.Page -eq 'Scan' -and $elapsed -gt 0.3 -and -not $auto.Scanned) { $auto.Scanned = $true; Save-Screenshot 'looking' }
            if ($app.Page -ne 'Findings' -or $elapsed -lt 1) { return }
            Save-Screenshot 'findings'
            $ui.FindScroll.ScrollToEnd(); $window.UpdateLayout(); Save-Screenshot 'findings-usage'; $ui.FindScroll.ScrollToHome()
            $first = @($app.Analyzer.Categories | Where-Object { $_.Items.Count -gt 0 }) | Select-Object -First 1
            if (-not $first) { & $next 'finish'; return }
            Invoke-Tile ('cat-open:' + $first.Key)
            & $next 'details'
        }
        'details' {
            if ($elapsed -lt 1) { return }
            Save-Screenshot 'details'
            Invoke-Click $ui.BackButton
            # untick a whole kind and tick it again through the cards
            $k = (@($app.Analyzer.Categories | Where-Object { $_.Items.Count -gt 0 -and $_.CanToggleAll }) | Select-Object -First 1).Key
            Invoke-Tile "cat:$k"; Invoke-Tile "cat:$k"
            [void] $auto.Log.Add(('ticked after toggling twice: {0}' -f (Get-Selection).Count))
            Invoke-Click $ui.NextButton
            & $next 'confirm'
        }
        'confirm' {
            if ($elapsed -lt 1) { return }
            Save-Screenshot 'confirm'
            if ($ui.ConfirmCheck.Visibility -eq 'Visible') { $ui.ConfirmCheck.IsChecked = $true; Update-ConfirmFooter }
            Invoke-Click $ui.NextButton
            & $next 'cleaning'
        }
        'cleaning' {
            if ($app.Page -eq 'Done' -and $elapsed -gt 1) { Save-Screenshot 'done'; & $next 'finish' }
        }
        'orgfolder' {
            if ($elapsed -lt 1) { return }
            Save-Screenshot 'org-folder'
            Invoke-Tile ('orgfolder:' + $Folder)
            & $next 'orghow'
        }
        'orghow' {
            if ($elapsed -lt 1) { return }
            Save-Screenshot 'org-how'
            Invoke-Tile 'orghow:Type'
            & $next 'orgpreview'
        }
        'orgpreview' {
            if ($elapsed -lt 1) { return }
            Save-Screenshot 'org-preview'
            Invoke-Click $ui.NextButton
            & $next 'orgdone'
        }
        'orgdone' {
            if ($app.Page -ne 'Done' -or $elapsed -lt 1) { return }
            Save-Screenshot 'org-done'
            [void] $auto.Log.Add(('sorted: {0}' -f (@(Get-ChildItem -LiteralPath $Folder -Directory | ForEach-Object { $_.Name }) -join ', ')))
            Invoke-Click $ui.AltButton   # Undo
            & $next 'orgundo'
        }
        'orgundo' {
            if ($app.Page -ne 'Done' -or -not $app.OrgUndo -or -not $app.Org.Done -or $elapsed -lt 1) { return }
            Save-Screenshot 'org-undone'
            [void] $auto.Log.Add(('after undo: {0}' -f (@(Get-ChildItem -LiteralPath $Folder | Where-Object { $_.Name -ne '.smart-organizer' } | ForEach-Object { $_.Name }) -join ', ')))
            & $next 'finish'
        }
        'finish' {
            if ($ScreenshotDir) {
                $result = @{ Stages = @($auto.Log); Page = $app.Page }
                if ($app.Analyzer) { $result.Categories = @($app.Analyzer.Categories | Where-Object { $_.Items.Count -gt 0 } | ForEach-Object { @{ Key = $_.Key; Items = $_.Items.Count; Ticked = $_.SelectedCount } }) }
                if ($app.Cleaner) { $result.Statuses = @($app.Cleaner.Items | ForEach-Object { '{0}: {1}' -f $_.Path, $_.Status }) }
                New-Item -ItemType Directory -Force -Path $ScreenshotDir | Out-Null
                [System.IO.File]::WriteAllText((Join-Path $ScreenshotDir 'result.json'), ($result | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
            }
            $auto.Stage = 'closing'
            $app.ForceClose = $true
            $window.Close()
        }
    }
}

# ---------------------------------------------------------------------------
# the heartbeat
# ---------------------------------------------------------------------------

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(200)
$timer.Add_Tick({
    try {
        switch ($app.Page) {
            'Scan'    { Update-ScanLive }
            'Details' { Update-DetailsFooter }
            'Work'    { if ($app.Task -eq 'Organize') { if ($app.Org) { Update-OrgLive } } elseif ($app.Cleaner) { Update-CleanLive } }
        }
        if ($AutoPilot) {
            if (([DateTime]::UtcNow - $auto.Started).TotalMinutes -gt 5 -and $auto.Stage -ne 'closing') { [void] $auto.Log.Add('gave up after 5 minutes'); $auto.Stage = 'finish' }
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

Initialize-StageList
Show-Step 'Task'
$timer.Start()
Write-UiLog ("cleanup started (autopilot: {0}, folder: '{1}')" -f [bool] $AutoPilot, $Folder)
[void] $window.ShowDialog()
$timer.Stop()
if ($app.Analyzer) { $app.Analyzer.Cancel = $true }
try { $LogWriter.Close() } catch { }
