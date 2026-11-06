#Requires -Version 5.1
<#
    ARK FPS Booster  v2.0
    Für ARK: Survival Evolved (ASE) und ARK: Survival Ascended (ASA)

    - Jede Änderung wird vorher gesichert (Registry-Werte, Energieplan, INI-Dateien)
      und kann mit "Alles rückgängig" vollständig zurückgesetzt werden.
    - Sicherung/Status liegt unter %APPDATA%\ArkFpsBooster
#>

$ErrorActionPreference = 'Stop'
$AppName    = 'ARK FPS Booster'
$AppVersion = '2.1'

# ---------------------------------------------------------------------------
#  Start: Adminrechte, STA-Modus und 64-Bit-PowerShell sicherstellen
# ---------------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
$isSta   = [Threading.Thread]::CurrentThread.GetApartmentState() -eq [Threading.ApartmentState]::STA
$wrongBitness = [Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess

if (-not $isAdmin -or -not $isSta -or $wrongBitness) {
    $psDir = 'System32'
    if ($wrongBitness) { $psDir = 'Sysnative' }
    $psExe   = Join-Path $env:SystemRoot "$psDir\WindowsPowerShell\v1.0\powershell.exe"
    $argList = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{0}"' -f $PSCommandPath
    $sp = @{ FilePath = $psExe; ArgumentList = $argList }
    if (-not $isAdmin) { $sp['Verb'] = 'RunAs' }
    try {
        Start-Process @sp
    } catch {
        Add-Type -AssemblyName PresentationFramework
        [void][System.Windows.MessageBox]::Show(
            "Der ARK FPS Booster braucht Administratorrechte, um Windows-Einstellungen zu ändern.`n`nBitte beim Start die Windows-Abfrage mit 'Ja' bestätigen.",
            $AppName, 'OK', 'Warning')
    }
    exit
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

if (-not ('ArkBoost.Native' -as [type])) {
    Add-Type -Namespace ArkBoost -Name Native -MemberDefinition @'
[DllImport("psapi.dll")]
public static extern bool EmptyWorkingSet(IntPtr hProcess);
[DllImport("user32.dll", SetLastError = true)]
public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, int[] pvParam, uint fWinIni);
'@
}

# ---------------------------------------------------------------------------
#  Pfade und Status
# ---------------------------------------------------------------------------
$DataDir   = Join-Path $env:APPDATA 'ArkFpsBooster'
$BackupDir = Join-Path $DataDir 'Backup'
$StateFile = Join-Path $DataDir 'state.json'
$LogFile   = Join-Path $DataDir 'log.txt'
New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null

$GuidRx = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
$script:NeedsReboot = $false
$script:Games = @()

function New-EmptyState {
    return @{
        Registry      = New-Object System.Collections.ArrayList
        CreatedKeys   = New-Object System.Collections.ArrayList
        IniBackups    = New-Object System.Collections.ArrayList
        ManualPaths   = New-Object System.Collections.ArrayList
        Renamed       = New-Object System.Collections.ArrayList
        PowerOriginal = $null
        UltimateGuid  = $null
    }
}

function Import-State {
    $s = New-EmptyState
    if (Test-Path -LiteralPath $StateFile) {
        try {
            $j = Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($r in @($j.Registry))    { if ($null -ne $r) { [void]$s.Registry.Add($r) } }
            foreach ($k in @($j.CreatedKeys)) { if ($k) { [void]$s.CreatedKeys.Add([string]$k) } }
            foreach ($b in @($j.IniBackups))  { if ($null -ne $b) { [void]$s.IniBackups.Add($b) } }
            foreach ($m in @($j.ManualPaths)) { if ($m) { [void]$s.ManualPaths.Add([string]$m) } }
            foreach ($rn in @($j.Renamed))    { if ($null -ne $rn) { [void]$s.Renamed.Add($rn) } }
            if ($j.PowerOriginal) { $s.PowerOriginal = [string]$j.PowerOriginal }
            if ($j.UltimateGuid)  { $s.UltimateGuid  = [string]$j.UltimateGuid }
        } catch {
            # Beschädigte Statusdatei: umbenennen statt verlieren
            try { Move-Item -LiteralPath $StateFile -Destination "$StateFile.defekt" -Force } catch { }
        }
    }
    return $s
}

function Save-State {
    $obj = [ordered]@{
        Registry      = @($script:State.Registry)
        CreatedKeys   = @($script:State.CreatedKeys)
        IniBackups    = @($script:State.IniBackups)
        ManualPaths   = @($script:State.ManualPaths)
        Renamed       = @($script:State.Renamed)
        PowerOriginal = $script:State.PowerOriginal
        UltimateGuid  = $script:State.UltimateGuid
    }
    $json = ConvertTo-Json -InputObject $obj -Depth 6
    [System.IO.File]::WriteAllText($StateFile, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Test-HasChanges {
    return ($script:State.Registry.Count -gt 0 -or $script:State.CreatedKeys.Count -gt 0 -or
            $script:State.IniBackups.Count -gt 0 -or $script:State.Renamed.Count -gt 0 -or
            [bool]$script:State.PowerOriginal)
}

$script:State = Import-State

# ---------------------------------------------------------------------------
#  Hilfsfunktionen
# ---------------------------------------------------------------------------
function Invoke-Native([string]$Exe, [string[]]$ArgList) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $Exe @ArgList 2>&1 | ForEach-Object { "$_" }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $old
    }
    return [pscustomobject]@{ Code = $code; Output = (@($out) -join "`n") }
}

function Get-RegBase([string]$Path) {
    $parts = $Path -split '\\', 2
    switch ($parts[0]) {
        'HKCU' { $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser,  [Microsoft.Win32.RegistryView]::Default) }
        'HKLM' { $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64) }
        default { throw "Unbekannter Registry-Zweig: $($parts[0])" }
    }
    return [pscustomobject]@{ Base = $base; Sub = $parts[1]; Hive = $parts[0] }
}

function Get-RegValue([string]$Path, [string]$Name) {
    $r = Get-RegBase $Path
    $k = $r.Base.OpenSubKey($r.Sub)
    if ($null -eq $k) { return $null }
    try { return $k.GetValue($Name, $null) } finally { $k.Close() }
}

function Open-RegKeyForWrite([string]$Path) {
    $r = Get-RegBase $Path
    $current = ''
    foreach ($seg in ($r.Sub -split '\\')) {
        if ($current) { $current = "$current\$seg" } else { $current = $seg }
        $k = $r.Base.OpenSubKey($current)
        if ($null -eq $k) {
            $new = $r.Base.CreateSubKey($current)
            $new.Close()
            $full = "$($r.Hive)\$current"
            if (-not ($script:State.CreatedKeys -contains $full)) { [void]$script:State.CreatedKeys.Add($full) }
        } else {
            $k.Close()
        }
    }
    $key = $r.Base.OpenSubKey($r.Sub, $true)
    if ($null -eq $key) { throw "Registry-Schlüssel kann nicht geöffnet werden: $Path" }
    return $key
}

# Setzt einen Registry-Wert und merkt sich beim ersten Mal den Originalzustand
function Set-TrackedValue([string]$Path, [string]$Name, $Value, [Microsoft.Win32.RegistryValueKind]$Kind) {
    $key = Open-RegKeyForWrite $Path
    try {
        $id = "$Path|$Name"
        $known = @($script:State.Registry | Where-Object { $_.Id -eq $id })
        if ($known.Count -eq 0) {
            $exists = @($key.GetValueNames()) -contains $Name
            $entry = [pscustomobject]@{ Id = $id; Path = $Path; Name = $Name; Existed = $exists; Value = $null; Kind = $null }
            if ($exists) {
                $entry.Kind  = $key.GetValueKind($Name).ToString()
                $entry.Value = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            }
            [void]$script:State.Registry.Add($entry)
        }
        $key.SetValue($Name, $Value, $Kind)
    } finally {
        $key.Close()
    }
}

function Set-MouseFromRegistry {
    $p = 'HKCU\Control Panel\Mouse'
    $vals = @(
        [int]("0" + [string](Get-RegValue $p 'MouseThreshold1')),
        [int]("0" + [string](Get-RegValue $p 'MouseThreshold2')),
        [int]("0" + [string](Get-RegValue $p 'MouseSpeed'))
    )
    # SPI_SETMOUSE = 0x0004, SPIF_UPDATEINIFILE | SPIF_SENDCHANGE = 3
    [void][ArkBoost.Native]::SystemParametersInfo(4, 0, [int[]]$vals, 3)
}

function Format-Size([double]$Bytes) {
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N0} MB' -f ($Bytes / 1MB)) }
    return ('{0:N0} KB' -f ($Bytes / 1KB))
}

# ---------------------------------------------------------------------------
#  Spiele finden
# ---------------------------------------------------------------------------
$GameDefs = @(
    @{ Short = 'ASE'; Name = 'ARK: Survival Evolved';  Folder = 'ARK';
       ExeRel = 'ShooterGame\Binaries\Win64\ShooterGame.exe'; ConfigRel = 'ShooterGame\Saved\Config\WindowsNoEditor';
       Proc = 'ShooterGame'; AppId = 346110 },
    @{ Short = 'ASA'; Name = 'ARK: Survival Ascended'; Folder = 'ARK Survival Ascended';
       ExeRel = 'ShooterGame\Binaries\Win64\ArkAscended.exe'; ConfigRel = 'ShooterGame\Saved\Config\Windows';
       Proc = 'ArkAscended'; AppId = 2399830 }
)

