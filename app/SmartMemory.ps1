<#
.SYNOPSIS
    Smart Memory - shows how full the PC's memory is, and frees it up the ways that really
    work: closing apps you do not need, stopping apps from starting with Windows, and a quick
    tidy-up before starting something heavy.

.DESCRIPTION
    The same kiosk-style window as Smart Transfer and Smart Cleanup: one question per screen,
    Back bottom left, the next step bottom right, every answer in the sidebar.

      Close apps     which apps  ->  close them  ->  how much memory came free
      Startup apps   which apps start with Windows (tick = yes)  ->  saved
      Quick tidy-up  every app hands back memory it is not using right now

    Only this user's own apps are ever offered: Windows, its services and security software
    never are. Apps with windows close as if their X was clicked, so they can still ask to
    save your work; only apps without any window are stopped directly. No administrator
    rights are needed - except to switch off an app that starts for everyone on the PC, which
    asks for them once.

    Start it by double-clicking "Smart Memory.cmd" next to this folder.

.PARAMETER AutoPilot
    Testing aid: answer every question by itself and save a screenshot of each screen. Needs
    -TestAppsFolder (only apps started from that folder are ever listed, closed or tidied) for
    Close and Tidy, and -TestRegistryKey (a key under HKCU playing the part of the startup
    settings) for Startup - a test run never touches real apps or real startup settings.
#>

[CmdletBinding()]
param(
    [switch] $AutoPilot,
    [ValidateSet('Close', 'Startup', 'Tidy')]
    [string] $AutoTask = 'Close',
    [string] $TestAppsFolder = '',
    [string] $TestRegistryKey = '',
    [string] $ScreenshotDir = ''
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework
trap {
    $message = $_.Exception.Message
    try {
        $dir = Join-Path $env:LOCALAPPDATA 'SmartTransfer\logs'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Add-Content -LiteralPath (Join-Path $dir 'startup-errors.log') -Value ('{0}  memory  {1}  {2}' -f (Get-Date), $message, $_.ScriptStackTrace)
    }
    catch { }
    if (-not $AutoPilot) { [void] [System.Windows.MessageBox]::Show("Smart Memory stopped because of a problem:`r`n`r`n$message", 'Smart Memory', 'OK', 'Error') }
    break
}

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    throw 'Please start Smart Memory with "Smart Memory.cmd" (it needs powershell -STA).'
}
if ($AutoPilot -and $AutoTask -ne 'Startup' -and -not $TestAppsFolder) { throw 'The autopilot needs -TestAppsFolder: it never closes or tidies real apps.' }
if ($AutoPilot -and $AutoTask -eq 'Startup' -and -not $TestRegistryKey) { throw 'The autopilot needs -TestRegistryKey: it never changes the real startup settings.' }

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Drawing
if (-not ('IPhoneTransferApp.Native' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'Native.cs') }
if (-not ('SmartMemory.Native' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'Memory.cs') }
$AppTitle = 'Smart Memory'
. (Join-Path $PSScriptRoot 'Common.ps1')

$Invariant = [System.Globalization.CultureInfo]::InvariantCulture
$DOT = ' ' + [char] 0x00B7 + ' '
$CHECK = [string] [char] 0x2713