function Get-SteamLibraries {
    $libs = New-Object System.Collections.ArrayList
    $cands = @()
    try { $cands += (Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -Name SteamPath -ErrorAction Stop).SteamPath } catch { }
    try { $cands += (Get-ItemProperty -Path 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' -Name InstallPath -ErrorAction Stop).InstallPath } catch { }
    if (${env:ProgramFiles(x86)}) { $cands += (Join-Path ${env:ProgramFiles(x86)} 'Steam') }

    foreach ($c in $cands) {
        if (-not $c) { continue }
        $p = ($c -replace '/', '\').TrimEnd('\')
        if (-not (Test-Path -LiteralPath $p)) { continue }
        if (-not ($libs -contains $p)) { [void]$libs.Add($p) }
        $vdf = Join-Path $p 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf) {
            try {
                $txt = Get-Content -LiteralPath $vdf -Raw -Encoding UTF8
                foreach ($m in [regex]::Matches($txt, '"path"\s+"([^"]+)"')) {
                    $lp = ($m.Groups[1].Value -replace '\\\\', '\').TrimEnd('\')
                    if ((Test-Path -LiteralPath $lp) -and -not ($libs -contains $lp)) { [void]$libs.Add($lp) }
                }
            } catch { }
        }
    }
    return @($libs)
}

function New-GameObject($def, [string]$root, [bool]$isSteam) {
    return [pscustomobject]@{
        Short = $def.Short; Name = $def.Name; Proc = $def.Proc; AppId = $def.AppId
        Root = $root; Exe = (Join-Path $root $def.ExeRel); ConfigDir = (Join-Path $root $def.ConfigRel)
        IsSteam = $isSteam
    }
}

function Find-Games {
    $found = New-Object System.Collections.ArrayList
    foreach ($lib in (Get-SteamLibraries)) {
        foreach ($def in $GameDefs) {
            $root = Join-Path $lib ("steamapps\common\" + $def.Folder)
            if (Test-Path -LiteralPath (Join-Path $root $def.ExeRel)) {
                if (-not (@($found | Where-Object { $_.Short -eq $def.Short }))) {
                    [void]$found.Add((New-GameObject $def $root $true))
                }
            }
        }
    }
    foreach ($mp in @($script:State.ManualPaths)) {
        foreach ($def in $GameDefs) {
            if ((Test-Path -LiteralPath (Join-Path $mp $def.ExeRel)) -and -not (@($found | Where-Object { $_.Short -eq $def.Short }))) {
                [void]$found.Add((New-GameObject $def $mp ($mp -match 'steamapps')))
            }
        }
    }
    return @($found)
}

# ---------------------------------------------------------------------------
#  Oberfläche (XAML)
# ---------------------------------------------------------------------------
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="ARK FPS Booster" Width="1120" Height="880" MinWidth="960" MinHeight="640"
        WindowStartupLocation="CenterScreen" Background="#0E1014" FontFamily="Segoe UI" FontSize="13"
        Foreground="#E8EAF0">
  <Window.Resources>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#E8EAF0"/>
      <Setter Property="Margin" Value="0,7,0,7"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Grid Background="Transparent">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <Border x:Name="Track" Width="40" Height="22" CornerRadius="11" Background="#343A47" VerticalAlignment="Top" Margin="0,1,0,0">
                <Ellipse x:Name="Knob" Width="16" Height="16" Fill="#FFFFFF" HorizontalAlignment="Left" Margin="3,0,0,0"/>
              </Border>
              <ContentPresenter Grid.Column="1" Margin="12,0,0,0" VerticalAlignment="Top"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Track" Property="Background" Value="#FF7A1A"/>
                <Setter TargetName="Knob" Property="HorizontalAlignment" Value="Right"/>
                <Setter TargetName="Knob" Property="Margin" Value="0,0,3,0"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="#E8EAF0"/>
      <Setter Property="Background" Value="#252A35"/>
      <Setter Property="Padding" Value="14,9"/>
      <Setter Property="Margin" Value="0,0,0,8"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Opacity" Value="0.85"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Opacity" Value="0.7"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Opacity" Value="0.4"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="AccentBtn" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="#FF7A1A"/>
      <Setter Property="Foreground" Value="#14100C"/>
      <Setter Property="FontWeight" Value="Bold"/>
    </Style>

    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="#171A21"/>
      <Setter Property="BorderBrush" Value="#242936"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="12"/>
      <Setter Property="Padding" Value="18,14"/>
      <Setter Property="Margin" Value="0,0,0,14"/>
    </Style>
    <Style x:Key="CardTitle" TargetType="TextBlock">
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Foreground" Value="#FF9A4D"/>
      <Setter Property="Margin" Value="0,0,0,4"/>
    </Style>
    <Style x:Key="Desc" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#8C94A6"/>
      <Setter Property="FontSize" Value="11.5"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="Margin" Value="0,2,0,0"/>
    </Style>
    <Style x:Key="Head" TargetType="TextBlock">
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <Style x:Key="Tile" TargetType="Border">
      <Setter Property="Background" Value="#0E1014"/>
      <Setter Property="CornerRadius" Value="8"/>
      <Setter Property="Padding" Value="12,8"/>
      <Setter Property="Margin" Value="0,0,10,0"/>
    </Style>
    <Style x:Key="TileLbl" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#8C94A6"/>
      <Setter Property="FontSize" Value="10.5"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="TileVal" TargetType="TextBlock">
      <Setter Property="FontSize" Value="17"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Margin" Value="0,2,0,0"/>
      <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="Margin" Value="0,4,0,8"/>
      <Setter Property="Padding" Value="8,5"/>
    </Style>
  </Window.Resources>

  <Grid Margin="20">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="*"/>
      <ColumnDefinition Width="20"/>
      <ColumnDefinition Width="360"/>
    </Grid.ColumnDefinitions>

    <!-- Kopfzeile -->
    <Border Grid.Row="0" Grid.ColumnSpan="3" Style="{StaticResource Card}" Padding="20,16">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <StackPanel>
          <TextBlock FontSize="26" FontWeight="Black">
            <Run Text="ARK" Foreground="#FF7A1A"/><Run Text=" FPS BOOSTER"/>
          </TextBlock>
          <TextBlock x:Name="TxtGames" Style="{StaticResource Desc}" FontSize="12.5" Text="Suche Spiele ..."/>
        </StackPanel>
        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
          <Button x:Name="BtnFolder" Style="{StaticResource Btn}" Content="Spielordner wählen" Margin="0,0,8,0"/>
          <Button x:Name="BtnStartASE" Style="{StaticResource Btn}" Content="▶  ASE starten" Margin="0,0,8,0" Visibility="Collapsed"/>
          <Button x:Name="BtnStartASA" Style="{StaticResource Btn}" Content="▶  ASA starten" Margin="0" Visibility="Collapsed"/>
        </StackPanel>
        <UniformGrid Grid.Row="1" Grid.ColumnSpan="2" Rows="1" Margin="0,14,0,0">
          <Border Style="{StaticResource Tile}"><StackPanel>
            <TextBlock Style="{StaticResource TileLbl}" Text="CPU-LAST"/>
            <TextBlock x:Name="MonCpu" Style="{StaticResource TileVal}" Text="–"/>
          </StackPanel></Border>
          <Border Style="{StaticResource Tile}"><StackPanel>
            <TextBlock Style="{StaticResource TileLbl}" Text="ARBEITSSPEICHER"/>
            <TextBlock x:Name="MonRam" Style="{StaticResource TileVal}" Text="–"/>
          </StackPanel></Border>
          <Border Style="{StaticResource Tile}"><StackPanel>
            <TextBlock Style="{StaticResource TileLbl}" Text="GPU-LAST"/>
            <TextBlock x:Name="MonGpu" Style="{StaticResource TileVal}" Text="–"/>
          </StackPanel></Border>
          <Border Style="{StaticResource Tile}"><StackPanel>
            <TextBlock Style="{StaticResource TileLbl}" Text="GPU-TEMPERATUR"/>
            <TextBlock x:Name="MonGpuTemp" Style="{StaticResource TileVal}" Text="–"/>
          </StackPanel></Border>
          <Border Style="{StaticResource Tile}"><StackPanel>
            <TextBlock Style="{StaticResource TileLbl}" Text="GRAFIKSPEICHER"/>
            <TextBlock x:Name="MonVram" Style="{StaticResource TileVal}" Text="–"/>
          </StackPanel></Border>
          <Border Style="{StaticResource Tile}" Margin="0"><StackPanel>
            <TextBlock Style="{StaticResource TileLbl}" Text="ARK"/>
            <TextBlock x:Name="MonArk" Style="{StaticResource TileVal}" Text="nicht gestartet"/>
          </StackPanel></Border>
        </UniformGrid>
      </Grid>
    </Border>

    <!-- Einstellungen -->
    <ScrollViewer Grid.Row="1" Grid.Column="0" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
      <StackPanel>

        <Border Style="{StaticResource Card}">
          <StackPanel>
            <TextBlock Style="{StaticResource CardTitle}" Text="Profile"/>
            <TextBlock Style="{StaticResource Desc}" Text="Stellt alle Schalter mit einem Klick passend ein. Danach „1-KLICK BOOST“ drücken. Deine Auswahl wird beim Schließen gespeichert."/>
            <UniformGrid Rows="1" Margin="0,10,0,4">
              <Button x:Name="BtnProfSafe" Style="{StaticResource Btn}" Margin="0,0,8,0" Content="🛡  Sicher"/>
              <Button x:Name="BtnProfRec"  Style="{StaticResource Btn}" Margin="0,0,8,0" Content="★  Empfohlen"/>
              <Button x:Name="BtnProfMax"  Style="{StaticResource Btn}" Margin="0" Content="🔥  Maximum"/>
            </UniformGrid>
            <CheckBox x:Name="ChkAutoBoost" IsChecked="True"><StackPanel>
              <TextBlock Style="{StaticResource Head}" Text="Auto-Boost beim ARK-Start"/>
              <TextBlock Style="{StaticResource Desc}" Text="Solange diese App offen ist: Sobald ARK startet, bekommt es sofort hohe Priorität und der Arbeitsspeicher wird aufgeräumt."/>
            </StackPanel></CheckBox>
          </StackPanel>
        </Border>

        <Border Style="{StaticResource Card}">
          <StackPanel>
            <TextBlock Style="{StaticResource CardTitle}" Text="Windows-Optimierung"/>
            <CheckBox x:Name="ChkRestore" IsChecked="True"><StackPanel>
              <TextBlock Style="{StaticResource Head}" Text="Wiederherstellungspunkt erstellen"/>
              <TextBlock Style="{StaticResource Desc}" Text="Zusätzliche Sicherheit über die Windows-Systemwiederherstellung (falls aktiviert). Kann beim ersten Mal etwas dauern."/>
            </StackPanel></CheckBox>
            <CheckBox x:Name="ChkPower" IsChecked="True"><StackPanel>
              <TextBlock Style="{StaticResource Head}" Text="Energieplan „Ultimative Leistung“"/>
              <TextBlock Style="{StaticResource Desc}" Text="CPU taktet nicht mehr runter, keine Energiesparpausen. Fällt automatisch auf „Höchstleistung“ zurück."/>
            </StackPanel></CheckBox>
            <CheckBox x:Name="ChkGameMode" IsChecked="True"><StackPanel>
              <TextBlock Style="{StaticResource Head}" Text="Windows-Spielmodus an"/>
              <TextBlock Style="{StaticResource Desc}" Text="Windows priorisiert das Spiel und verschiebt Updates/Hintergrundarbeit."/>
            </StackPanel></CheckBox>
            <CheckBox x:Name="ChkGameBar" IsChecked="True"><StackPanel>
              <TextBlock Style="{StaticResource Head}" Text="Xbox Game Bar / Hintergrundaufnahme aus"/>
              <TextBlock Style="{StaticResource Desc}" Text="Die ständige Hintergrundaufnahme (Game DVR) kostet spürbar FPS."/>
            </StackPanel></CheckBox>
            <CheckBox x:Name="ChkScheduler" IsChecked="True"><StackPanel>
              <TextBlock Style="{StaticResource Head}" Text="Spiele bekommen Vorrang bei CPU und GPU"/>
              <TextBlock Style="{StaticResource Desc}" Text="Multimedia-Scheduler: höhere GPU-/CPU-Priorität für Spiele, weniger Reserve für Hintergrundprozesse."/>
            </StackPanel></CheckBox>
            <CheckBox x:Name="ChkNetwork" IsChecked="True"><StackPanel>
              <TextBlock Style="{StaticResource Head}" Text="Netzwerk-Drosselung aus"/>
              <TextBlock Style="{StaticResource Desc}" Text="Entfernt die Windows-Netzwerkdrosselung während Multimedia läuft – hilft gegen Lags auf Servern."/>
            </StackPanel></CheckBox>
            <CheckBox x:Name="ChkMouse" IsChecked="True"><StackPanel>
              <TextBlock Style="{StaticResource Head}" Text="Mausbeschleunigung aus"/>
              <TextBlock Style="{StaticResource Desc}" Text="Präzises, gleichmäßiges Zielen (Zeigerbeschleunigung verbessern = aus)."/>
            </StackPanel></CheckBox>
            <CheckBox x:Name="ChkNotify" IsChecked="True"><StackPanel>
              <TextBlock Style="{StaticResource Head}" Text="Windows-Benachrichtigungen aus"/>
              <TextBlock Style="{StaticResource Desc}" Text="Keine Popups mitten im Kampf. Wird mit „Alles rückgängig“ wieder eingeschaltet."/>
            </StackPanel></CheckBox>
            <CheckBox x:Name="ChkBgApps" IsChecked="True"><StackPanel>
              <TextBlock Style="{StaticResource Head}" Text="Windows-Hintergrund-Apps aus"/>
              <TextBlock Style="{StaticResource Desc}" Text="Store-Apps dürfen nicht mehr im Hintergrund laufen (Discord, Steam usw. sind nicht betroffen)."/>
            </StackPanel></CheckBox>
            <CheckBox x:Name="ChkPowerThrottle" IsChecked="True"><StackPanel>
              <TextBlock Style="{StaticResource Head}" Text="Energiedrosselung (Power Throttling) aus"/>
              <TextBlock Style="{StaticResource Desc}" Text="Windows bremst Programme im Hintergrund nicht mehr aus – wichtig, wenn ARK kurz minimiert ist (Alt+Tab)."/>
            </StackPanel></CheckBox>
            <CheckBox x:Name="ChkStickyKeys" IsChecked="True"><StackPanel>
              <TextBlock Style="{StaticResource Head}" Text="Einrastfunktion-Popup aus (5× Shift)"/>
              <TextBlock Style="{StaticResource Desc}" Text="Kein „Einrastfunktion aktivieren?“-Fenster mehr, das dich mitten im Spiel rauswirft. Wirkt ab der nächsten Anmeldung."/>
            </StackPanel></CheckBox>
            <CheckBox x:Name="ChkTransparency" IsChecked="True"><StackPanel>
              <TextBlock Style="{StaticResource Head}" Text="Transparenzeffekte aus"/>
              <TextBlock Style="{StaticResource Desc}" Text="Spart etwas GPU-Leistung für Taskleiste und Fenster."/>
            </StackPanel></CheckBox>
            <CheckBox x:Name="ChkHags" IsChecked="False"><StackPanel>
              <TextBlock Style="{StaticResource Head}" Text="Hardwarebeschleunigte GPU-Planung (Neustart nötig)"/>
              <TextBlock Style="{StaticResource Desc}" Text="Bei NVIDIA ab GTX 10xx meist besser. Wirkt erst nach einem PC-Neustart."/>
            </StackPanel></CheckBox>
          </StackPanel>
        </Border>

        <Border Style="{StaticResource Card}">
          <StackPanel>
            <TextBlock Style="{StaticResource CardTitle}" Text="ARK-Optimierung"/>
            <CheckBox x:Name="ChkFso" IsChecked="True"><StackPanel>
              <TextBlock Style="{StaticResource Head}" Text="Vollbildoptimierung für ARK aus"/>
              <TextBlock Style="{StaticResource Desc}" Text="Echtes Vollbild – weniger Input-Lag und oft stabilere FPS."/>
            </StackPanel></CheckBox>
            <CheckBox x:Name="ChkGpuPref" IsChecked="True"><StackPanel>
              <TextBlock Style="{StaticResource Head}" Text="ARK nutzt immer die starke Grafikkarte"/>
              <TextBlock Style="{StaticResource Desc}" Text="Windows-Grafikeinstellung „Hohe Leistung“ für ARK."/>
            </StackPanel></CheckBox>
            <CheckBox x:Name="ChkPriority" IsChecked="True"><StackPanel>
              <TextBlock Style="{StaticResource Head}" Text="ARK startet mit hoher CPU-Priorität"/>
              <TextBlock Style="{StaticResource Desc}" Text="Gilt ab dem nächsten Start automatisch; läuft ARK gerade, wird es sofort hochgestuft."/>
            </StackPanel></CheckBox>
            <CheckBox x:Name="ChkIntros" IsChecked="True"><StackPanel>
              <TextBlock Style="{StaticResource Head}" Text="Intro-Videos überspringen (nur ASE)"/>
              <TextBlock Style="{StaticResource Desc}" Text="ARK startet schneller. Die Videos werden nur umbenannt und mit „Alles rückgängig“ wiederhergestellt."/>
            </StackPanel></CheckBox>
            <CheckBox x:Name="ChkGraphics" IsChecked="True"><StackPanel>
              <TextBlock Style="{StaticResource Head}" Text="Grafik-Einstellungen in den ARK-Configs anpassen"/>
              <TextBlock Style="{StaticResource Desc}" Text="ARK muss dafür geschlossen sein. Die Original-Configs werden vorher gesichert."/>
            </StackPanel></CheckBox>

            <Grid Margin="52,4,0,0">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="16"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <StackPanel Grid.Column="0">
                <TextBlock Style="{StaticResource Desc}" Text="Grafik-Preset"/>
                <ComboBox x:Name="CmbPreset" SelectedIndex="2">
                  <ComboBoxItem Content="Nicht ändern"/>
                  <ComboBoxItem Content="Maximale FPS (niedrig)"/>
                  <ComboBoxItem Content="Ausgewogen (mittel)"/>
                </ComboBox>
                <TextBlock Style="{StaticResource Desc}" Text="FPS-Limit"/>
                <ComboBox x:Name="CmbFps" SelectedIndex="1">
                  <ComboBoxItem Content="Nicht ändern"/>
                  <ComboBoxItem Content="Unbegrenzt"/>
                  <ComboBoxItem Content="60 FPS"/>
                  <ComboBoxItem Content="75 FPS"/>
                  <ComboBoxItem Content="120 FPS"/>
                  <ComboBoxItem Content="144 FPS"/>
                  <ComboBoxItem Content="165 FPS"/>
                  <ComboBoxItem Content="240 FPS"/>
                </ComboBox>
              </StackPanel>
              <StackPanel Grid.Column="2">
                <TextBlock Style="{StaticResource Desc}" Text="Render-Auflösung"/>
                <ComboBox x:Name="CmbRes" SelectedIndex="0">
                  <ComboBoxItem Content="Nicht ändern"/>
                  <ComboBoxItem Content="100 % (scharf)"/>
                  <ComboBoxItem Content="90 %"/>
                  <ComboBoxItem Content="80 %"/>
                  <ComboBoxItem Content="75 %"/>
                  <ComboBoxItem Content="70 % (max. FPS)"/>
                </ComboBox>
                <CheckBox x:Name="ChkVsync" IsChecked="True" Margin="0,8,0,4"><TextBlock Style="{StaticResource Head}" Text="V-Sync aus"/></CheckBox>
                <CheckBox x:Name="ChkPostFx" IsChecked="True" Margin="0,4,0,4"><TextBlock Style="{StaticResource Head}" Text="Motion Blur, Tiefenunschärfe, Lens Flare aus"/></CheckBox>
              </StackPanel>
            </Grid>
          </StackPanel>
        </Border>

        <Border Style="{StaticResource Card}">
          <StackPanel>
            <TextBlock Style="{StaticResource CardTitle}" Text="Aufräumen"/>
            <CheckBox x:Name="ChkTemp" IsChecked="True"><StackPanel>
              <TextBlock Style="{StaticResource Head}" Text="Temporäre Dateien löschen"/>
              <TextBlock Style="{StaticResource Desc}" Text="Leert die Temp-Ordner von Windows und deinem Benutzer. Gesperrte Dateien werden übersprungen."/>
            </StackPanel></CheckBox>
            <CheckBox x:Name="ChkRam" IsChecked="True"><StackPanel>
              <TextBlock Style="{StaticResource Head}" Text="Arbeitsspeicher freigeben"/>
              <TextBlock Style="{StaticResource Desc}" Text="Räumt den RAM anderer Programme auf – am besten direkt vor dem Spielstart. ARK selbst wird nicht angefasst."/>
            </StackPanel></CheckBox>
            <CheckBox x:Name="ChkShader" IsChecked="False"><StackPanel>
              <TextBlock Style="{StaticResource Head}" Text="Shader-Cache leeren"/>
              <TextBlock Style="{StaticResource Desc}" Text="Nur bei Rucklern nach Treiber-Updates sinnvoll. Der erste Start danach lädt etwas länger."/>
            </StackPanel></CheckBox>
            <CheckBox x:Name="ChkDns" IsChecked="True"><StackPanel>
              <TextBlock Style="{StaticResource Head}" Text="DNS-Cache leeren"/>
              <TextBlock Style="{StaticResource Desc}" Text="Hilft, wenn Server-Liste oder Verbindung zu Servern hängt."/>
            </StackPanel></CheckBox>
          </StackPanel>
        </Border>

        <Border Style="{StaticResource Card}">
          <StackPanel>
            <TextBlock Style="{StaticResource CardTitle}" Text="Hintergrundprogramme"/>
            <TextBlock Style="{StaticResource Desc}" Text="Bekannte Programme, die gerade laufen und Leistung fressen. Auswählen und schließen – Browser werden normal geschlossen (wie mit dem X), Steam wird nie angefasst."/>
            <StackPanel x:Name="PnlApps" Margin="0,8,0,4"/>
            <CheckBox x:Name="ChkCloseApps" IsChecked="False"><StackPanel>
              <TextBlock Style="{StaticResource Head}" Text="Ausgewählte Programme beim Boost automatisch schließen"/>
            </StackPanel></CheckBox>
            <UniformGrid Rows="1" Margin="0,6,0,0">
              <Button x:Name="BtnScanApps"  Style="{StaticResource Btn}" Margin="0,0,8,0" Content="⟳  Aktualisieren"/>
              <Button x:Name="BtnCloseApps" Style="{StaticResource Btn}" Margin="0" Content="✖  Ausgewählte schließen"/>
            </UniformGrid>
          </StackPanel>
        </Border>

        <Border Style="{StaticResource Card}">
          <StackPanel>
            <TextBlock Style="{StaticResource CardTitle}" Text="Netzwerk und System"/>
            <Grid Margin="0,4,0,8">
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <Button x:Name="BtnPing" Style="{StaticResource Btn}" Margin="0" Content="📶  Ping-Test"/>
              <TextBlock x:Name="TxtPing" Grid.Column="1" Style="{StaticResource Desc}" VerticalAlignment="Center" Margin="12,0,0,0"
                         Text="Misst deine Verbindungsqualität (Ping und Paketverlust)."/>
            </Grid>
            <TextBlock Style="{StaticResource Head}" Text="Dein System" Margin="0,4,0,2"/>
            <TextBlock x:Name="TxtSysInfo" Style="{StaticResource Desc}" FontFamily="Consolas" Text="Wird geladen ..."/>
            <UniformGrid Rows="1" Margin="0,10,0,0">
              <Button x:Name="BtnOpenData"  Style="{StaticResource Btn}" Margin="0,0,8,0" Content="📁  Sicherungsordner"/>
              <Button x:Name="BtnOpenConfig" Style="{StaticResource Btn}" Margin="0" Content="📁  ARK-Config-Ordner"/>
            </UniformGrid>
          </StackPanel>
        </Border>

        <Border Style="{StaticResource Card}">
          <StackPanel>
            <TextBlock Style="{StaticResource CardTitle}" Text="Steam-Startoptionen (optional)"/>
            <TextBlock Style="{StaticResource Desc}" Text="Steam → Bibliothek → Rechtsklick auf ARK → Eigenschaften → Startoptionen → einfügen."/>
            <TextBlock Style="{StaticResource Head}" Text="ARK: Survival Evolved" Margin="0,10,0,2"/>
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <TextBox x:Name="TxtLaunchAse" IsReadOnly="True" Background="#0E1014" Foreground="#E8EAF0" BorderBrush="#2C3240" Padding="8,6" VerticalContentAlignment="Center"
                       Text="-USEALLAVAILABLECORES -nomansky -high"/>
              <Button x:Name="BtnCopyAse" Grid.Column="1" Style="{StaticResource Btn}" Content="Kopieren" Margin="8,0,0,0"/>
            </Grid>
            <TextBlock Style="{StaticResource Desc}" Text="Für extrem schwache PCs zusätzlich: -sm4 -d3d10 -lowmemory (sieht deutlich schlechter aus)."/>
            <TextBlock Style="{StaticResource Head}" Text="ARK: Survival Ascended" Margin="0,10,0,2"/>
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <TextBox x:Name="TxtLaunchAsa" IsReadOnly="True" Background="#0E1014" Foreground="#E8EAF0" BorderBrush="#2C3240" Padding="8,6" VerticalContentAlignment="Center"
                       Text="-USEALLAVAILABLECORES"/>
              <Button x:Name="BtnCopyAsa" Grid.Column="1" Style="{StaticResource Btn}" Content="Kopieren" Margin="8,0,0,0"/>
            </Grid>
            <TextBlock Style="{StaticResource Desc}" Text="Bei ASA bringt das Abschalten von Lumen (globale Beleuchtung) am meisten – das erledigt das Preset „Maximale FPS“."/>
          </StackPanel>
        </Border>

      </StackPanel>
    </ScrollViewer>

    <!-- Aktionen + Protokoll -->
    <Grid Grid.Row="1" Grid.Column="2">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>
      <Border Style="{StaticResource Card}">
        <StackPanel>
          <Button x:Name="BtnBoost" Style="{StaticResource AccentBtn}" Padding="14,18" FontSize="20" Margin="0,0,0,10">
            <TextBlock Text="⚡  1-KLICK BOOST"/>
          </Button>
          <TextBlock Style="{StaticResource Desc}" Margin="0,0,0,12" TextAlignment="Center"
                     Text="Wendet alle eingeschalteten Optionen an. Alles wird vorher gesichert."/>
          <Button x:Name="BtnUndo" Style="{StaticResource Btn}" Content="↩  Alles rückgängig machen"/>
          <TextBlock x:Name="TxtStatus" Style="{StaticResource Desc}" TextAlignment="Center" Margin="0,4,0,0"/>
        </StackPanel>
      </Border>
      <Border Grid.Row="1" Style="{StaticResource Card}" Margin="0">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <TextBlock Style="{StaticResource CardTitle}" Text="Protokoll"/>
          <TextBox x:Name="TxtLog" Grid.Row="1" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"
                   Background="#0E1014" Foreground="#C9CEDA" BorderThickness="0" FontFamily="Consolas" FontSize="11.5" Padding="6"/>
        </Grid>
      </Border>
    </Grid>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$Window = [Windows.Markup.XamlReader]::Load($reader)

$ui = @{}
foreach ($n in @('TxtGames','BtnFolder','BtnStartASE','BtnStartASA','ChkRestore','ChkPower','ChkGameMode','ChkGameBar',
                 'ChkScheduler','ChkNetwork','ChkMouse','ChkNotify','ChkBgApps','ChkHags','ChkFso','ChkGpuPref',
                 'ChkPriority','ChkGraphics','CmbPreset','CmbFps','CmbRes','ChkVsync','ChkPostFx','ChkTemp','ChkRam',
                 'ChkShader','TxtLaunchAse','TxtLaunchAsa','BtnCopyAse','BtnCopyAsa','BtnBoost','BtnUndo','TxtStatus','TxtLog',
                 'MonCpu','MonRam','MonGpu','MonGpuTemp','MonVram','MonArk','BtnProfSafe','BtnProfRec','BtnProfMax',
                 'ChkAutoBoost','ChkPowerThrottle','ChkStickyKeys','ChkTransparency','ChkIntros','ChkDns','PnlApps',
                 'ChkCloseApps','BtnScanApps','BtnCloseApps','BtnPing','TxtPing','TxtSysInfo','BtnOpenData','BtnOpenConfig')) {
    $ui[$n] = $Window.FindName($n)
}

# ---------------------------------------------------------------------------
#  Protokoll
# ---------------------------------------------------------------------------
function Update-UiNow {
    $Window.Dispatcher.Invoke([action]{ }, [System.Windows.Threading.DispatcherPriority]::Background)
}

function Write-Log([string]$Message, [string]$Level = 'info') {
    switch ($Level) {
        'ok'    { $sym = '✔' }
        'warn'  { $sym = '⚠' }
        'err'   { $sym = '✖' }
        'head'  { $sym = '»' }
        default { $sym = '•' }
    }
    $line = '[{0}] {1} {2}' -f (Get-Date -Format 'HH:mm:ss'), $sym, $Message
    $ui.TxtLog.AppendText($line + "`r`n")
    $ui.TxtLog.ScrollToEnd()
    try { Add-Content -LiteralPath $LogFile -Value ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd'), $line) -Encoding UTF8 } catch { }
    Update-UiNow
}

function Invoke-Step([string]$Title, [scriptblock]$Action) {
    try {
        & $Action
    } catch {
        Write-Log "$Title – Fehler: $($_.Exception.Message)" 'err'
    }
}

function Update-Status {
    if (Test-HasChanges) {
        $ui.TxtStatus.Text = 'Status: Optimierungen aktiv (Sicherung vorhanden)'
        $ui.BtnUndo.IsEnabled = $true
    } else {
        $ui.TxtStatus.Text = 'Status: Originalzustand'
        $ui.BtnUndo.IsEnabled = $false
    }
}

function Set-Busy([bool]$Busy) {
    $script:IsBusy = $Busy
    foreach ($b in @('BtnBoost','BtnUndo','BtnFolder','BtnStartASE','BtnStartASA','BtnProfSafe','BtnProfRec','BtnProfMax',
                     'BtnScanApps','BtnCloseApps','BtnPing')) { $ui[$b].IsEnabled = -not $Busy }
    if ($Busy) { $Window.Cursor = [System.Windows.Input.Cursors]::Wait } else { $Window.Cursor = $null; Update-Status }
    Update-UiNow
}

# ---------------------------------------------------------------------------
#  Optimierungen – Windows
# ---------------------------------------------------------------------------
function New-RestorePoint {
    Write-Log 'Erstelle Wiederherstellungspunkt (kann etwas dauern) ...'
    $warn = $null
    try {
        Checkpoint-Computer -Description 'ARK FPS Booster' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop -WarningVariable warn -WarningAction SilentlyContinue
        if ($warn) { Write-Log 'Wiederherstellungspunkt übersprungen (Windows erlaubt nur einen pro 24 Std.). Eigene Sicherung ist trotzdem aktiv.' 'warn' }
        else { Write-Log 'Wiederherstellungspunkt erstellt' 'ok' }
    } catch {
        Write-Log 'Wiederherstellungspunkt nicht möglich (Systemschutz evtl. deaktiviert). Eigene Sicherung ist trotzdem aktiv.' 'warn'
    }
}

function Get-ActivePowerGuid {
    $r = Invoke-Native 'powercfg.exe' @('/getactivescheme')
    if ($r.Output -match $GuidRx) { return $Matches[0] }
    return $null
}

function Set-PowerPlan {
    $current = Get-ActivePowerGuid
    if (-not $script:State.PowerOriginal -and $current) { $script:State.PowerOriginal = $current }

    $target = $null
    $list = (Invoke-Native 'powercfg.exe' @('/list')).Output
    if ($script:State.UltimateGuid -and $list -match [regex]::Escape($script:State.UltimateGuid)) {
        $target = $script:State.UltimateGuid
    } else {
        $dup = Invoke-Native 'powercfg.exe' @('-duplicatescheme', 'e9a42b02-d5df-448d-aa00-03f14749eb61')
        if ($dup.Code -eq 0 -and $dup.Output -match $GuidRx) {
            $target = $Matches[0]
            $script:State.UltimateGuid = $target
        }
    }

    $name = 'Ultimative Leistung'
    if ($target) {
        $set = Invoke-Native 'powercfg.exe' @('/setactive', $target)
        if ($set.Code -ne 0) { $target = $null }
    }
    if (-not $target) {
        $name = 'Höchstleistung'
        $set = Invoke-Native 'powercfg.exe' @('/setactive', '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c')
        if ($set.Code -ne 0) { throw 'Energieplan konnte nicht gesetzt werden (evtl. von deinem Laptop-Hersteller gesperrt).' }
    }
    Write-Log ("Energieplan '" + $name + "' aktiv") 'ok'
}

function Set-WindowsTweaks {
    if ($ui.ChkGameMode.IsChecked) {
        Invoke-Step 'Spielmodus' {
            Set-TrackedValue 'HKCU\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1 'DWord'
            Set-TrackedValue 'HKCU\Software\Microsoft\GameBar' 'AllowAutoGameMode'   1 'DWord'
            Write-Log 'Windows-Spielmodus an' 'ok'
        }
    }
    if ($ui.ChkGameBar.IsChecked) {
        Invoke-Step 'Game Bar' {
            Set-TrackedValue 'HKCU\System\GameConfigStore' 'GameDVR_Enabled' 0 'DWord'
            Set-TrackedValue 'HKCU\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0 'DWord'
            Write-Log 'Xbox-Hintergrundaufnahme aus' 'ok'
        }
    }
    if ($ui.ChkScheduler.IsChecked) {
        Invoke-Step 'Spiele-Priorität' {
            $mm = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
            Set-TrackedValue $mm 'SystemResponsiveness' 10 'DWord'
            Set-TrackedValue "$mm\Tasks\Games" 'GPU Priority'        8      'DWord'
            Set-TrackedValue "$mm\Tasks\Games" 'Priority'            6      'DWord'
            Set-TrackedValue "$mm\Tasks\Games" 'Scheduling Category' 'High' 'String'
            Set-TrackedValue "$mm\Tasks\Games" 'SFIO Priority'       'High' 'String'
            Write-Log 'Spiele haben Vorrang bei CPU/GPU' 'ok'
        }
    }
    if ($ui.ChkNetwork.IsChecked) {
        Invoke-Step 'Netzwerk' {
            # -1 entspricht 0xFFFFFFFF = Drosselung aus
            Set-TrackedValue 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'NetworkThrottlingIndex' (-1) 'DWord'
            Write-Log 'Netzwerk-Drosselung aus' 'ok'
        }
    }
    if ($ui.ChkMouse.IsChecked) {
        Invoke-Step 'Maus' {
            Set-TrackedValue 'HKCU\Control Panel\Mouse' 'MouseSpeed'      '0' 'String'
            Set-TrackedValue 'HKCU\Control Panel\Mouse' 'MouseThreshold1' '0' 'String'
            Set-TrackedValue 'HKCU\Control Panel\Mouse' 'MouseThreshold2' '0' 'String'
            Set-MouseFromRegistry
            Write-Log 'Mausbeschleunigung aus' 'ok'
        }
    }
    if ($ui.ChkNotify.IsChecked) {
        Invoke-Step 'Benachrichtigungen' {
            Set-TrackedValue 'HKCU\Software\Microsoft\Windows\CurrentVersion\PushNotifications' 'ToastEnabled' 0 'DWord'
            Write-Log 'Benachrichtigungen aus' 'ok'
        }
    }
    if ($ui.ChkBgApps.IsChecked) {
        Invoke-Step 'Hintergrund-Apps' {
            Set-TrackedValue 'HKCU\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 1 'DWord'
            Write-Log 'Windows-Hintergrund-Apps aus' 'ok'
        }
    }
    if ($ui.ChkPowerThrottle.IsChecked) {
        Invoke-Step 'Power Throttling' {
            Set-TrackedValue 'HKLM\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff' 1 'DWord'
            Write-Log 'Energiedrosselung aus' 'ok'
        }
    }
    if ($ui.ChkStickyKeys.IsChecked) {
        Invoke-Step 'Einrastfunktion' {
            Set-TrackedValue 'HKCU\Control Panel\Accessibility\StickyKeys'        'Flags' '506' 'String'
            Set-TrackedValue 'HKCU\Control Panel\Accessibility\ToggleKeys'        'Flags' '58'  'String'
            Set-TrackedValue 'HKCU\Control Panel\Accessibility\Keyboard Response' 'Flags' '122' 'String'
            Write-Log 'Einrastfunktion-/Tastatur-Popups aus (ab nächster Anmeldung)' 'ok'
        }
    }
    if ($ui.ChkTransparency.IsChecked) {
        Invoke-Step 'Transparenz' {
            Set-TrackedValue 'HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 0 'DWord'
            Write-Log 'Transparenzeffekte aus' 'ok'
        }
    }
    if ($ui.ChkHags.IsChecked) {
        Invoke-Step 'GPU-Planung' {
            $cur = Get-RegValue 'HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode'
            if ($cur -ne 2) {
                Set-TrackedValue 'HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2 'DWord'
                $script:NeedsReboot = $true
                Write-Log 'Hardwarebeschleunigte GPU-Planung an (wirkt nach Neustart)' 'ok'
            } else {
                Write-Log 'Hardwarebeschleunigte GPU-Planung war schon an' 'ok'
            }
        }
    }
}

# ---------------------------------------------------------------------------
#  Optimierungen – ARK
# ---------------------------------------------------------------------------
function Set-ArkExeTweaks($g) {
    if ($ui.ChkFso.IsChecked) {
        Invoke-Step "Vollbildoptimierung ($($g.Short))" {
            $p   = 'HKCU\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers'
            $cur = [string](Get-RegValue $p $g.Exe)
            if ($cur -notmatch 'DISABLEDXMAXIMIZEDWINDOWEDMODE') {
                if ([string]::IsNullOrWhiteSpace($cur)) { $new = '~ DISABLEDXMAXIMIZEDWINDOWEDMODE' }
                else { $new = "$($cur.TrimEnd()) DISABLEDXMAXIMIZEDWINDOWEDMODE" }
                Set-TrackedValue $p $g.Exe $new 'String'
            }
            Write-Log "$($g.Short): Vollbildoptimierung aus" 'ok'
        }
    }
    if ($ui.ChkGpuPref.IsChecked) {
        Invoke-Step "GPU-Präferenz ($($g.Short))" {
            $p   = 'HKCU\Software\Microsoft\DirectX\UserGpuPreferences'
            $cur = [string](Get-RegValue $p $g.Exe)
            if ($cur -match 'GpuPreference=\d+;') { $new = $cur -replace 'GpuPreference=\d+;', 'GpuPreference=2;' }
            else { $new = "GpuPreference=2;$cur" }
            if ($new -ne $cur) { Set-TrackedValue $p $g.Exe $new 'String' }
            Write-Log "$($g.Short): nutzt Hochleistungs-Grafikkarte" 'ok'
        }
    }
    if ($ui.ChkPriority.IsChecked) {
        Invoke-Step "CPU-Priorität ($($g.Short))" {
            $exeName = Split-Path $g.Exe -Leaf
            Set-TrackedValue "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$exeName\PerfOptions" 'CpuPriorityClass' 3 'DWord'
            $running = @(Get-Process -Name $g.Proc -ErrorAction SilentlyContinue)
            foreach ($proc in $running) {
                try { $proc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::High } catch { }
            }
            if ($running.Count -gt 0) { Write-Log "$($g.Short): hohe CPU-Priorität (sofort + bei jedem Start)" 'ok' }
            else { Write-Log "$($g.Short): startet ab jetzt mit hoher CPU-Priorität" 'ok' }
        }
    }
}

function Skip-IntroVideos($g) {
    if ($g.Short -ne 'ASE') { return }
    if (@(Get-Process -Name $g.Proc -ErrorAction SilentlyContinue).Count -gt 0) {
        Write-Log 'ASE läuft gerade – Intro-Videos übersprungen.' 'warn'
        return
    }
    $dir = Join-Path $g.Root 'ShooterGame\Content\Movies'
    if (-not (Test-Path -LiteralPath $dir)) { Write-Log 'ASE: Kein Intro-Ordner gefunden – nichts zu tun.' 'ok'; return }
    $count = 0
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -Force -ErrorAction SilentlyContinue)) {
        if ($f.Extension -notin @('.mp4', '.bik', '.webm', '.wmv')) { continue }
        $target = $f.FullName + '.arkboost'
        if (Test-Path -LiteralPath $target) { continue }
        Rename-Item -LiteralPath $f.FullName -NewName ($f.Name + '.arkboost') -ErrorAction Stop
        [void]$script:State.Renamed.Add([pscustomobject]@{ From = $f.FullName; To = $target })
        $count++
    }
    Save-State
    if ($count -gt 0) { Write-Log "ASE: $count Intro-Videos deaktiviert" 'ok' } else { Write-Log 'ASE: Intro-Videos waren schon deaktiviert' 'ok' }
}

function Read-IniFile([string]$Path) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $enc = New-Object System.Text.UTF8Encoding($false)
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { $enc = [System.Text.Encoding]::Unicode }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) { $enc = [System.Text.Encoding]::BigEndianUnicode }
    elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $enc = New-Object System.Text.UTF8Encoding($true) }
    $text  = [System.IO.File]::ReadAllText($Path, $enc)
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($l in ($text -split "\r?\n")) { $lines.Add($l) }
    return @{ Lines = $lines; Encoding = $enc }
}

function Set-IniValues([string]$Path, [string]$Section, [System.Collections.IDictionary]$Values) {
    if (Test-Path -LiteralPath $Path) {
        $ini = Read-IniFile $Path
    } else {
        $ini = @{ Lines = (New-Object System.Collections.Generic.List[string]); Encoding = (New-Object System.Text.UTF8Encoding($false)) }
    }
    $lines = $ini.Lines
    while ($lines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($lines[$lines.Count - 1])) { $lines.RemoveAt($lines.Count - 1) }

    $hdrRx = '^\s*\[' + [regex]::Escape($Section) + '\]\s*$'
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $hdrRx) { $start = $i; break }
    }
    if ($start -lt 0) {
        if ($lines.Count -gt 0) { $lines.Add('') }
        $lines.Add("[$Section]")
        $start = $lines.Count - 1
    }

    foreach ($key in @($Values.Keys)) {
        $val = $Values[$key]
        $end = $lines.Count
        for ($j = $start + 1; $j -lt $lines.Count; $j++) {
            if ($lines[$j] -match '^\s*\[') { $end = $j; break }
        }
        $keyRx = '^\s*' + [regex]::Escape($key) + '\s*='
        $found = $false
        for ($j = $start + 1; $j -lt $end; $j++) {
            if ($lines[$j] -match $keyRx) { $lines[$j] = "$key=$val"; $found = $true; break }
        }
        if (-not $found) {
            $ins = $end
            while ($ins -gt ($start + 1) -and [string]::IsNullOrWhiteSpace($lines[$ins - 1])) { $ins-- }
            $lines.Insert($ins, "$key=$val")
        }
    }
    $lines.Add('')

    $content = $lines -join "`r`n"
    $readOnly = $false
    if (Test-Path -LiteralPath $Path) {
        $fi = Get-Item -LiteralPath $Path -Force
        if ($fi.IsReadOnly) { $fi.IsReadOnly = $false; $readOnly = $true }
    }
    try {
        [System.IO.File]::WriteAllText($Path, $content, $ini.Encoding)
    } finally {
        if ($readOnly) { (Get-Item -LiteralPath $Path -Force).IsReadOnly = $true }
    }
}