$LogDir  = Join-Path $env:LOCALAPPDATA 'SmartTransfer\logs'
$LogPath = Join-Path $LogDir ('memory-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogWriter = New-Object System.IO.StreamWriter($LogPath, $true, (New-Object System.Text.UTF8Encoding($false)))
$LogWriter.AutoFlush = $true

function Write-UiLog { param([string] $Text) try { $LogWriter.WriteLine(('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text)) } catch { } }

# Never offered, even when they run as this user: Windows' own parts, security software, and
# what keeps the desktop, the taskbar and typing working.
$PROTECTED = @(
    'explorer', 'dwm', 'csrss', 'winlogon', 'wininit', 'lsass', 'services', 'smss', 'svchost', 'sihost', 'ctfmon', 'fontdrvhost',
    'taskhostw', 'RuntimeBroker', 'ShellExperienceHost', 'StartMenuExperienceHost', 'SearchHost', 'SearchApp', 'TextInputHost',
    'ApplicationFrameHost', 'LockApp', 'dllhost', 'conhost', 'audiodg', 'MsMpEng', 'NisSrv', 'SecurityHealthSystray',
    'SecurityHealthService', 'smartscreen', 'Memory Compression', 'Registry', 'System', 'Idle', 'vmmem', 'vmmemWSL', 'WmiPrvSE',
    'ShellHost', 'Widgets', 'WidgetService', 'CrossDeviceResume', 'PhoneExperienceHost', 'UserOOBEBroker', 'SystemSettingsBroker'
)

# ---------------------------------------------------------------------------
# the window
# ---------------------------------------------------------------------------

$xamlText = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Smart Memory" Width="1180" Height="800" MinWidth="980" MinHeight="680"
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
            <Border Width="40" Height="40" CornerRadius="11" Background="#4F46E5">
              <TextBlock Style="{StaticResource Icon}" Text="&#xE964;" FontSize="20" Foreground="White" HorizontalAlignment="Center"/>
            </Border>
            <StackPanel Margin="12,0,0,0" VerticalAlignment="Center">
              <TextBlock Text="Smart Memory" FontSize="18" FontWeight="SemiBold" Foreground="White"/>
              <TextBlock Text="Free up memory, the honest way" FontSize="12" Foreground="#94A3B8"/>
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
                <TextBlock Text="Your work is safe" Foreground="White" FontSize="12" FontWeight="SemiBold" Margin="8,0,0,0"/>
              </StackPanel>
              <TextBlock Text="Apps close as if you clicked their X, so they can ask to save. Windows itself is never touched."
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

        <!-- how full is the memory, and what to do -->
        <ScrollViewer x:Name="PageHome" VerticalScrollBarVisibility="Auto">
          <StackPanel MaxWidth="920">
            <TextBlock x:Name="HomeHeading" Style="{StaticResource H1}"/>
            <TextBlock x:Name="HomeSubText" Style="{StaticResource Sub}"/>
            <Border Style="{StaticResource Card}" Margin="0,24,0,0" Padding="28,22">
              <StackPanel>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <TextBlock x:Name="GaugePercent" FontSize="52" FontWeight="SemiBold" VerticalAlignment="Center"/>
                  <StackPanel Grid.Column="1" Margin="22,0,0,0" VerticalAlignment="Center">
                    <TextBlock x:Name="GaugeState" FontSize="17" FontWeight="SemiBold"/>
                    <TextBlock x:Name="GaugeText" Foreground="#475569" FontSize="14" Margin="0,4,0,0" TextWrapping="Wrap"/>
                  </StackPanel>
                </Grid>
                <ProgressBar x:Name="GaugeBar" Height="14" Margin="0,16,0,0" Maximum="100"/>
                <TextBlock x:Name="GaugeTop" Foreground="#64748B" FontSize="13" Margin="0,12,0,0" TextWrapping="Wrap"/>
              </StackPanel>
            </Border>
            <TextBlock Text="WHAT WOULD YOU LIKE TO DO?" Foreground="#64748B" FontSize="12" FontWeight="Bold" Margin="4,26,0,4"/>
            <UniformGrid x:Name="TaskTiles" Columns="3" Margin="-8,0,-8,0"/>
          </StackPanel>
        </ScrollViewer>

        <!-- which apps can be closed -->
        <Grid x:Name="PageApps" MaxWidth="920" Visibility="Collapsed">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <StackPanel>
            <TextBlock Text="Which apps can be closed?" Style="{StaticResource H1}"/>
            <TextBlock x:Name="AppsSubText" Style="{StaticResource Sub}"/>
          </StackPanel>
          <Border Grid.Row="1" Style="{StaticResource Card}" Margin="0,20,0,0" Padding="0">
            <Grid>
              <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
              <DockPanel Margin="18,14,18,8">
                <Button x:Name="AppsRefreshButton" DockPanel.Dock="Right" Content="Look again" Style="{StaticResource Link}"/>
                <TextBlock Text="Tick the apps you do not need right now. Biggest first." FontSize="14" Foreground="#475569" VerticalAlignment="Center"/>
              </DockPanel>
              <DataGrid x:Name="AppsGrid" Grid.Row="1" Margin="4,0,4,4">
                <DataGrid.Columns>
                  <DataGridTemplateColumn Header="" Width="48">
                    <DataGridTemplateColumn.CellTemplate>
                      <DataTemplate>
                        <CheckBox IsChecked="{Binding Selected, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                      </DataTemplate>
                    </DataGridTemplateColumn.CellTemplate>
                  </DataGridTemplateColumn>
                  <DataGridTemplateColumn Header="App" Width="3*">
                    <DataGridTemplateColumn.CellTemplate>
                      <DataTemplate>
                        <StackPanel Orientation="Horizontal" Margin="0,6" ToolTip="{Binding Path}">
                          <Image Source="{Binding Icon}" Width="28" Height="28" VerticalAlignment="Center" Margin="0,0,12,0"/>
                          <StackPanel VerticalAlignment="Center">
                            <TextBlock Text="{Binding Name}" FontWeight="SemiBold" FontSize="14"/>
                            <TextBlock Text="{Binding Detail}" Foreground="#64748B" FontSize="12"/>
                          </StackPanel>
                        </StackPanel>
                      </DataTemplate>
                    </DataGridTemplateColumn.CellTemplate>
                  </DataGridTemplateColumn>
                  <DataGridTemplateColumn Header="Memory" Width="2*">
                    <DataGridTemplateColumn.CellTemplate>
                      <DataTemplate>
                        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                          <TextBlock Text="{Binding MemoryText}" FontWeight="SemiBold" Width="80" VerticalAlignment="Center"/>
                          <Border Width="{Binding BarWidth}" Height="8" CornerRadius="4" Background="#4F46E5" VerticalAlignment="Center"/>
                        </StackPanel>
                      </DataTemplate>
                    </DataGridTemplateColumn.CellTemplate>
                  </DataGridTemplateColumn>
                </DataGrid.Columns>
              </DataGrid>
            </Grid>
          </Border>
          <TextBlock x:Name="AppsTip" Grid.Row="2" Foreground="#475569" FontSize="13" TextWrapping="Wrap" Margin="4,12,4,0" Visibility="Collapsed"/>
        </Grid>

        <!-- the last look before closing -->
        <ScrollViewer x:Name="PageConfirm" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
          <StackPanel MaxWidth="920">
            <TextBlock x:Name="ConfirmHeading" Style="{StaticResource H1}"/>
            <TextBlock Text="Save anything you are working on in these apps first. Press Change to go back to the list." Style="{StaticResource Sub}"/>
            <Border Style="{StaticResource Card}" Padding="0" Margin="0,26,0,0">
              <StackPanel x:Name="ConfirmRows"/>
            </Border>
          </StackPanel>
        </ScrollViewer>

        <!-- which apps start with Windows -->
        <Grid x:Name="PageStartup" MaxWidth="920" Visibility="Collapsed">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <StackPanel>
            <TextBlock Text="Which apps should start with Windows?" Style="{StaticResource H1}"/>
            <TextBlock x:Name="StartupSubText" Style="{StaticResource Sub}"/>
          </StackPanel>
          <Border Grid.Row="1" Style="{StaticResource Card}" Margin="0,20,0,0" Padding="0">
            <Grid>
              <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
              <DockPanel Margin="18,14,18,8">
                <Button x:Name="StartupSettingsButton" DockPanel.Dock="Right" Content="More in Windows Settings" Style="{StaticResource Link}"/>
                <TextBlock Text="Ticked = starts by itself. Untick what you can open yourself when you need it." FontSize="14" Foreground="#475569" VerticalAlignment="Center"/>
              </DockPanel>
              <DataGrid x:Name="StartupGrid" Grid.Row="1" Margin="4,0,4,4">
                <DataGrid.Columns>
                  <DataGridTemplateColumn Header="" Width="48">
                    <DataGridTemplateColumn.CellTemplate>
                      <DataTemplate>
                        <CheckBox IsChecked="{Binding Enabled, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                      </DataTemplate>
                    </DataGridTemplateColumn.CellTemplate>
                  </DataGridTemplateColumn>
                  <DataGridTemplateColumn Header="App" Width="3*">
                    <DataGridTemplateColumn.CellTemplate>
                      <DataTemplate>
                        <StackPanel Orientation="Horizontal" Margin="0,6" ToolTip="{Binding Path}">
                          <Image Source="{Binding Icon}" Width="28" Height="28" VerticalAlignment="Center" Margin="0,0,12,0"/>
                          <StackPanel VerticalAlignment="Center">
                            <TextBlock Text="{Binding Name}" FontWeight="SemiBold" FontSize="14"/>
                            <TextBlock Text="{Binding Detail}" Foreground="#64748B" FontSize="12" TextTrimming="CharacterEllipsis"/>
                          </StackPanel>
                        </StackPanel>
                      </DataTemplate>
                    </DataGridTemplateColumn.CellTemplate>
                  </DataGridTemplateColumn>
                  <DataGridTextColumn Header="" Binding="{Binding Badge}" Width="2*" Foreground="#475569"/>
                </DataGrid.Columns>
              </DataGrid>
            </Grid>
          </Border>
          <TextBlock Grid.Row="2" Foreground="#475569" FontSize="13" TextWrapping="Wrap" Margin="4,12,4,0"
                     Text="Unticking only stops an app from starting by itself: it stays installed, and you can still open it whenever you want."/>
        </Grid>

        <!-- quick tidy-up -->
        <ScrollViewer x:Name="PageTidy" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
          <StackPanel MaxWidth="920">
            <TextBlock Text="Quick tidy-up" Style="{StaticResource H1}"/>
            <TextBlock Text="Every app is asked to hand back the memory it is not using right now." Style="{StaticResource Sub}"/>
            <Border Style="{StaticResource Card}" Padding="0" Margin="0,26,0,0">
              <StackPanel x:Name="TidyFacts"/>
            </Border>
          </StackPanel>
        </ScrollViewer>

        <!-- working: closing, saving, tidying -->
        <ScrollViewer x:Name="PageWork" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
          <StackPanel MaxWidth="920">
            <TextBlock x:Name="WorkHeading" Style="{StaticResource H1}"/>
            <TextBlock x:Name="WorkSubText" Style="{StaticResource Sub}"/>
            <Border Style="{StaticResource Card}" Padding="0" Margin="0,26,0,0">
              <ItemsControl x:Name="WorkList">
                <ItemsControl.ItemTemplate>
                  <DataTemplate>
                    <Border Padding="22,14" BorderBrush="#EEF2F7" BorderThickness="0,0,0,1">
                      <DockPanel>
                        <TextBlock DockPanel.Dock="Right" Text="{Binding Status}" Foreground="{Binding StatusColor}" FontWeight="SemiBold" VerticalAlignment="Center"/>
                        <Image Source="{Binding Icon}" Width="24" Height="24" Margin="0,0,12,0"/>
                        <TextBlock Text="{Binding Name}" FontSize="15" FontWeight="SemiBold" VerticalAlignment="Center"/>
                      </DockPanel>
                    </Border>
                  </DataTemplate>
                </ItemsControl.ItemTemplate>
              </ItemsControl>
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
[IPhoneTransferApp.Native]::SetAppId('SmartTransfer.Memory')
$IconPath = Join-Path $PSScriptRoot 'iPhoneTransfer.ico'
if (Test-Path -LiteralPath $IconPath) {
    try { $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create((New-Object System.Uri $IconPath)) } catch { }
}

# ---------------------------------------------------------------------------
# state
# ---------------------------------------------------------------------------

$app = @{
    Page = 'Home'; Task = ''
    Apps = New-Object 'System.Collections.ObjectModel.ObservableCollection[SmartMemory.AppRow]'
    Closing = New-Object 'System.Collections.ObjectModel.ObservableCollection[SmartMemory.AppRow]'
    Startup = New-Object 'System.Collections.ObjectModel.ObservableCollection[SmartMemory.StartupRow]'
    AvailableBefore = [int64] 0; WorkStarted = [DateTime]::MinValue; Working = $false; Result = $null
    LastGauge = [DateTime]::MinValue; ForceClose = $false
}
$ui.AppsGrid.ItemsSource = $app.Apps
$ui.WorkList.ItemsSource = $app.Closing
$ui.StartupGrid.ItemsSource = $app.Startup
$StageUi = New-Object System.Collections.ArrayList
$GREEN = '#15803D'; $AMBER = '#B45309'; $RED = '#B91C1C'; $GRAY = '#64748B'; $INDIGO = '#4F46E5'

$STAGE_SETS = @{
    ''        = @(@{ Title = 'What'; Pages = @('Home'); Go = 'Home' })
    'Close'   = @(
        @{ Title = 'What';  Pages = @('Home');            Go = 'Home' },
        @{ Title = 'Apps';  Pages = @('Apps');            Go = 'Apps' },
        @{ Title = 'Close'; Pages = @('Confirm', 'Work'); Go = 'Confirm' },
        @{ Title = 'Done';  Pages = @('Done');            Go = '' })
    'Startup' = @(
        @{ Title = 'What';         Pages = @('Home');    Go = 'Home' },
        @{ Title = 'Startup apps'; Pages = @('Startup'); Go = 'Startup' },
        @{ Title = 'Done';         Pages = @('Done');    Go = '' })
    'Tidy'    = @(
        @{ Title = 'What';    Pages = @('Home');         Go = 'Home' },
        @{ Title = 'Tidy up'; Pages = @('Tidy', 'Work'); Go = 'Tidy' },
        @{ Title = 'Done';    Pages = @('Done');         Go = '' })
}
$STAGES = $STAGE_SETS['']
$PAGES = @('Home', 'Apps', 'Confirm', 'Startup', 'Tidy', 'Work', 'Done')

# ---------------------------------------------------------------------------
# memory, apps, icons
# ---------------------------------------------------------------------------

function Get-Memory {
    $s = [SmartMemory.Native]::Status()
    $used = $s[0] - $s[1]
    $pct = 0; if ($s[0] -gt 0) { $pct = [int] [math]::Round(100.0 * $used / $s[0]) }
    return @{ Total = [int64] $s[0]; Available = [int64] $s[1]; Used = [int64] $used; Percent = $pct }
}

$IconCache = @{}
function Get-AppIcon {
    param([string] $Path)
    if (-not $Path) { return $null }
    $key = $Path.ToLowerInvariant()
    if ($IconCache.ContainsKey($key)) { return $IconCache[$key] }
    $image = $null
    try {
        $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($Path)
        if ($icon) {
            $image = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon($icon.Handle, [System.Windows.Int32Rect]::Empty, [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
            $image.Freeze()
            $icon.Dispose()
        }
    }
    catch { }
    $IconCache[$key] = $image
    return $image
}

function Get-FriendlyName {
    # What people call the app: its description ("Google Chrome"), else its product name, else
    # the file name.
    param([string] $Path, [string] $Fallback)
    try {
        $v = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
        foreach ($n in @($v.FileDescription, $v.ProductName)) { if ($n -and $n.Trim().Length -gt 1) { return $n.Trim() } }
    }
    catch { }
    return $Fallback
}

function Get-Publisher {
    param([string] $Path)
    try { $c = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Path).CompanyName; if ($c) { return $c.Trim() } } catch { }
    return ''
}

function Test-ClosableProcess {
    # This user's own apps only: same sign-in session, a program file we are allowed to read,
    # not part of Windows and not on the list above. (A test run only sees its own test apps.)
    param($Process, [int] $Session, [string] $Path)
    if ($Process.SessionId -ne $Session -or $Process.Id -eq $PID) { return $false }
    if ($PROTECTED -contains $Process.ProcessName) { return $false }
    if (-not $Path) { return $false }
    if ($TestAppsFolder) { return $Path.StartsWith($TestAppsFolder.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) }
    if ($Path.StartsWith($env:WINDIR.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { return $false }
    # Parts of Windows that live elsewhere (Store-installed pieces like the widgets feed).
    try { if ([System.Diagnostics.FileVersionInfo]::GetVersionInfo($Path).ProductName -like 'Microsoft*Windows*Operating System*') { return $false } } catch { }
    return $true
}

$SMALL = 25MB   # apps using less are not worth closing to free memory: not listed

function Get-RunningApps {
    # Every app with all its processes together - a browser runs dozens - and with the helpers
    # it started itself (VS Code starts language servers, extensions, terminals): those go when
    # the app is closed, and closing one on its own could break the app. Biggest first.
    $session = (Get-Process -Id $PID).SessionId
    $table = [SmartMemory.Native]::ProcessTable()
    $closable = @{}
    foreach ($p in Get-Process) {
        $path = $null
        try { $path = $p.Path } catch { }
        if (Test-ClosableProcess $p $session $path) { $closable[$p.Id] = @{ Process = $p; Path = $path } }
    }
    $groups = @{}
    foreach ($id in @($closable.Keys)) {
        # The top-most closable process this one descends from decides the app it belongs to.
        $top = $id; $walk = $id
        for ($n = 0; $n -lt 12; $n++) {
            $row = $table[$walk]
            if ($null -eq $row) { break }
            $parent = [int] $row[1]
            if ($parent -eq $walk -or -not $closable.ContainsKey($parent)) { break }
            $top = $parent; $walk = $parent
        }
        $owner = $closable[$top]
        $key = $owner.Path.ToLowerInvariant()
        if (-not $groups.ContainsKey($key)) { $groups[$key] = @{ Path = $owner.Path; Name = $owner.Process.ProcessName; Pids = New-Object System.Collections.ArrayList; Bytes = [int64] 0 } }
        $g = $groups[$key]
        [void] $g.Pids.Add($id)
        $b = $null; if ($table.ContainsKey($id)) { $b = $table[$id][0] }
        if ($null -eq $b) { $b = $closable[$id].Process.WorkingSet64 }
        $g.Bytes += [int64] $b
    }
    $rows = New-Object System.Collections.ArrayList
    $script:SmallApps = 0
    foreach ($g in $groups.Values) {
        if ($g.Bytes -lt $SMALL -and -not $TestAppsFolder) { $script:SmallApps++; continue }
        $r = New-Object SmartMemory.AppRow
        $r.Path = $g.Path
        $r.Name = Get-FriendlyName $g.Path $g.Name
        $r.Pids = [int[]] @($g.Pids)
        $r.Bytes = $g.Bytes
        $r.Windows = [SmartMemory.Native]::WindowCount($r.Pids)
        $r.MemoryText = Format-Bytes $g.Bytes
        $r.Icon = Get-AppIcon $g.Path
        if ($r.Windows -eq 0) { $r.Detail = 'Runs in the background (no window)' }
        else { $r.Detail = Format-Plural $r.Windows 'window open' 'windows open' }
        [void] $rows.Add($r)
    }
    return @($rows | Sort-Object { - $_.Bytes })
}

function Update-Gauge {
    $m = Get-Memory
    $ui.GaugePercent.Text = '{0}%' -f $m.Percent
    $ui.GaugeBar.Value = $m.Percent
    if ($m.Percent -ge 85) { $color = $RED; $state = 'Nearly full' } elseif ($m.Percent -ge 70) { $color = $AMBER; $state = 'Getting full' } else { $color = '#16A34A'; $state = 'Plenty free' }
    Set-Color $ui.GaugePercent 'Foreground' $color
    Set-Color $ui.GaugeBar 'Foreground' $color
    $ui.GaugeState.Text = $state
    $ui.GaugeText.Text = '{0} of {1} in use{2}{3} free' -f (Format-Bytes $m.Used), (Format-Bytes $m.Total), $DOT, (Format-Bytes $m.Available)
    return $m
}

# ---------------------------------------------------------------------------
# navigation
# ---------------------------------------------------------------------------

function Test-CanGoBack { return (-not $app.Working -and $app.Page -ne 'Done') }

function Get-StageAnswer {
    param([int] $Index)
    if ($Index -eq 0) {
        switch ($app.Task) { 'Close' { return 'Close apps' } 'Startup' { return 'Startup apps' } 'Tidy' { return 'Quick tidy-up' } }
        return ''
    }
    if ($app.Task -eq 'Close' -and $Index -eq 1) {
        $sel = @($app.Apps | Where-Object { $_.Selected })
        if ($sel.Count -gt 0) { $b = [int64] 0; foreach ($r in $sel) { $b += $r.Bytes }; return ('{0}, {1}' -f (Format-Plural $sel.Count 'app' 'apps'), (Format-Bytes $b)) }
    }
    if ($app.Task -eq 'Startup' -and $Index -eq 1) {
        $changed = @($app.Startup | Where-Object { $_.Enabled -ne $_.WasEnabled }).Count
        if ($changed -gt 0) { return (Format-Plural $changed 'change' 'changes') }
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
        'Home'    { Enter-Home }
        'Apps'    { Enter-Apps }
        'Confirm' { Enter-Confirm }
        'Startup' { Enter-Startup }
        'Tidy'    { Enter-Tidy }
    }
    Update-StageList
    Write-UiLog "page: $Name"
}

function Set-Task {
    param([string] $Task)
    if ($Task -ne $app.Task) {
        $app.Task = $Task
        $script:STAGES = $STAGE_SETS[$Task]
        Initialize-StageList
    }
}

function Invoke-Back {
    switch ($app.Page) {
        'Apps'    { Show-Step 'Home' }
        'Confirm' { Show-Step 'Apps' }
        'Startup' { Show-Step 'Home' }
        'Tidy'    { Show-Step 'Home' }
    }
}

function Invoke-Next {
    switch ($app.Page) {
        'Home'    { if ($app.Task) { Invoke-Tile ('task:' + $app.Task) } }
        'Apps'    { if (@($app.Apps | Where-Object { $_.Selected }).Count -gt 0) { Show-Step 'Confirm' } }
        'Confirm' { Start-Closing }
        'Startup' { Save-Startup }
        'Tidy'    { Start-Tidy }
        'Done'    { $app.Result = $null; Set-Task ''; $app.Task = ''; Show-Step 'Home' }
    }
}

function Invoke-Alt {
    if ($app.Page -eq 'Done' -and $app.DoneAlt) { & $app.DoneAlt }
}

function Invoke-Tile {
    param([string] $Action)
    $parts = @($Action -split ':', 2)
    $kind = $parts[0]; $value = ''
    if ($parts.Count -gt 1) { $value = $parts[1] }
    Write-UiLog "choice: $Action"
    switch ($kind) {
        'task' {
            Set-Task $value
            switch ($value) { 'Close' { Show-Step 'Apps' } 'Startup' { Show-Step 'Startup' } 'Tidy' { Show-Step 'Tidy' } }
        }
        'goto'     { if (Test-CanGoBack) { Show-Step $value } }
        'settings' { if (-not $AutoPilot) { Start-Process 'ms-settings:startupapps' } }
    }
}

# ---------------------------------------------------------------------------
# home
# ---------------------------------------------------------------------------

function Enter-Home {
    $m = Update-Gauge
    if ($m.Percent -ge 85) { $ui.HomeHeading.Text = 'Your memory is nearly full'; $ui.HomeSubText.Text = 'That is when a PC gets slow: Windows has to keep moving things to the disk. Closing apps you do not need helps right away.' }
    elseif ($m.Percent -ge 70) { $ui.HomeHeading.Text = 'Your memory is getting full'; $ui.HomeSubText.Text = 'Closing apps you do not need, and keeping apps from starting by themselves, keeps the PC quick.' }
    else { $ui.HomeHeading.Text = 'Your memory is fine'; $ui.HomeSubText.Text = 'There is plenty free. Windows uses spare memory to keep things quick - free memory is not wasted memory.' }
    $top = @(Get-RunningApps | Select-Object -First 3)
    if ($top.Count -gt 0) { $ui.GaugeTop.Text = 'Using the most: ' + (($top | ForEach-Object { '{0} {1}' -f $_.Name, (Format-Bytes $_.Bytes) }) -join ', ') }
    else { $ui.GaugeTop.Text = '' }
    $ui.TaskTiles.Children.Clear()
    $badge = ''; if ($m.Percent -ge 70) { $badge = 'Recommended' }
    [void] $ui.TaskTiles.Children.Add((New-Tile -Action 'task:Close' -Icon ([string] [char] 0xE711) -Title 'Close apps' -Text 'See which apps use the most, and close the ones you do not need right now.' -Badge $badge -Accent $INDIGO -AccentBack '#E0E7FF' -Selected:($app.Task -eq 'Close')))
    [void] $ui.TaskTiles.Children.Add((New-Tile -Action 'task:Startup' -Icon ([string] [char] 0xE7E8) -Title 'Startup apps' -Text 'Stop apps from starting by themselves with Windows - the lasting fix.' -Accent $INDIGO -AccentBack '#E0E7FF' -Selected:($app.Task -eq 'Startup')))
    [void] $ui.TaskTiles.Children.Add((New-Tile -Action 'task:Tidy' -Icon ([string] [char] 0xE945) -Title 'Quick tidy-up' -Text 'Every app hands back memory it is not using. Handy before a game or a big task.' -Accent $INDIGO -AccentBack '#E0E7FF' -Selected:($app.Task -eq 'Tidy')))
    Set-Footer -Back '' -Next 'Continue' -NextEnabled ([bool] $app.Task)
}

# ---------------------------------------------------------------------------
# close apps
# ---------------------------------------------------------------------------

function Enter-Apps {
    $window.Cursor = [System.Windows.Input.Cursors]::Wait
    try {
        $keep = @{}; foreach ($r in $app.Apps) { if ($r.Selected) { $keep[$r.Path.ToLowerInvariant()] = $true } }
        $app.Apps.Clear()
        $rows = @(Get-RunningApps)
        $max = [double] 1; if ($rows.Count -gt 0) { $max = [math]::Max(1.0, [double] $rows[0].Bytes) }
        foreach ($r in $rows) {
            $r.BarWidth = [math]::Max(3.0, 140.0 * $r.Bytes / $max)
            $r.Selected = $keep.ContainsKey($r.Path.ToLowerInvariant())
            $app.Apps.Add($r)
        }
    }
    finally { $window.Cursor = $null }
    $total = [int64] 0; foreach ($r in $app.Apps) { $total += $r.Bytes }
    $ui.AppsSubText.Text = '{0} of yours use {1}. Windows itself is not listed - it is never closed here.' -f (Format-Plural $app.Apps.Count 'app' 'apps'), (Format-Bytes $total)
    if ($script:SmallApps -gt 0) { $ui.AppsSubText.Text += (' Neither are {0} using less than {1} each.' -f (Format-Plural $script:SmallApps 'small helper' 'small helpers'), (Format-Bytes $SMALL)) }
    $browsers = @($app.Apps | Where-Object { $_.Path -match '\\(chrome|msedge|brave|firefox|opera)\.exe$' })
    if ($browsers.Count -gt 0) {
        $ui.AppsTip.Text = 'Browsers: every open tab uses memory. Their Memory Saver puts tabs you are not looking at to sleep - in Edge: Settings > System and performance; in Chrome: Settings > Performance.'
        $ui.AppsTip.Visibility = 'Visible'
    }
    else { $ui.AppsTip.Visibility = 'Collapsed' }
    Update-AppsFooter
}

function Update-AppsFooter {
    $sel = @($app.Apps | Where-Object { $_.Selected })
    $b = [int64] 0; foreach ($r in $sel) { $b += $r.Bytes }
    $next = 'Close apps'; $text = 'Tick the apps to close.'
    if ($sel.Count -gt 0) { $next = 'Close ' + (Format-Plural $sel.Count 'app' 'apps'); $text = 'Frees about ' + (Format-Bytes $b) }
    if ($ui.NextButton.Content -ne $next -or $ui.FooterText.Text -ne $text) { Set-Footer -Next $next -NextEnabled ($sel.Count -gt 0) -Text $text }
}

function Enter-Confirm {
    $ui.ConfirmRows.Children.Clear()
    $sel = @($app.Apps | Where-Object { $_.Selected })
    $ui.ConfirmHeading.Text = 'Close {0}?' -f (Format-Plural $sel.Count 'app' 'apps')
    for ($n = 0; $n -lt $sel.Count; $n++) {
        $r = $sel[$n]
        if ($r.Windows -gt 0) { $how = 'Closes as if you clicked its X - it can still ask you to save.' } else { $how = 'Runs in the background without a window, so it is stopped directly.' }
        [void] $ui.ConfirmRows.Children.Add((New-FactRow -Icon ([string] [char] 0xE711) -Label $r.MemoryText -Value $r.Name -Detail $how -Change 'Apps' -Accent $INDIGO -AccentBack '#E0E7FF' -Last:($n -eq $sel.Count - 1)))
    }
    Set-Footer -Next ('Close ' + (Format-Plural $sel.Count 'app' 'apps'))
}

function Start-Closing {
    $app.Closing.Clear()
    $app.AvailableBefore = (Get-Memory).Available
    foreach ($r in @($app.Apps | Where-Object { $_.Selected })) {
        $r.CloseStarted = [DateTime]::UtcNow
        if ($r.Windows -gt 0 -and [SmartMemory.Native]::CloseWindows($r.Pids) -gt 0) { $r.Status = 'Closing...' }
        else { Stop-AppProcesses $r; $r.Status = 'Stopping...' }
        $r.StatusColor = $GRAY
        $app.Closing.Add($r)
        Write-UiLog ("closing {0} ({1} processes, {2} windows)" -f $r.Name, $r.Pids.Count, $r.Windows)
    }
    $app.Working = $true; $app.WorkStarted = [DateTime]::UtcNow
    $ui.WorkHeading.Text = 'Closing apps'
    $ui.WorkSubText.Text = 'If an app asks whether to save something, answer it in that app''s window.'
    Show-Step 'Work'
    Set-Footer -Back '' -Next 'Closing...' -NextEnabled $false
}

function Stop-AppProcesses {
    param($Row)
    $Row.Forced = $true
    foreach ($id in $Row.Pids) { try { Stop-Process -Id $id -Force -ErrorAction Stop } catch { } }
}

function Test-Running { param($Row) foreach ($id in $Row.Pids) { if (Get-Process -Id $id -ErrorAction SilentlyContinue) { return $true } }; return $false }

function Update-Closing {
    # An app counts as closed once every one of its processes is gone. Give each up to ten
    # seconds - longer would just mean it is waiting for an answer about saving.
    $open = 0
    foreach ($r in $app.Closing) {
        if ($r.Status -match '^(Closed|Stopped|Still open)') { continue }
        if (-not (Test-Running $r)) {
            if ($r.Forced) { $r.Status = $CHECK + ' Stopped' } else { $r.Status = $CHECK + ' Closed' }
            $r.StatusColor = $GREEN
            Write-UiLog ("  {0}: {1}" -f $r.Name, $r.Status)
        }
        elseif (([DateTime]::UtcNow - $r.CloseStarted).TotalSeconds -gt 10) {
            $r.Status = 'Still open'; $r.StatusColor = $AMBER
            Write-UiLog ("  {0}: still open" -f $r.Name)
        }
        else { $open++ }
    }
    if ($open -eq 0 -and ([DateTime]::UtcNow - $app.WorkStarted).TotalSeconds -gt 1.5) { Complete-Closing }
}

function Complete-Closing {
    $app.Working = $false
    Start-Sleep -Milliseconds 500   # let Windows count the memory as free
    $after = (Get-Memory).Available
    $freed = [math]::Max([int64] 0, $after - $app.AvailableBefore)
    $closed = @($app.Closing | Where-Object { $_.Status -notmatch 'Still open' })
    $still = @($app.Closing | Where-Object { $_.Status -match 'Still open' })
    $ui.DoneFacts.Children.Clear(); $ui.DoneExtra.Children.Clear()
    for ($n = 0; $n -lt $app.Closing.Count; $n++) {
        $r = $app.Closing[$n]
        $detail = 'Was using ' + $r.MemoryText
        if ($r.Status -match 'Still open') { $detail = 'Still open - it may be asking you to save something. Look at its window, or force it closed below.' }
        [void] $ui.DoneFacts.Children.Add((New-FactRow -Icon ([string] [char] 0xE711) -Label $r.Status -Value $r.Name -Detail $detail -Accent $INDIGO -AccentBack '#E0E7FF' -Last:($n -eq $app.Closing.Count - 1)))
    }
    $ui.DoneFactsCard.Visibility = 'Visible'
    Set-Color $ui.DoneIconBack 'Background' '#16A34A'; $ui.DoneIcon.Text = [string] [char] 0xE73E
    $ui.DoneHeading.Text = 'Closed {0}' -f (Format-Plural $closed.Count 'app' 'apps')
    $m = Get-Memory
    $ui.DoneText.Text = '{0} more memory is free - {1}% in use now.' -f (Format-Bytes $freed), $m.Percent
    $app.DoneAlt = $null
    if ($still.Count -gt 0) {
        Set-Color $ui.DoneIconBack 'Background' '#D97706'; $ui.DoneIcon.Text = [string] [char] 0xE7BA
        $app.DoneAlt = { Invoke-ForceClose }
        Set-Footer -Back '' -Next 'Done' -Alt ('Force close ' + (Format-Plural $still.Count 'app' 'apps'))
    }
    else { Set-Footer -Back '' -Next 'Done' }
    Write-UiLog ("closing done: {0} closed, {1} still open, {2} freed" -f $closed.Count, $still.Count, (Format-Bytes $freed))
    Show-Step 'Done'
    if ($app.DoneAlt) { Set-Footer -Back '' -Next 'Done' -Alt ('Force close ' + (Format-Plural $still.Count 'app' 'apps')) } else { Set-Footer -Back '' -Next 'Done' }
}

function Invoke-ForceClose {
    $still = @($app.Closing | Where-Object { $_.Status -match 'Still open' })
    $names = ($still | ForEach-Object { $_.Name }) -join ', '
    if (-not (Confirm-Action ("Force close {0}?`r`n`r`nAnything not saved in them is lost." -f $names) 'Force close?' 'Warning')) { return }
    foreach ($r in $still) { Stop-AppProcesses $r; $r.Status = 'Stopping...'; $r.CloseStarted = [DateTime]::UtcNow }
    $app.Working = $true; $app.WorkStarted = [DateTime]::UtcNow
    $ui.WorkHeading.Text = 'Force closing'
    $ui.WorkSubText.Text = ''
    Show-Step 'Work'
    Set-Footer -Back '' -Next 'Closing...' -NextEnabled $false
}

# ---------------------------------------------------------------------------
# startup apps
# ---------------------------------------------------------------------------

$APPROVED = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'

function Get-StartupSources {
    # Where Windows keeps "start with Windows" - and where each one's on/off switch is (the
    # same switches Task Manager's Startup apps page uses). A test run uses its own key.
    if ($TestRegistryKey) {
        return @(@{ Hive = 'HKCU'; Run = "$TestRegistryKey\Run"; Approved = "$TestRegistryKey\StartupApproved\Run" })
    }
    return @(
        @{ Hive = 'HKCU'; Run = 'Software\Microsoft\Windows\CurrentVersion\Run'; Approved = "$APPROVED\Run" },
        @{ Hive = 'HKLM'; Run = 'Software\Microsoft\Windows\CurrentVersion\Run'; Approved = "$APPROVED\Run" },
        @{ Hive = 'HKLM'; Run = 'Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Approved = "$APPROVED\Run32" },
        @{ Hive = 'HKCU'; Folder = [Environment]::GetFolderPath('Startup'); Approved = "$APPROVED\StartupFolder" },
        @{ Hive = 'HKLM'; Folder = [Environment]::GetFolderPath('CommonStartup'); Approved = "$APPROVED\StartupFolder" }
    )
}

function Get-HiveKey { param([string] $Hive) if ($Hive -eq 'HKLM') { return [Microsoft.Win32.Registry]::LocalMachine }; return [Microsoft.Win32.Registry]::CurrentUser }

function Get-CommandPath {
    # The program a startup command runs: "C:\...\app.exe" --minimized  ->  C:\...\app.exe
    param([string] $Command)
    $c = [Environment]::ExpandEnvironmentVariables($Command).Trim()
    if ($c.StartsWith('"')) { $end = $c.IndexOf('"', 1); if ($end -gt 0) { return $c.Substring(1, $end - 1) } }
    $i = $c.ToLowerInvariant().IndexOf('.exe')
    if ($i -gt 0) { return $c.Substring(0, $i + 4) }
    return ($c -split ' ')[0]
}

function Test-StartupEnabled {
    # Task Manager writes 02/06 for on and 03/07 for off as the first byte; no entry means on.
    param([string] $Hive, [string] $Approved, [string] $Name)
    try {
        $k = (Get-HiveKey $Hive).OpenSubKey($Approved)
        if (-not $k) { return $true }
        $v = $k.GetValue($Name); $k.Close()
        if ($v -is [byte[]] -and $v.Length -gt 0) { return (($v[0] -band 1) -eq 0) }
    }
    catch { }
    return $true
}

function Get-StartupApps {
    $rows = New-Object System.Collections.ArrayList
    $running = @{}
    $ws = [SmartMemory.Native]::PrivateWorkingSets()
    foreach ($p in Get-Process) { $path = $null; try { $path = $p.Path } catch { }; if ($path) { $k = $path.ToLowerInvariant(); $b = $ws[$p.Id]; if ($null -eq $b) { $b = 0 }; $running[$k] = [int64] $running[$k] + [int64] $b } }
    $shell = New-Object -ComObject WScript.Shell
    foreach ($src in (Get-StartupSources)) {
        $entries = @()
        if ($src.Run) {
            try {
                $k = (Get-HiveKey $src.Hive).OpenSubKey($src.Run)
                if ($k) { foreach ($n in $k.GetValueNames()) { if ($n) { $entries += , @($n, [string] $k.GetValue($n)) } }; $k.Close() }
            }
            catch { }
        }
        elseif ($src.Folder -and (Test-Path -LiteralPath $src.Folder)) {
            foreach ($f in Get-ChildItem -LiteralPath $src.Folder -File -ErrorAction SilentlyContinue) {
                if ($f.Name -eq 'desktop.ini') { continue }
                $target = $f.FullName
                if ($f.Extension -eq '.lnk') { try { $t = $shell.CreateShortcut($f.FullName).TargetPath; if ($t) { $target = $t } } catch { } }
                $entries += , @($f.Name, $target)
            }
        }
        foreach ($e in $entries) {
            $r = New-Object SmartMemory.StartupRow
            $r.ValueName = $e[0]; $r.Hive = $src.Hive; $r.ApprovedKey = $src.Approved
            $r.Path = Get-CommandPath $e[1]
            $name = [System.IO.Path]::GetFileNameWithoutExtension($e[0])
            if (Test-Path -LiteralPath $r.Path) { $name = Get-FriendlyName $r.Path $name; $r.Icon = Get-AppIcon $r.Path }
            $r.Name = $name
            $publisher = ''; if (Test-Path -LiteralPath $r.Path) { $publisher = Get-Publisher $r.Path }
            $r.Detail = (@($publisher, $r.Path) | Where-Object { $_ }) -join $DOT
            $r.WasEnabled = Test-StartupEnabled $src.Hive $src.Approved $e[0]
            $r.Enabled = $r.WasEnabled
            $r.NeedsAdmin = ($src.Hive -eq 'HKLM')
            $badges = @()
            $mem = $running[$r.Path.ToLowerInvariant()]
            if ($mem) { $badges += ('Running now, using ' + (Format-Bytes $mem)) }
            if ($r.NeedsAdmin) { $badges += 'For everyone on this PC - asks for permission' }
            $r.Badge = $badges -join "`r`n"
            [void] $rows.Add($r)
        }
    }
    return @($rows | Sort-Object @{ Expression = { -not $_.WasEnabled } }, Name)
}

function Enter-Startup {
    $window.Cursor = [System.Windows.Input.Cursors]::Wait
    try {
        $app.Startup.Clear()
        foreach ($r in (Get-StartupApps)) { $app.Startup.Add($r) }
    }
    finally { $window.Cursor = $null }
    $on = @($app.Startup | Where-Object { $_.WasEnabled }).Count
    $ui.StartupSubText.Text = '{0} by {1} when you sign in. Each one takes memory - and time - from the start.' -f (Format-Plural $on 'app starts' 'apps start'), $(if ($on -eq 1) { 'itself' } else { 'themselves' })
    Update-StartupFooter
}

function Update-StartupFooter {
    $changed = @($app.Startup | Where-Object { $_.Enabled -ne $_.WasEnabled })
    $next = 'Save changes'; $text = 'Nothing changed yet.'
    if ($changed.Count -gt 0) { $next = 'Save {0}' -f (Format-Plural $changed.Count 'change' 'changes'); $text = '' }
    if ($ui.NextButton.Content -ne $next -or $ui.FooterText.Text -ne $text) { Set-Footer -Next $next -NextEnabled ($changed.Count -gt 0) -Text $text }
}

function Get-ApprovedBytes {
    # On: 02 and eleven zero bytes. Off: 03, then the time it was switched off.
    param([bool] $Enabled)
    $bytes = New-Object byte[] 12
    if ($Enabled) { $bytes[0] = 2 }
    else { $bytes[0] = 3; [Array]::Copy([BitConverter]::GetBytes([DateTime]::UtcNow.ToFileTimeUtc()), 0, $bytes, 4, 8) }
    return , $bytes
}

function Save-Startup {
    $changed = @($app.Startup | Where-Object { $_.Enabled -ne $_.WasEnabled })
    $failed = New-Object System.Collections.ArrayList
    $admin = @($changed | Where-Object { $_.NeedsAdmin })
    foreach ($r in @($changed | Where-Object { -not $_.NeedsAdmin })) {
        try {
            $k = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($r.ApprovedKey)
            $k.SetValue($r.ValueName, (Get-ApprovedBytes $r.Enabled), [Microsoft.Win32.RegistryValueKind]::Binary); $k.Close()
        }
        catch { [void] $failed.Add($r) }
    }
    if ($admin.Count -gt 0) {
        # One permission prompt for all of them: reg.exe, run as administrator.
        $commands = foreach ($r in $admin) {
            $hex = (-join ((Get-ApprovedBytes $r.Enabled) | ForEach-Object { $_.ToString('X2') }))
            'reg add "HKLM\{0}" /v "{1}" /t REG_BINARY /d {2} /f' -f $r.ApprovedKey, $r.ValueName, $hex
        }
        try { Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', ($commands -join ' & ') -Verb RunAs -WindowStyle Hidden -Wait }
        catch { Write-UiLog "permission declined: $($_.Exception.Message)" }
    }
    # What is really saved now, read back.
    foreach ($r in $changed) {
        $now = Test-StartupEnabled $r.Hive $r.ApprovedKey $r.ValueName
        if ($now -ne $r.Enabled -and -not $failed.Contains($r)) { [void] $failed.Add($r) }
        Write-UiLog ("startup {0}: {1} -> {2} (saved: {3})" -f $r.Name, $r.WasEnabled, $r.Enabled, ($now -eq $r.Enabled))
    }
    Complete-Startup $changed $failed
}

function Complete-Startup {
    param($Changed, $Failed)
    $ui.DoneFacts.Children.Clear(); $ui.DoneExtra.Children.Clear()
    $off = @($Changed | Where-Object { -not $_.Enabled -and -not $Failed.Contains($_) })
    $on = @($Changed | Where-Object { $_.Enabled -and -not $Failed.Contains($_) })
    $rows = @()
    foreach ($r in $off) { $rows += , @($r, 'Will not start by itself any more') }
    foreach ($r in $on) { $rows += , @($r, 'Starts with Windows again') }
    foreach ($r in $Failed) { $rows += , @($r, 'Not changed - permission was not given') }
    for ($n = 0; $n -lt $rows.Count; $n++) {
        [void] $ui.DoneFacts.Children.Add((New-FactRow -Icon ([string] [char] 0xE7E8) -Label $rows[$n][1] -Value $rows[$n][0].Name -Accent $INDIGO -AccentBack '#E0E7FF' -Last:($n -eq $rows.Count - 1)))
    }
    $ui.DoneFactsCard.Visibility = $(if ($rows.Count -gt 0) { 'Visible' } else { 'Collapsed' })
    Set-Color $ui.DoneIconBack 'Background' '#16A34A'; $ui.DoneIcon.Text = [string] [char] 0xE73E
    if ($Failed.Count -gt 0) { Set-Color $ui.DoneIconBack 'Background' '#D97706'; $ui.DoneIcon.Text = [string] [char] 0xE7BA }
    $ui.DoneHeading.Text = 'Saved'
    $ui.DoneText.Text = 'This takes effect the next time you sign in.'
    foreach ($r in $app.Startup) { $r.WasEnabled = Test-StartupEnabled $r.Hive $r.ApprovedKey $r.ValueName }
    # Switched off, but still running right now? Offer to close those too.
    $runningOff = @($off | Where-Object { $_.Badge -match 'Running now' })
    $app.DoneAlt = $null
    if ($runningOff.Count -gt 0 -and -not $AutoPilot) {
        $ui.DoneText.Text += (' {0} still running right now.' -f (Format-Plural $runningOff.Count 'of them is' 'of them are'))
        $paths = @{}; foreach ($r in $runningOff) { $paths[$r.Path.ToLowerInvariant()] = $true }
        $app.DoneAlt = { Set-Task 'Close'; Show-Step 'Apps'; foreach ($a in $app.Apps) { if ($paths.ContainsKey($a.Path.ToLowerInvariant())) { $a.Selected = $true } }; Update-AppsFooter }.GetNewClosure()
    }
    Show-Step 'Done'
    if ($app.DoneAlt) { Set-Footer -Back '' -Next 'Done' -Alt 'Close them now' } else { Set-Footer -Back '' -Next 'Done' }
}

# ---------------------------------------------------------------------------
# quick tidy-up
# ---------------------------------------------------------------------------

function Enter-Tidy {
    $ui.TidyFacts.Children.Clear()
    [void] $ui.TidyFacts.Children.Add((New-FactRow -Icon ([string] [char] 0xE945) -Label 'What it does' -Value 'Apps hand back memory they are not using' -Detail 'Nothing is closed and nothing is lost: an app gets its memory back the moment it needs it.' -Accent $INDIGO -AccentBack '#E0E7FF'))
    [void] $ui.TidyFacts.Children.Add((New-FactRow -Icon ([string] [char] 0xE916) -Label 'When it helps' -Value 'Right before something big' -Detail 'Like a game, a video call or editing a large file. The effect fades as apps get busy again.' -Accent $INDIGO -AccentBack '#E0E7FF'))
    [void] $ui.TidyFacts.Children.Add((New-FactRow -Icon ([string] [char] 0xE711) -Label 'For a lasting effect' -Value 'Close apps, and keep them from starting by themselves' -Detail 'Those are the other two choices on the first screen.' -Accent $INDIGO -AccentBack '#E0E7FF' -Last))
    Set-Footer -Next 'Tidy up now'
}

function Start-Tidy {
    $app.Closing.Clear()
    $before = (Get-Memory).Available
    $session = (Get-Process -Id $PID).SessionId
    $done = 0
    $window.Cursor = [System.Windows.Input.Cursors]::Wait
    try {
        foreach ($p in Get-Process) {
            if ($p.SessionId -ne $session) { continue }
            if ($TestAppsFolder) {
                $path = $null; try { $path = $p.Path } catch { }
                if (-not $path -or -not $path.StartsWith($TestAppsFolder.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { continue }
            }
            if ([SmartMemory.Native]::Trim($p.Id)) { $done++ }
        }
    }
    finally { $window.Cursor = $null }
    Start-Sleep -Milliseconds 800
    $m = Get-Memory
    $gained = [math]::Max([int64] 0, $m.Available - $before)
    Write-UiLog ("tidy-up: {0} apps, {1} more free" -f $done, (Format-Bytes $gained))
    $ui.DoneFacts.Children.Clear(); $ui.DoneExtra.Children.Clear()
    $ui.DoneFactsCard.Visibility = 'Collapsed'
    Set-Color $ui.DoneIconBack 'Background' '#16A34A'; $ui.DoneIcon.Text = [string] [char] 0xE73E
    $ui.DoneHeading.Text = '{0} more memory free' -f (Format-Bytes $gained)
    $ui.DoneText.Text = '{0} handed back what {2} not using - {1}% in use now. It fills up again as your apps get busy; for a lasting effect, close apps you do not need.' -f (Format-Plural $done 'app' 'apps'), $m.Percent, $(if ($done -eq 1) { 'it was' } else { 'they were' })
    $app.DoneAlt = { Set-Task 'Close'; Show-Step 'Apps' }
    Show-Step 'Done'
    Set-Footer -Back '' -Next 'Done' -Alt 'Close apps'
}

# ---------------------------------------------------------------------------
# buttons
# ---------------------------------------------------------------------------

$ui.BackButton.Add_Click({ Invoke-Safely { Invoke-Back } })
$ui.NextButton.Add_Click({ Invoke-Safely { Invoke-Next } })
$ui.AltButton.Add_Click({ Invoke-Safely { Invoke-Alt } })
$ui.OpenLogButton.Add_Click({ Invoke-Safely { Open-Path $LogPath } })
$ui.AppsRefreshButton.Add_Click({ Invoke-Safely { Enter-Apps } })
$ui.StartupSettingsButton.Add_Click({ Invoke-Safely { Invoke-Tile 'settings:' } })

$window.Add_PreviewKeyDown({ param($s, $e)
    if ($e.Key -eq 'Escape' -or $e.SystemKey -eq 'Left') {
        if ($ui.BackButton.Visibility -eq 'Visible' -and $ui.BackButton.IsEnabled) { $e.Handled = $true; Invoke-Safely { Invoke-Back } }
    }
})
$window.Add_Closing({ param($s, $e) if (-not $app.ForceClose -and $app.Working -and -not (Confirm-Action 'Apps are still closing. Close this window anyway?')) { $e.Cancel = $true } })

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
            Save-Screenshot 'home'
            Invoke-Tile ('task:' + $AutoTask)
            & $next 'task'
        }
        'task' {
            if ($elapsed -lt 1) { return }
            switch ($AutoTask) {
                'Close' {
                    [void] $auto.Log.Add(('listed: {0}' -f (($app.Apps | ForEach-Object { '{0} ({1}, {2})' -f $_.Name, $_.Detail, $_.MemoryText }) -join '; ')))
                    foreach ($r in $app.Apps) { $r.Selected = $true }
                    Update-AppsFooter
                    Save-Screenshot 'apps'
                    Invoke-Click $ui.NextButton
                    & $next 'confirm'
                }
                'Startup' {
                    [void] $auto.Log.Add(('listed: {0}' -f (($app.Startup | ForEach-Object { '{0}={1}' -f $_.Name, $_.Enabled }) -join '; ')))
                    foreach ($r in $app.Startup) { $r.Enabled = -not $r.Enabled }
                    Update-StartupFooter
                    Save-Screenshot 'startup'
                    Invoke-Click $ui.NextButton
                    & $next 'done'
                }
                'Tidy' { Save-Screenshot 'tidy'; Invoke-Click $ui.NextButton; & $next 'done' }
            }
        }
        'confirm' {
            if ($elapsed -lt 1) { return }
            Save-Screenshot 'confirm'
            Invoke-Click $ui.NextButton
            & $next 'closing'
        }
        'closing' {
            if ($app.Page -eq 'Work' -and -not $auto.Closing -and $elapsed -gt 0.3) { $auto.Closing = $true; Save-Screenshot 'closing' }
            if ($app.Page -ne 'Done' -or $elapsed -lt 1) { return }
            Save-Screenshot 'closed'
            [void] $auto.Log.Add(('statuses: {0}' -f (($app.Closing | ForEach-Object { '{0}: {1}' -f $_.Name, $_.Status }) -join '; ')))
            if ($ui.AltButton.Visibility -eq 'Visible') { Invoke-Click $ui.AltButton; & $next 'forcing'; return }
            & $next 'finish'
        }
        'forcing' {
            if ($app.Page -ne 'Done' -or $elapsed -lt 1) { return }
            Save-Screenshot 'forced'
            [void] $auto.Log.Add(('after force: {0}' -f (($app.Closing | ForEach-Object { '{0}: {1}' -f $_.Name, $_.Status }) -join '; ')))
            & $next 'finish'
        }
        'done' {
            if ($app.Page -ne 'Done' -or $elapsed -lt 1) { return }
            Save-Screenshot 'done'
            if ($AutoTask -eq 'Startup') { [void] $auto.Log.Add(('saved: {0}' -f (($app.Startup | ForEach-Object { '{0}={1}' -f $_.Name, (Test-StartupEnabled $_.Hive $_.ApprovedKey $_.ValueName) }) -join '; '))) }
            [void] $auto.Log.Add('done: ' + $ui.DoneHeading.Text + ' / ' + $ui.DoneText.Text)
            & $next 'finish'
        }
        'finish' {
            if ($ScreenshotDir) {
                New-Item -ItemType Directory -Force -Path $ScreenshotDir | Out-Null
                [System.IO.File]::WriteAllText((Join-Path $ScreenshotDir 'result.json'), (@{ Stages = @($auto.Log); Page = $app.Page } | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
            }
            $auto.Stage = 'closing-window'
            $app.ForceClose = $true
            $window.Close()
        }
    }
}

# ---------------------------------------------------------------------------
# the heartbeat
# ---------------------------------------------------------------------------

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(250)
$timer.Add_Tick({
    try {
        switch ($app.Page) {
            'Home'    { if (([DateTime]::UtcNow - $app.LastGauge).TotalSeconds -ge 2) { $app.LastGauge = [DateTime]::UtcNow; [void] (Update-Gauge) } }
            'Apps'    { Update-AppsFooter }
            'Startup' { Update-StartupFooter }
            'Work'    { if ($app.Working) { Update-Closing } }
        }
        if ($AutoPilot) {
            if (([DateTime]::UtcNow - $auto.Started).TotalMinutes -gt 3 -and $auto.Stage -ne 'closing-window') { [void] $auto.Log.Add('gave up after 3 minutes'); $auto.Stage = 'finish' }
            Step-AutoPilot
        }
    }
    catch {
        Write-UiLog ("tick failed: {0} {1}" -f $_.Exception.Message, $_.ScriptStackTrace)
        if ($AutoPilot -and $auto.Stage -ne 'closing-window') { [void] $auto.Log.Add("error in $($auto.Stage): $($_.Exception.Message)"); $auto.Stage = 'finish' }
    }
})

# ---------------------------------------------------------------------------
# start
# ---------------------------------------------------------------------------

Initialize-StageList
Show-Step 'Home'
$timer.Start()
Write-UiLog ("memory started (autopilot: {0}, task: {1})" -f [bool] $AutoPilot, $AutoTask)
[void] $window.ShowDialog()
$timer.Stop()
try { $LogWriter.Close() } catch { }