function Backup-File([string]$Path, [string]$Tag) {
    if (@($script:State.IniBackups | Where-Object { $_.Source -eq $Path }).Count -gt 0) { return }
    $exists = Test-Path -LiteralPath $Path
    $bk = $null
    if ($exists) {
        $bk = Join-Path $BackupDir ('{0}_{1}' -f $Tag, (Split-Path $Path -Leaf))
        Copy-Item -LiteralPath $Path -Destination $bk -Force
    }
    [void]$script:State.IniBackups.Add([pscustomobject]@{ Source = $Path; Backup = $bk; Existed = $exists })
    Save-State
}

function Set-ArkGraphics($g) {
    if (@(Get-Process -Name $g.Proc -ErrorAction SilentlyContinue).Count -gt 0) {
        Write-Log "$($g.Short) läuft gerade – Grafik-Configs übersprungen. Spiel schließen und nochmal boosten." 'warn'
        return
    }
    $gus = Join-Path $g.ConfigDir 'GameUserSettings.ini'
    $eng = Join-Path $g.ConfigDir 'Engine.ini'
    if (-not (Test-Path -LiteralPath $gus)) {
        Write-Log "$($g.Short): Keine Config gefunden – starte ARK einmal, beende es und booste dann nochmal." 'warn'
        return
    }
    Backup-File $gus $g.Short
    Backup-File $eng $g.Short

    $userSec = '/Script/ShooterGame.ShooterGameUserSettings'
    $us = [ordered]@{}
    if ($ui.ChkVsync.IsChecked) { $us['bUseVSync'] = 'False' }

    $fpsMap = @(-1, 0, 60, 75, 120, 144, 165, 240)
    $fpsIdx = [Math]::Max(0, $ui.CmbFps.SelectedIndex)
    $fps    = $fpsMap[$fpsIdx]
    if ($fps -ge 0) { $us['FrameRateLimit'] = ('{0}.000000' -f $fps) }

    $preset = $ui.CmbPreset.SelectedIndex
    $sg = [ordered]@{}
    if ($preset -eq 1) {
        $sg['sg.ViewDistanceQuality'] = '1'; $sg['sg.AntiAliasingQuality'] = '0'; $sg['sg.ShadowQuality'] = '0'
        $sg['sg.PostProcessQuality']  = '0'; $sg['sg.TextureQuality']      = '1'; $sg['sg.EffectsQuality'] = '0'
        $sg['sg.FoliageQuality']      = '0'
        if ($g.Short -eq 'ASA') {
            $sg['sg.ShadingQuality'] = '0'; $sg['sg.GlobalIlluminationQuality'] = '0'; $sg['sg.ReflectionQuality'] = '0'
        } else {
            $us['bDisableBloom'] = 'True'; $us['bDisableLightShafts'] = 'True'
        }
    } elseif ($preset -eq 2) {
        $sg['sg.ViewDistanceQuality'] = '2'; $sg['sg.AntiAliasingQuality'] = '2'; $sg['sg.ShadowQuality'] = '1'
        $sg['sg.PostProcessQuality']  = '1'; $sg['sg.TextureQuality']      = '2'; $sg['sg.EffectsQuality'] = '1'
        $sg['sg.FoliageQuality']      = '1'
        if ($g.Short -eq 'ASA') {
            $sg['sg.ShadingQuality'] = '1'; $sg['sg.GlobalIlluminationQuality'] = '1'; $sg['sg.ReflectionQuality'] = '1'
        }
    }
    $resMap = @(-1, 100, 90, 80, 75, 70)
    $resIdx = [Math]::Max(0, $ui.CmbRes.SelectedIndex)
    if ($resMap[$resIdx] -gt 0) { $sg['sg.ResolutionQuality'] = [string]$resMap[$resIdx] }

    if ($us.Count -gt 0) { Set-IniValues $gus $userSec $us }
    if ($sg.Count -gt 0) { Set-IniValues $gus 'ScalabilityGroups' $sg }

    if ($ui.ChkPostFx.IsChecked) {
        Set-IniValues $eng 'SystemSettings' ([ordered]@{
            'r.MotionBlurQuality'       = '0'
            'r.DepthOfFieldQuality'     = '0'
            'r.LensFlareQuality'        = '0'
            'r.SceneColorFringeQuality' = '0'
        })
    }
    if ($g.Short -eq 'ASE' -and $fps -ge 0) {
        # ASE glättet/limitiert die Framerate sonst selbst
        Set-IniValues $eng '/Script/Engine.Engine' ([ordered]@{ 'bSmoothFrameRate' = 'False' })
    }

    $parts = @()
    if ($preset -eq 1) { $parts += 'Preset Maximale FPS' } elseif ($preset -eq 2) { $parts += 'Preset Ausgewogen' }
    if ($fps -eq 0) { $parts += 'FPS unbegrenzt' } elseif ($fps -gt 0) { $parts += "FPS-Limit $fps" }
    if ($resMap[$resIdx] -gt 0) { $parts += "Auflösung $($resMap[$resIdx]) %" }
    if ($ui.ChkVsync.IsChecked) { $parts += 'V-Sync aus' }
    if ($ui.ChkPostFx.IsChecked) { $parts += 'Effekte aus' }
    if ($parts.Count -eq 0) { $parts += 'nichts geändert' }
    Write-Log ("$($g.Short): Grafik-Config angepasst (" + ($parts -join ', ') + ')') 'ok'
}

# ---------------------------------------------------------------------------
#  Aufräumen
# ---------------------------------------------------------------------------
function Clear-FolderContents([string]$Dir) {
    $freed = [long]0
    if (-not $Dir -or -not (Test-Path -LiteralPath $Dir)) { return $freed }
    foreach ($item in @(Get-ChildItem -LiteralPath $Dir -Force -ErrorAction SilentlyContinue)) {
        $size = [long]0
        if ($item.PSIsContainer) {
            $sum = (Get-ChildItem -LiteralPath $item.FullName -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
            if ($sum) { $size = [long]$sum }
        } else {
            $size = [long]$item.Length
        }
        try {
            Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
            $freed += $size
        } catch { }
    }
    return $freed
}

function Clear-TempFiles {
    $dirs = @($env:TEMP, (Join-Path $env:SystemRoot 'Temp')) | Select-Object -Unique
    $freed = [long]0
    foreach ($d in $dirs) { $freed += Clear-FolderContents $d }
    Write-Log ("Temporäre Dateien gelöscht ({0} frei)" -f (Format-Size $freed)) 'ok'
}

function Clear-ShaderCache {
    $dirs = @(
        (Join-Path $env:LOCALAPPDATA 'NVIDIA\DXCache'),
        (Join-Path $env:LOCALAPPDATA 'NVIDIA\GLCache'),
        (Join-Path $env:LOCALAPPDATA 'D3DSCache'),
        (Join-Path $env:LOCALAPPDATA 'AMD\DxCache')
    )
    $freed = [long]0
    foreach ($d in $dirs) { $freed += Clear-FolderContents $d }
    Write-Log ("Shader-Cache geleert ({0} frei)" -f (Format-Size $freed)) 'ok'
}

function Clear-Ram {
    $before = $null
    try { $before = [long](Get-CimInstance -ClassName Win32_OperatingSystem).FreePhysicalMemory } catch { }
    # Spiel und Anti-Cheat (BattlEye / EasyAntiCheat) werden nie angefasst
    $skip = @('ShooterGame', 'ShooterGame_BE', 'ArkAscended', 'ArkAscended_BE', 'BEService', 'BEService_x64',
              'EasyAntiCheat', 'EasyAntiCheat_EOS', 'Idle', 'System', 'audiodg', 'dwm', 'csrss', 'smss', 'wininit')
    foreach ($p in @(Get-Process)) {
        if ($skip -contains $p.ProcessName) { continue }
        try { [void][ArkBoost.Native]::EmptyWorkingSet($p.Handle) } catch { }
    }
    Start-Sleep -Milliseconds 600
    $msg = 'Arbeitsspeicher aufgeräumt'
    try {
        $after = [long](Get-CimInstance -ClassName Win32_OperatingSystem).FreePhysicalMemory
        if ($null -ne $before -and $after -gt $before) { $msg += (' ({0} zusätzlich frei)' -f (Format-Size (($after - $before) * 1KB))) }
    } catch { }
    Write-Log $msg 'ok'
}

# ---------------------------------------------------------------------------
#  Boost / Rückgängig
# ---------------------------------------------------------------------------
function Invoke-Boost {
    Set-Busy $true
    try {
        $script:NeedsReboot = $false
        Write-Log '1-Klick-Boost gestartet' 'head'

        if ($ui.ChkRestore.IsChecked) { Invoke-Step 'Wiederherstellungspunkt' { New-RestorePoint } }
        if ($ui.ChkPower.IsChecked)   { Invoke-Step 'Energieplan' { Set-PowerPlan } }
        Save-State

        Set-WindowsTweaks
        Save-State

        if ($script:Games.Count -eq 0 -and ($ui.ChkFso.IsChecked -or $ui.ChkGpuPref.IsChecked -or $ui.ChkPriority.IsChecked -or $ui.ChkGraphics.IsChecked)) {
            Write-Log 'Kein ARK gefunden – ARK-Optimierungen übersprungen. Nutze „Spielordner wählen“.' 'warn'
        }
        foreach ($g in $script:Games) {
            Set-ArkExeTweaks $g
            if ($ui.ChkGraphics.IsChecked) { Invoke-Step "Grafik-Config ($($g.Short))" { Set-ArkGraphics $g } }
            if ($ui.ChkIntros.IsChecked)   { Invoke-Step "Intro-Videos ($($g.Short))" { Skip-IntroVideos $g } }
            Save-State
        }

        if ($ui.ChkCloseApps.IsChecked) { Invoke-Step 'Hintergrundprogramme' { Close-SelectedApps } }
        if ($ui.ChkDns.IsChecked)    { Invoke-Step 'DNS-Cache' { Clear-DnsCache } }
        if ($ui.ChkTemp.IsChecked)   { Invoke-Step 'Temp-Dateien' { Clear-TempFiles } }
        if ($ui.ChkShader.IsChecked) { Invoke-Step 'Shader-Cache' { Clear-ShaderCache } }
        if ($ui.ChkRam.IsChecked)    { Invoke-Step 'Arbeitsspeicher' { Clear-Ram } }

        Save-State
        Write-Log 'Boost fertig – viel Spaß beim Zocken!' 'head'
        if ($script:NeedsReboot) {
            Write-Log 'Bitte den PC neu starten, damit die GPU-Planung aktiv wird.' 'warn'
            [void][System.Windows.MessageBox]::Show('Fertig! Für die GPU-Planung ist ein Neustart nötig.', $AppName, 'OK', 'Information')
        }
    } catch {
        Write-Log "Unerwarteter Fehler: $($_.Exception.Message)" 'err'
    } finally {
        try { Save-State } catch { }
        Set-Busy $false
    }
}

function Invoke-Undo {
    $answer = [System.Windows.MessageBox]::Show('Alle Änderungen des ARK FPS Boosters zurücksetzen?', $AppName, 'YesNo', 'Question')
    if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { return }

    Set-Busy $true
    try {
        Write-Log 'Setze alles zurück ...' 'head'

        # 0) Umbenannte Dateien (Intro-Videos)
        $keepRen = New-Object System.Collections.ArrayList
        foreach ($rn in @($script:State.Renamed)) {
            try {
                if ((Test-Path -LiteralPath $rn.To) -and -not (Test-Path -LiteralPath $rn.From)) {
                    Rename-Item -LiteralPath $rn.To -NewName (Split-Path $rn.From -Leaf) -ErrorAction Stop
                }
            } catch {
                [void]$keepRen.Add($rn)
                Write-Log "Datei nicht wiederhergestellt ($(Split-Path $rn.From -Leaf)): $($_.Exception.Message)" 'err'
            }
        }
        if (@($script:State.Renamed).Count -gt 0 -and $keepRen.Count -eq 0) { Write-Log 'Intro-Videos wiederhergestellt' 'ok' }
        $script:State.Renamed = $keepRen

        # 1) INI-Dateien
        $keepIni = New-Object System.Collections.ArrayList
        foreach ($b in @($script:State.IniBackups)) {
            try {
                $procs = @()
                foreach ($g in $script:Games) {
                    if ($b.Source.StartsWith($g.ConfigDir, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $procs += @(Get-Process -Name $g.Proc -ErrorAction SilentlyContinue)
                    }
                }
                if ($procs.Count -gt 0) { throw 'ARK läuft gerade – bitte schließen' }

                if ($b.Existed -and $b.Backup -and (Test-Path -LiteralPath $b.Backup)) {
                    if (Test-Path -LiteralPath $b.Source) {
                        $fi = Get-Item -LiteralPath $b.Source -Force
                        if ($fi.IsReadOnly) { $fi.IsReadOnly = $false }
                    }
                    Copy-Item -LiteralPath $b.Backup -Destination $b.Source -Force
                    Remove-Item -LiteralPath $b.Backup -Force -ErrorAction SilentlyContinue
                } elseif (-not $b.Existed -and (Test-Path -LiteralPath $b.Source)) {
                    Remove-Item -LiteralPath $b.Source -Force
                }
                Write-Log ("Config wiederhergestellt: " + (Split-Path $b.Source -Leaf)) 'ok'
            } catch {
                [void]$keepIni.Add($b)
                Write-Log ("Config nicht wiederhergestellt (" + (Split-Path $b.Source -Leaf) + "): $($_.Exception.Message)") 'err'
            }
        }
        $script:State.IniBackups = $keepIni

        # 2) Registry-Werte (in umgekehrter Reihenfolge)
        $keepReg = New-Object System.Collections.ArrayList
        $entries = @($script:State.Registry)
        [array]::Reverse($entries)
        foreach ($e in $entries) {
            try {
                $r = Get-RegBase $e.Path
                $k = $r.Base.OpenSubKey($r.Sub, $true)
                if ($null -ne $k) {
                    try {
                        if ($e.Existed) {
                            $kind = [Microsoft.Win32.RegistryValueKind]([string]$e.Kind)
                            $val  = $e.Value
                            if     ($kind -eq [Microsoft.Win32.RegistryValueKind]::DWord)       { $val = [int]$val }
                            elseif ($kind -eq [Microsoft.Win32.RegistryValueKind]::QWord)       { $val = [long]$val }
                            elseif ($kind -eq [Microsoft.Win32.RegistryValueKind]::Binary)      { $val = [byte[]]@($val) }
                            elseif ($kind -eq [Microsoft.Win32.RegistryValueKind]::MultiString) { $val = [string[]]@($val) }
                            else   { $val = [string]$val }
                            $k.SetValue([string]$e.Name, $val, $kind)
                        } else {
                            $k.DeleteValue([string]$e.Name, $false)
                        }
                    } finally { $k.Close() }
                }
            } catch {
                [void]$keepReg.Add($e)
                Write-Log "Registry-Wert nicht zurückgesetzt ($($e.Name)): $($_.Exception.Message)" 'err'
            }
        }
        $keepReg.Reverse()
        $script:State.Registry = $keepReg
        if ($keepReg.Count -eq 0) { Write-Log 'Windows-Einstellungen zurückgesetzt' 'ok' }

        # 3) Von uns angelegte (jetzt leere) Registry-Schlüssel entfernen
        $keepKeys = New-Object System.Collections.ArrayList
        $keys = @($script:State.CreatedKeys)
        [array]::Reverse($keys)
        foreach ($kp in $keys) {
            try {
                $r = Get-RegBase $kp
                $k = $r.Base.OpenSubKey($r.Sub)
                if ($null -eq $k) { continue }
                $empty = ($k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0)
                $k.Close()
                if ($empty) { $r.Base.DeleteSubKey($r.Sub, $false) }
            } catch {
                [void]$keepKeys.Add($kp)
            }
        }
        $keepKeys.Reverse()
        $script:State.CreatedKeys = $keepKeys

        # 4) Maus sofort übernehmen
        try { Set-MouseFromRegistry } catch { }

        # 5) Energieplan
        if ($script:State.PowerOriginal) {
            $set = Invoke-Native 'powercfg.exe' @('/setactive', $script:State.PowerOriginal)
            if ($set.Code -eq 0) {
                if ($script:State.UltimateGuid -and $script:State.UltimateGuid -ne $script:State.PowerOriginal) {
                    [void](Invoke-Native 'powercfg.exe' @('/delete', $script:State.UltimateGuid))
                }
                $script:State.PowerOriginal = $null
                $script:State.UltimateGuid  = $null
                Write-Log 'Ursprünglicher Energieplan aktiv' 'ok'
            } else {
                Write-Log 'Ursprünglicher Energieplan konnte nicht aktiviert werden' 'err'
            }
        }

        Save-State
        if (Test-HasChanges) { Write-Log 'Einiges konnte nicht zurückgesetzt werden – siehe oben. Erneut versuchen möglich.' 'warn' }
        else { Write-Log 'Alles ist wieder im Originalzustand.' 'head' }
    } catch {
        Write-Log "Unerwarteter Fehler: $($_.Exception.Message)" 'err'
    } finally {
        try { Save-State } catch { }
        Set-Busy $false
    }
}

# ---------------------------------------------------------------------------
#  Netzwerk
# ---------------------------------------------------------------------------
function Clear-DnsCache {
    $r = Invoke-Native 'ipconfig.exe' @('/flushdns')
    if ($r.Code -ne 0) { throw 'ipconfig /flushdns ist fehlgeschlagen' }
    Write-Log 'DNS-Cache geleert' 'ok'
}

function Test-Ping {
    $targets = @(
        @{ Name = 'Cloudflare'; Host = '1.1.1.1' },
        @{ Name = 'Google';     Host = '8.8.8.8' }
    )
    $ui.TxtPing.Text = 'Messe ...'
    Update-UiNow
    $ping  = New-Object System.Net.NetworkInformation.Ping
    $lines = @()
    $allAvg = @()
    foreach ($t in $targets) {
        $times = @()
        $lost  = 0
        for ($i = 0; $i -lt 5; $i++) {
            try {
                $r = $ping.Send($t.Host, 1000)
                if ($r.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) { $times += [int]$r.RoundtripTime } else { $lost++ }
            } catch { $lost++ }
            Update-UiNow
        }
        $loss = [int](100 * $lost / 5)
        if ($times.Count -gt 0) {
            $stats = $times | Measure-Object -Average -Minimum -Maximum
            $avg = [int][math]::Round($stats.Average)
            $jit = [int]($stats.Maximum - $stats.Minimum)
            $allAvg += $avg
            $lines += ('{0}: Ø {1} ms, Schwankung {2} ms, Verlust {3} %' -f $t.Name, $avg, $jit, $loss)
        } else {
            $lines += ('{0}: keine Antwort' -f $t.Name)
        }
    }
    $ping.Dispose()
    if ($allAvg.Count -gt 0) {
        $best = ($allAvg | Measure-Object -Minimum).Minimum
        if     ($best -lt 30)  { $rating = 'sehr gut' }
        elseif ($best -lt 60)  { $rating = 'gut' }
        elseif ($best -lt 100) { $rating = 'okay' }
        else                   { $rating = 'schlecht – LAN-Kabel statt WLAN hilft oft' }
        $lines += "Bewertung: $rating"
    } else {
        $lines += 'Keine Internetverbindung?'
    }
    $ui.TxtPing.Text = ($lines -join "`n")
    Write-Log ('Ping-Test: ' + ($lines -join ' | ')) 'ok'
}

# ---------------------------------------------------------------------------
#  Systeminfo
# ---------------------------------------------------------------------------
function Get-SysInfoText {
    $out = @()
    try {
        $cpu = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1
        $out += ('CPU:      {0} ({1} Kerne / {2} Threads)' -f $cpu.Name.Trim(), $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors)
    } catch { }
    try {
        foreach ($v in @(Get-CimInstance -ClassName Win32_VideoController | Where-Object { $_.Name -notmatch 'Basic|Virtual|Remote|Parsec|Meta' })) {
            $drv = [string]$v.DriverVersion
            if ($v.Name -match 'NVIDIA' -and $drv) {
                $digits = $drv -replace '\.', ''
                if ($digits.Length -ge 5) { $d = $digits.Substring($digits.Length - 5); $drv = $d.Substring(0, 3) + '.' + $d.Substring(3) }
            }
            $out += ('GPU:      {0} (Treiber {1})' -f $v.Name, $drv)
        }
    } catch { }
    try {
        $ram = [math]::Round((Get-CimInstance -ClassName Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
        $out += ('RAM:      {0} GB' -f $ram)
    } catch { }
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        $out += ('System:   {0} (Build {1})' -f $os.Caption.Trim(), $os.BuildNumber)
    } catch { }
    try {
        $r = Invoke-Native 'powercfg.exe' @('/getactivescheme')
        if ($r.Output -match '\(([^)]+)\)') { $out += ('Energie:  {0}' -f $Matches[1]) }
    } catch { }
    if ($out.Count -eq 0) { return 'Systeminfos konnten nicht gelesen werden.' }
    return ($out -join "`n")
}

# ---------------------------------------------------------------------------
#  Hintergrundprogramme
# ---------------------------------------------------------------------------
$KnownApps = @(
    @{ Proc = 'chrome';             Name = 'Google Chrome';               Kill = $false },
    @{ Proc = 'msedge';             Name = 'Microsoft Edge';              Kill = $false },
    @{ Proc = 'firefox';            Name = 'Firefox';                     Kill = $false },
    @{ Proc = 'opera';              Name = 'Opera / Opera GX';            Kill = $false },
    @{ Proc = 'brave';              Name = 'Brave';                       Kill = $false },
    @{ Proc = 'EpicGamesLauncher';  Name = 'Epic Games Launcher';         Kill = $true },
    @{ Proc = 'EADesktop';          Name = 'EA App';                      Kill = $true },
    @{ Proc = 'upc';                Name = 'Ubisoft Connect';             Kill = $true },
    @{ Proc = 'Battle.net';         Name = 'Battle.net';                  Kill = $true },
    @{ Proc = 'GalaxyClient';       Name = 'GOG Galaxy';                  Kill = $true },
    @{ Proc = 'RiotClientServices'; Name = 'Riot Client';                 Kill = $true },
    @{ Proc = 'OneDrive';           Name = 'OneDrive (Synchronisierung)'; Kill = $true },
    @{ Proc = 'Dropbox';            Name = 'Dropbox';                     Kill = $true },
    @{ Proc = 'ms-teams';           Name = 'Microsoft Teams';             Kill = $true },
    @{ Proc = 'Teams';              Name = 'Microsoft Teams (klassisch)'; Kill = $true },
    @{ Proc = 'Spotify';            Name = 'Spotify';                     Kill = $true },
    @{ Proc = 'WhatsApp';           Name = 'WhatsApp';                    Kill = $true },
    @{ Proc = 'Telegram';           Name = 'Telegram';                    Kill = $true },
    @{ Proc = 'Overwolf';           Name = 'Overwolf';                    Kill = $true },
    @{ Proc = 'Creative Cloud';     Name = 'Adobe Creative Cloud';        Kill = $true },
    @{ Proc = 'Discord';            Name = 'Discord (Achtung: Sprachchat)'; Kill = $true }
)

function Update-AppList {
    $ui.PnlApps.Children.Clear()
    $any = $false
    foreach ($a in $KnownApps) {
        $procs = @(Get-Process -Name $a.Proc -ErrorAction SilentlyContinue)
        if ($procs.Count -eq 0) { continue }
        $any = $true
        $mb = [math]::Round((($procs | Measure-Object -Property WorkingSet64 -Sum).Sum) / 1MB)
        $cb = New-Object System.Windows.Controls.CheckBox
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = ('{0}   ·   {1} MB RAM' -f $a.Name, $mb)
        $tb.TextWrapping = [System.Windows.TextWrapping]::Wrap
        $cb.Content = $tb
        $cb.Tag = $a.Proc
        $cb.Margin = New-Object System.Windows.Thickness(0, 4, 0, 4)
        $cb.IsChecked = ($script:Settings.Apps -contains $a.Proc)
        $cb.Add_Click({
            param($src, $evt)
            $name = [string]$src.Tag
            if ($src.IsChecked) {
                if (-not ($script:Settings.Apps -contains $name)) { [void]$script:Settings.Apps.Add($name) }
            } else {
                $script:Settings.Apps.Remove($name)
            }
        })
        [void]$ui.PnlApps.Children.Add($cb)
    }
    if (-not $any) {
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = 'Keine bekannten Hintergrundprogramme aktiv – sehr gut!'
        $tb.Foreground = $script:BrGood
        $tb.Margin = New-Object System.Windows.Thickness(0, 4, 0, 4)
        [void]$ui.PnlApps.Children.Add($tb)
    }
}

function Close-SelectedApps {
    $selected = @()
    foreach ($c in $ui.PnlApps.Children) {
        if ($c -is [System.Windows.Controls.CheckBox] -and $c.IsChecked) { $selected += [string]$c.Tag }
    }
    if ($selected.Count -eq 0) { Write-Log 'Keine Hintergrundprogramme ausgewählt' 'info'; return }

    foreach ($name in $selected) {
        foreach ($p in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
            try { if ($p.MainWindowHandle -ne [IntPtr]::Zero) { [void]$p.CloseMainWindow() } } catch { }
        }
    }
    for ($i = 0; $i -lt 10; $i++) {
        $left = 0
        foreach ($name in $selected) { $left += @(Get-Process -Name $name -ErrorAction SilentlyContinue).Count }
        if ($left -eq 0) { break }
        Start-Sleep -Milliseconds 300
        Update-UiNow
    }
    foreach ($name in $selected) {
        $def  = $KnownApps | Where-Object { $_.Proc -eq $name } | Select-Object -First 1
        $rest = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
        if ($rest.Count -gt 0 -and $def -and $def.Kill) {
            foreach ($p in $rest) { try { $p.Kill() } catch { } }
            Start-Sleep -Milliseconds 200
            $rest = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
        }
        $label = $name
        if ($def) { $label = $def.Name }
        if ($rest.Count -eq 0) { Write-Log "$label geschlossen" 'ok' }
        else { Write-Log "$label läuft noch (evtl. offenes Fenster mit ungespeicherten Daten)" 'warn' }
    }
    Update-AppList
}

# ---------------------------------------------------------------------------
#  Einstellungen merken und Profile
# ---------------------------------------------------------------------------
$SettingsFile = Join-Path $DataDir 'settings.json'
$ToggleNames = @('ChkRestore','ChkPower','ChkGameMode','ChkGameBar','ChkScheduler','ChkNetwork','ChkMouse','ChkNotify',
                 'ChkBgApps','ChkPowerThrottle','ChkStickyKeys','ChkTransparency','ChkHags','ChkFso','ChkGpuPref',
                 'ChkPriority','ChkIntros','ChkGraphics','ChkVsync','ChkPostFx','ChkTemp','ChkRam','ChkShader','ChkDns',
                 'ChkAutoBoost','ChkCloseApps')
$ComboNames  = @('CmbPreset','CmbFps','CmbRes')
$script:Settings = @{ Apps = New-Object System.Collections.ArrayList }

function Import-Settings {
    if (-not (Test-Path -LiteralPath $SettingsFile)) { return }
    try {
        $j = Get-Content -LiteralPath $SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($n in $ToggleNames) {
            $v = $null
            if ($j.Toggles) { $v = $j.Toggles.$n }
            if ($null -ne $v) { $ui[$n].IsChecked = [bool]$v }
        }
        foreach ($n in $ComboNames) {
            $v = $null
            if ($j.Combos) { $v = $j.Combos.$n }
            if ($null -ne $v -and [int]$v -ge 0 -and [int]$v -lt $ui[$n].Items.Count) { $ui[$n].SelectedIndex = [int]$v }
        }
        foreach ($a in @($j.Apps)) { if ($a) { [void]$script:Settings.Apps.Add([string]$a) } }
    } catch { }
}

function Save-Settings {
    $t = [ordered]@{}
    foreach ($n in $ToggleNames) { $t[$n] = [bool]$ui[$n].IsChecked }
    $c = [ordered]@{}
    foreach ($n in $ComboNames) { $c[$n] = [int]$ui[$n].SelectedIndex }
    $obj  = [ordered]@{ Toggles = $t; Combos = $c; Apps = @($script:Settings.Apps) }
    $json = ConvertTo-Json -InputObject $obj -Depth 4
    [System.IO.File]::WriteAllText($SettingsFile, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Set-Profile([string]$Name) {
    $safe = @('ChkRestore','ChkPower','ChkGameMode','ChkGameBar','ChkScheduler','ChkStickyKeys','ChkFso','ChkGpuPref',
              'ChkPriority','ChkTemp','ChkRam','ChkDns')
    $rec  = $safe + @('ChkNetwork','ChkMouse','ChkNotify','ChkBgApps','ChkPowerThrottle','ChkTransparency','ChkIntros',
                      'ChkGraphics','ChkVsync','ChkPostFx')
    $max  = $rec + @('ChkHags')
    switch ($Name) {
        'safe' { $on = $safe; $combos = @(0, 0, 0); $label = 'Sicher' }
        'max'  { $on = $max;  $combos = @(1, 1, 3); $label = 'Maximum' }
        default { $on = $rec; $combos = @(2, 1, 0); $label = 'Empfohlen' }
    }
    foreach ($n in $ToggleNames) {
        if ($n -in @('ChkAutoBoost', 'ChkCloseApps')) { continue }
        $ui[$n].IsChecked = ($on -contains $n)
    }
    for ($i = 0; $i -lt $ComboNames.Count; $i++) { $ui[$ComboNames[$i]].SelectedIndex = $combos[$i] }
    Write-Log ("Profil '" + $label + "' eingestellt – jetzt 1-KLICK BOOST drücken") 'ok'
}

# ---------------------------------------------------------------------------
#  Live-Monitor (läuft im Hintergrund, damit die Oberfläche nie ruckelt)
# ---------------------------------------------------------------------------
$bc = New-Object System.Windows.Media.BrushConverter
$script:BrNormal = $bc.ConvertFromString('#E8EAF0')
$script:BrGood   = $bc.ConvertFromString('#4ADE80')
$script:BrWarn   = $bc.ConvertFromString('#FBBF24')
$script:BrCrit   = $bc.ConvertFromString('#F87171')
$script:BrMuted  = $bc.ConvertFromString('#8C94A6')
$script:IsBusy = $false
$script:InTick = $false
$script:PrevRunning = @()

$smiPath = @(
    (Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'),
    (Join-Path $env:ProgramFiles 'NVIDIA Corporation\NVSMI\nvidia-smi.exe')
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

$script:Mon = [hashtable]::Synchronized(@{
    Run = $true; Smi = $smiPath; Cpu = $null; RamPct = $null; RamUsed = $null; RamTotal = $null
    Gpu = $null; GpuTemp = $null; VramUsed = $null; VramTotal = $null; Ase = $false; Asa = $false
})

$monScript = {
    param($Mon)
    while ($Mon.Run) {
        try {
            $c = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop
            $Mon.Cpu = [int]$c.PercentProcessorTime
        } catch { }
        try {
            $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
            $tot  = [double]$os.TotalVisibleMemorySize
            $free = [double]$os.FreePhysicalMemory
            if ($tot -gt 0) {
                $Mon.RamTotal = $tot / 1MB
                $Mon.RamUsed  = ($tot - $free) / 1MB
                $Mon.RamPct   = [int](100 * ($tot - $free) / $tot)
            }
        } catch { }
        if ($Mon.Smi) {
            try {
                $line = & $Mon.Smi '--query-gpu=utilization.gpu,temperature.gpu,memory.used,memory.total' '--format=csv,noheader,nounits' 2>$null | Select-Object -First 1
                $v = @(([string]$line) -split ',' | ForEach-Object { $_.Trim() })
                if ($v.Count -ge 4) {
                    $Mon.Gpu = [int]$v[0]; $Mon.GpuTemp = [int]$v[1]; $Mon.VramUsed = [double]$v[2]; $Mon.VramTotal = [double]$v[3]
                }
            } catch { }
        }
        $Mon.Ase = (@(Get-Process -Name 'ShooterGame' -ErrorAction SilentlyContinue).Count -gt 0)
        $Mon.Asa = (@(Get-Process -Name 'ArkAscended' -ErrorAction SilentlyContinue).Count -gt 0)
        Start-Sleep -Milliseconds 1500
    }
}

function Start-Monitor {
    try {
        $script:MonPs = [powershell]::Create()
        [void]$script:MonPs.AddScript($monScript.ToString()).AddArgument($script:Mon)
        [void]$script:MonPs.BeginInvoke()
    } catch {
        Write-Log 'Live-Monitor konnte nicht gestartet werden' 'warn'
    }
    $script:Timer = New-Object System.Windows.Threading.DispatcherTimer
    $script:Timer.Interval = [TimeSpan]::FromMilliseconds(1500)
    $script:Timer.Add_Tick({
        # Schutz vor Verschachtelung: Write-Log lässt die Oberfläche kurz weiterlaufen,
        # dabei darf kein zweiter Tick in den ersten hineinlaufen.
        if ($script:InTick) { return }
        $script:InTick = $true
        try { Update-Monitor } catch { try { Write-Log "Monitor-Fehler: $($_.Exception.Message)" 'warn' } catch { } }
        finally { $script:InTick = $false }
    })
    $script:Timer.Start()
}

function Stop-Monitor {
    try { if ($script:Timer) { $script:Timer.Stop() } } catch { }
    $script:Mon.Run = $false
    try { if ($script:MonPs) { [void]$script:MonPs.BeginStop($null, $null) } } catch { }
}

function Set-TileValue($Tb, [string]$Text, $Value, [double]$Warn, [double]$Crit) {
    $Tb.Text = $Text
    if ($null -eq $Value)       { $Tb.Foreground = $script:BrMuted }
    elseif ($Value -ge $Crit)   { $Tb.Foreground = $script:BrCrit }
    elseif ($Value -ge $Warn)   { $Tb.Foreground = $script:BrWarn }
    else                        { $Tb.Foreground = $script:BrNormal }
}

function Update-Monitor {
    $m = $script:Mon
    if ($null -ne $m.Cpu)    { Set-TileValue $ui.MonCpu ("{0} %" -f $m.Cpu) $m.Cpu 80 95 }
    if ($null -ne $m.RamPct) { Set-TileValue $ui.MonRam ('{0:N1} / {1:N0} GB' -f $m.RamUsed, $m.RamTotal) $m.RamPct 80 92 }
    if (-not $m.Smi) {
        Set-TileValue $ui.MonGpu 'nur NVIDIA' $null 0 0
        Set-TileValue $ui.MonGpuTemp 'nur NVIDIA' $null 0 0
        Set-TileValue $ui.MonVram 'nur NVIDIA' $null 0 0
    } elseif ($null -ne $m.Gpu) {
        Set-TileValue $ui.MonGpu ("{0} %" -f $m.Gpu) $m.Gpu 101 101
        Set-TileValue $ui.MonGpuTemp ("{0} °C" -f $m.GpuTemp) $m.GpuTemp 78 86
        $vPct = 0
        if ($m.VramTotal -gt 0) { $vPct = 100 * $m.VramUsed / $m.VramTotal }
        Set-TileValue $ui.MonVram ('{0:N1} / {1:N0} GB' -f ($m.VramUsed / 1024), ($m.VramTotal / 1024)) $vPct 85 95
    }

    $running = @()
    if ($m.Ase) { $running += 'ASE' }
    if ($m.Asa) { $running += 'ASA' }
    if ($running.Count -gt 0) {
        $ui.MonArk.Text = 'läuft (' + ($running -join ' + ') + ')'
        $ui.MonArk.Foreground = $script:BrGood
    } else {
        $ui.MonArk.Text = 'nicht gestartet'
        $ui.MonArk.Foreground = $script:BrMuted
    }

    if ($script:IsBusy) { return }
    # Erst den neuen Zustand merken, DANN reagieren – sonst wird der Auto-Boost
    # beim nächsten Timer-Tick erneut ausgelöst (Endlosschleife).
    $started = @($running | Where-Object { $script:PrevRunning -notcontains $_ })
    $ended   = @($script:PrevRunning | Where-Object { $running -notcontains $_ })
    $script:PrevRunning = $running
    foreach ($r in $ended)   { Write-Log "$r wurde beendet" 'info' }
    foreach ($r in $started) { Invoke-AutoBoost $r }
}

function Invoke-AutoBoost([string]$Short) {
    if (-not $ui.ChkAutoBoost.IsChecked) { Write-Log "$Short läuft" 'info'; return }
    $procName = 'ShooterGame'
    if ($Short -eq 'ASA') { $procName = 'ArkAscended' }
    Set-Busy $true
    try {
        Write-Log "$Short gestartet – Auto-Boost" 'head'
        foreach ($p in @(Get-Process -Name $procName -ErrorAction SilentlyContinue)) {
            try { $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::High } catch { }
        }
        Write-Log "$Short läuft mit hoher CPU-Priorität" 'ok'
        try { Clear-Ram } catch { }
    } finally {
        Set-Busy $false
    }
}

# ---------------------------------------------------------------------------
#  Spiele-Anzeige
# ---------------------------------------------------------------------------
function Update-Games {
    $script:Games = @(Find-Games)
    if ($script:Games.Count -eq 0) {
        $ui.TxtGames.Text = 'Kein ARK gefunden – Windows-Optimierungen funktionieren trotzdem. ARK woanders installiert? → „Spielordner wählen“'
    } else {
        $ui.TxtGames.Text = 'Gefunden: ' + ((@($script:Games) | ForEach-Object { "$($_.Name)  ($($_.Root))" }) -join '   |   ')
    }
    $ase = @($script:Games | Where-Object { $_.Short -eq 'ASE' })
    $asa = @($script:Games | Where-Object { $_.Short -eq 'ASA' })
    if ($ase.Count -gt 0) { $ui.BtnStartASE.Visibility = 'Visible' } else { $ui.BtnStartASE.Visibility = 'Collapsed' }
    if ($asa.Count -gt 0) { $ui.BtnStartASA.Visibility = 'Visible' } else { $ui.BtnStartASA.Visibility = 'Collapsed' }
}

function Start-Game([string]$Short) {
    $g = @($script:Games | Where-Object { $_.Short -eq $Short }) | Select-Object -First 1
    if (-not $g) { return }
    try {
        if ($ui.ChkRam.IsChecked) { Clear-Ram }
        if ($g.IsSteam) { Start-Process ("steam://rungameid/{0}" -f $g.AppId) }
        else { Start-Process -FilePath $g.Exe -WorkingDirectory (Split-Path $g.Exe -Parent) }
        Write-Log "$($g.Name) wird gestartet ..." 'ok'
    } catch {
        Write-Log "Start fehlgeschlagen: $($_.Exception.Message)" 'err'
    }
}

# ---------------------------------------------------------------------------
#  Ereignisse
# ---------------------------------------------------------------------------
$ui.BtnBoost.Add_Click({ Invoke-Boost })
$ui.BtnUndo.Add_Click({ Invoke-Undo })
$ui.BtnStartASE.Add_Click({ Start-Game 'ASE' })
$ui.BtnStartASA.Add_Click({ Start-Game 'ASA' })

$ui.BtnCopyAse.Add_Click({
    try { [System.Windows.Clipboard]::SetText($ui.TxtLaunchAse.Text); Write-Log 'ASE-Startoptionen kopiert' 'ok' } catch { Write-Log 'Kopieren fehlgeschlagen' 'err' }
})
$ui.BtnCopyAsa.Add_Click({
    try { [System.Windows.Clipboard]::SetText($ui.TxtLaunchAsa.Text); Write-Log 'ASA-Startoptionen kopiert' 'ok' } catch { Write-Log 'Kopieren fehlgeschlagen' 'err' }
})

$ui.BtnFolder.Add_Click({
    try {
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'ARK-Installationsordner wählen (der Ordner, in dem „ShooterGame“ liegt)'
        $dlg.ShowNewFolderButton = $false
        if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
        $path = $dlg.SelectedPath.TrimEnd('\')
        $match = @($GameDefs | Where-Object { Test-Path -LiteralPath (Join-Path $path $_.ExeRel) })
        if ($match.Count -eq 0) {
            [void][System.Windows.MessageBox]::Show("In diesem Ordner wurde kein ARK gefunden.`n`nWähle den Ordner, der den Unterordner 'ShooterGame' enthält.", $AppName, 'OK', 'Warning')
            return
        }
        if (-not ($script:State.ManualPaths -contains $path)) { [void]$script:State.ManualPaths.Add($path) }
        Save-State
        Update-Games
        Write-Log "Spielordner hinzugefügt: $path" 'ok'
    } catch {
        Write-Log "Ordnerauswahl fehlgeschlagen: $($_.Exception.Message)" 'err'
    }
})

$ui.BtnProfSafe.Add_Click({ try { Set-Profile 'safe' } catch { Write-Log "Profil-Fehler: $($_.Exception.Message)" 'err' } })
$ui.BtnProfRec.Add_Click({  try { Set-Profile 'rec'  } catch { Write-Log "Profil-Fehler: $($_.Exception.Message)" 'err' } })
$ui.BtnProfMax.Add_Click({  try { Set-Profile 'max'  } catch { Write-Log "Profil-Fehler: $($_.Exception.Message)" 'err' } })

$ui.BtnScanApps.Add_Click({ try { Update-AppList; Write-Log 'Hintergrundprogramme aktualisiert' 'ok' } catch { Write-Log "Fehler: $($_.Exception.Message)" 'err' } })
$ui.BtnCloseApps.Add_Click({
    Set-Busy $true
    try { Close-SelectedApps } catch { Write-Log "Fehler: $($_.Exception.Message)" 'err' } finally { Set-Busy $false }
})
$ui.BtnPing.Add_Click({
    Set-Busy $true
    try { Test-Ping } catch { Write-Log "Ping-Test fehlgeschlagen: $($_.Exception.Message)" 'err' } finally { Set-Busy $false }
})
$ui.BtnOpenData.Add_Click({ try { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $DataDir) } catch { } })
$ui.BtnOpenConfig.Add_Click({
    $g = @($script:Games | Where-Object { Test-Path -LiteralPath $_.ConfigDir }) | Select-Object -First 1
    if ($g) { try { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $g.ConfigDir) } catch { } }
    else { Write-Log 'Kein ARK-Config-Ordner gefunden – ARK einmal starten.' 'warn' }
})

$Window.Add_Loaded({
    try {
        Write-Log "$AppName $AppVersion bereit (Adminrechte aktiv)" 'head'
        Import-Settings
        Update-Games
        foreach ($g in $script:Games) { Write-Log "$($g.Name) gefunden" 'ok' }
        if ($script:Games.Count -eq 0) { Write-Log 'Kein ARK automatisch gefunden.' 'warn' }
        Update-Status
        Update-AppList
        $ui.TxtSysInfo.Text = Get-SysInfoText
        if (-not $smiPath) { Write-Log 'nvidia-smi nicht gefunden – GPU-Werte im Monitor nur mit NVIDIA-Treiber.' 'info' }
        Start-Monitor
    } catch {
        Write-Log "Fehler beim Start: $($_.Exception.Message)" 'err'
    }
})

$Window.Add_Closing({
    try { Save-Settings } catch { }
    Stop-Monitor
})

# Letzte Absicherung: Kein Fehler darf die App einfach schließen
$Window.Dispatcher.Add_UnhandledException({
    param($src, $evt)
    try {
        Add-Content -LiteralPath $LogFile -Value ('{0} ABSTURZ ABGEFANGEN: {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $evt.Exception.ToString()) -Encoding UTF8
        Write-Log "Fehler abgefangen: $($evt.Exception.Message)" 'err'
    } catch { }
    $evt.Handled = $true
})

try {
    [void]$Window.ShowDialog()
} catch {
    try { Add-Content -LiteralPath $LogFile -Value ('{0} ABSTURZ: {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $_.Exception.ToString()) -Encoding UTF8 } catch { }
    [void][System.Windows.MessageBox]::Show("Der ARK FPS Booster ist auf einen Fehler gestoßen:`n`n$($_.Exception.Message)`n`nDetails stehen in %APPDATA%\ArkFpsBooster\log.txt", $AppName, 'OK', 'Error')
} finally {
    Stop-Monitor
}
