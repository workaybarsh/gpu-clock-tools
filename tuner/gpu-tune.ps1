<#
.SYNOPSIS
    gpu-tune - NVIDIA GPU clock tuner for Windows.

.DESCRIPTION
    Identifies the card, measures its current state, and finds a "safe sustained
    clock" automatically from a TEMPERATURE TARGET. It applies the value as a
    locked clock and releases it when the workload ends.

    AUTO ALGORITHM:
      1. Checks whether the card supports clock locking (Volta or newer)
      2. Idles at stock clocks, waits for temperatures to settle
      3. If above target: steps down 100 MHz at a time
      4. Once below target: steps back up 50 MHz to find the highest safe point
      5. Locks the found value and keeps it while it runs
      6. If temperature drifts upward, reduces further automatically
      7. Hands over to the watchdog (default) which keeps the lock while the
         GPU is in use and releases it when the work stops

    IMPORTANT - RUN THIS WHILE YOUR WORKLOAD IS RUNNING:
      Temperature-based tuning is only meaningful while the card is actually
      working. With the miner/render/AI job stopped the card sits idle
      (e.g. 44 C), and the program will correctly report that no lock is needed
      and exit. That is by design, not a bug.
      Start your workload first, then run this.

    WHERE THE LOCK LIVES:
      In driver memory. It disappears on shutdown / reboot / driver reload.
      What happens when this tool exits is controlled by -After (see below).

.PARAMETER Mode
    Detect  : card info and support status only (no writes)
    Status  : current state plus the saved profile
    Auto    : find the highest safe clock for the temperature target, then lock it
    Fixed   : lock the MHz value given with -Clock
    Percent : lock the percentage given with -Percent
    Clear   : release the lock (-rgc) and return to driver defaults

.PARAMETER After
    What to do once the target clock is known (default: Watch)

      Watch   : hand over to watchdog/gpu-clock-watchdog.ps1. The watchdog holds
                the lock while the GPU is in use and releases it (-rgc) when the
                work stops. This is the "run it during mining" mode.
      Keep    : apply the lock and exit, leaving it in place until -Mode Clear,
                a reboot or a driver reload.
      Release : apply the lock briefly, then release it and exit.

.PARAMETER Clock
    Target MHz for Fixed mode (for example 1900).

.PARAMETER Percent
    Percentage of the maximum clock for Percent mode (for example 76).

.PARAMETER TargetTemp
    Temperature target for Auto mode (default 65 C).

.PARAMETER MaxTemp
    Emergency ceiling (default 80 C). Above this, the clock is reduced further.

.PARAMETER MaxFan
    Emergency fan ceiling in percent (default 85).

.PARAMETER ProcessName
    Processes to watch. Empty means "run until Ctrl+C".

.EXAMPLE
    .\gpu-tune.ps1 -Mode Detect

.EXAMPLE
    .\gpu-tune.ps1 -Mode Auto -TargetTemp 65 -ProcessName YOUR_MINER

.EXAMPLE
    .\gpu-tune.ps1 -Mode Fixed -Clock 1900

.NOTES
    Requires administrator rights (for nvidia-smi -lgc).
    Clock locking is not supported on pre-Volta cards (GTX 10 series and older).
#>

param(
    [ValidateSet('Detect', 'Status', 'Auto', 'Fixed', 'Percent', 'Clear')]
    [string]$Mode = 'Detect',

    [int]$GpuIndex = 0,
    [int]$Clock = 0,
    [int]$Percent = 0,

    [int]$TargetTemp = 65,
    [int]$MaxTemp = 80,
    [int]$MaxFan = 85,

    [int]$StepCoarse = 100,
    [int]$StepFine = 50,
    [int]$SettleSeconds = 90,
    [int]$StepSeconds = 120,
    [int]$MaxSteps = 30,

    [string[]]$ProcessName = @(),

    [string]$ProfilePath = '',
    [string]$LogFile = '',

    [switch]$ListAll,
    [switch]$Force,
    [switch]$DryRun,

    [ValidateSet('Watch', 'Keep', 'Release')]
    [string]$After = 'Watch'
)

$ErrorActionPreference = 'Stop'
$script:Gpu = $GpuIndex

if (-not $ProfilePath) {
    $ProfilePath = Join-Path $env:LOCALAPPDATA 'gpu-clock-tools\gpu-profile.json'
}

# ------------------------------------------------------------------ helpers

function Write-Log {
    param([string]$Message)
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $Message"
    Write-Host $line
    if ($LogFile) {
        $dir = Split-Path $LogFile -Parent
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $line | Out-File -FilePath $LogFile -Append -Encoding utf8
    }
}

function Invoke-Smi {
    param([string[]]$SmiArgs)
    $out = & nvidia-smi @SmiArgs 2>&1
    return [pscustomobject]@{
        Code = $LASTEXITCODE
        Text = (($out | Out-String).Trim())
    }
}

function To-Num {
    param($Value)
    if ($null -eq $Value) { return $null }
    $s = ("$Value").Trim()
    if ($s -match '^-?[0-9]+(\.[0-9]+)?$') { return [double]$s }
    return $null
}

function Get-GpuInfo {
    $fields = 'name,driver_version,pci.bus_id,pci.device_id,clocks.max.gr,clocks.gr,power.draw,power.limit,power.default_limit,temperature.gpu,fan.speed,utilization.gpu,memory.total'
    $r = Invoke-Smi @('-i', "$script:Gpu", "--query-gpu=$fields", '--format=csv,noheader,nounits')
    if ($r.Code -ne 0) { throw "Could not read nvidia-smi: $($r.Text)" }

    $p = $r.Text -split ','
    if ($p.Count -lt 13) { throw "Unexpected nvidia-smi output: $($r.Text)" }

    return [pscustomobject]@{
        Name         = $p[0].Trim()
        Driver       = $p[1].Trim()
        PciBus       = $p[2].Trim()
        DeviceId     = $p[3].Trim()
        MaxClock     = (To-Num $p[4])
        CoreClock    = (To-Num $p[5])
        Power        = (To-Num $p[6])
        PowerLimit   = (To-Num $p[7])
        PowerDefault = (To-Num $p[8])
        Temp         = (To-Num $p[9])
        Fan          = (To-Num $p[10])
        Util         = (To-Num $p[11])
        MemTotal     = $p[12].Trim()
    }
}

function Get-Architecture {
    $r = Invoke-Smi @('-i', "$script:Gpu", '-q')
    if ($r.Code -ne 0) { return '' }
    $m = [regex]::Match($r.Text, 'Product Architecture\s*:\s*(.+)')
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return ''
}

function Test-ClockLockLikely {
    # Read-only guess based on the architecture name; no writes.
    param([string]$Arch)
    if (-not $Arch) { return 'unknown' }
    $a = $Arch.ToLower()
    if ($a -match 'volta|turing|ampere|ada|blackwell|hopper|grace') { return 'yes' }
    if ($a -match 'pascal|maxwell|kepler') { return 'no' }
    return 'unknown'
}

function Get-ProfileKey {
    param($Info)
    $raw = "$($Info.DeviceId)|$($Info.Name)"
    return ($raw -replace '[^A-Za-z0-9]+', '_')
}

function Load-Profiles {
    if (-not (Test-Path $ProfilePath)) { return @{} }
    try {
        $obj = Get-Content $ProfilePath -Raw -Encoding utf8 | ConvertFrom-Json
        $h = @{}
        if ($obj -and ($obj.PSObject.Properties.Name -contains 'profiles')) {
            foreach ($p in $obj.profiles.PSObject.Properties) { $h[$p.Name] = $p.Value }
        }
        return $h
    }
    catch { return @{} }
}

function Save-Profile {
    param($Info, [int]$SafeClock, [int]$TargetTemperature)
    try {
        $dir = Split-Path $ProfilePath -Parent
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $key = Get-ProfileKey $Info
        $h = Load-Profiles
        $h[$key] = [pscustomobject]@{
            name       = $Info.Name
            deviceId   = $Info.DeviceId
            maxClock   = $Info.MaxClock
            safeClock  = $SafeClock
            targetTemp = $TargetTemperature
            driver     = $Info.Driver
            foundAt    = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        }
        ([pscustomobject]@{ profiles = $h }) | ConvertTo-Json -Depth 6 | Out-File -FilePath $ProfilePath -Encoding utf8
        Write-Log "Profile saved: $key -> $SafeClock MHz"
    }
    catch {
        Write-Log "WARNING: could not save profile: $($_.Exception.Message)"
    }
}

function Set-ClockLock {
    param([int]$Mhz)
    if ($DryRun) { Write-Log "[DryRun] would run: -lgc $Mhz"; return $true }
    $r = Invoke-Smi @('-i', "$script:Gpu", '-eow', '-lgc', "$Mhz")
    if ($r.Code -eq 0) { return $true }
    Write-Log "ERROR -lgc $Mhz : $($r.Text)"
    return $false
}

function Clear-ClockLock {
    if ($DryRun) { Write-Log '[DryRun] would run: -rgc'; return }
    $r = Invoke-Smi @('-i', "$script:Gpu", '-rgc')
    if ($r.Code -ne 0) { Write-Log "WARNING -rgc failed: $($r.Text)" }
}

function Test-UnderLoad {
    param($Info)
    $util = 0
    if ($null -ne $Info.Util) { $util = $Info.Util }
    $pk = 0
    if ($null -ne $Info.Power -and $null -ne $Info.PowerLimit -and $Info.PowerLimit -gt 0) {
        $pk = ($Info.Power / $Info.PowerLimit) * 100
    }
    return [pscustomobject]@{
        IsLoaded = ($util -ge 40 -or $pk -ge 30)
        Util     = $util
        PowerPct = [math]::Round($pk, 0)
    }
}

function Format-Value {
    param($Value, [string]$Unit)
    if ($null -eq $Value) { return 'N/A' }
    return "$Value$Unit"
}

function Show-RiskNotice {
    Write-Host ''
    Write-Host '  NOTICE: You are responsible for your own hardware.' -ForegroundColor Yellow
    Write-Host '  Clock changes are applied at your own risk. The authors accept no' -ForegroundColor Yellow
    Write-Host '  liability for damage, instability, data loss or a voided warranty.' -ForegroundColor Yellow
    Write-Host '  Verify temperatures yourself. Full text: DISCLAIMER.md' -ForegroundColor Yellow
    Write-Host ''
}

function Show-GpuInfo {
    param($Info, [string]$Arch, [string]$Support)
    Write-Host ''
    Write-Host '  CARD'
    Write-Host ('    Name          : ' + $Info.Name)
    if ($Arch) { Write-Host ('    Architecture  : ' + $Arch) }
    Write-Host ('    PCI           : ' + $Info.PciBus + '   (' + $Info.DeviceId + ')')
    Write-Host ('    Driver        : ' + $Info.Driver)
    Write-Host ('    Memory        : ' + $Info.MemTotal + ' MB')
    Write-Host ''
    Write-Host '  STATE'
    Write-Host ('    Max clock     : ' + (Format-Value $Info.MaxClock ' MHz'))
    Write-Host ('    Current clock : ' + (Format-Value $Info.CoreClock ' MHz'))
    Write-Host ('    Power         : ' + (Format-Value $Info.Power ' W') + ' / limit ' + (Format-Value $Info.PowerLimit ' W'))
    Write-Host ('    Temperature   : ' + (Format-Value $Info.Temp ' C'))
    Write-Host ('    Fan           : ' + (Format-Value $Info.Fan ' %'))
    Write-Host ('    Utilization   : ' + (Format-Value $Info.Util ' %'))
    Write-Host ''
    Write-Host ('  CLOCK LOCK    : ' + $Support)
    if ($Support -eq 'no') {
        Write-Host '    -> Pre-Volta architecture. nvidia-smi -lgc does not work on this card.' -ForegroundColor Yellow
    }
    elseif ($Support -eq 'unknown') {
        Write-Host '    -> Architecture could not be read; try -Mode Fixed with a small value.' -ForegroundColor Yellow
    }
    Write-Host ''
}

# ------------------------------------------------------------------ list mode

if ($ListAll) {
    $r = Invoke-Smi @('-L')
    Write-Host $r.Text
    Write-Host ''
    $q = Invoke-Smi @('--query-gpu=index,name,pci.bus_id,clocks.max.gr,clocks.gr,temperature.gpu', '--format=csv,noheader')
    Write-Host $q.Text
    exit 0
}

# ------------------------------------------------------------------ modes

$info = $null
try { $info = Get-GpuInfo }
catch { Write-Log "ERROR: $($_.Exception.Message)"; exit 1 }

$arch = Get-Architecture
$support = Test-ClockLockLikely $arch

switch ($Mode) {

    'Clear' {
        Clear-ClockLock
        Write-Log 'Clock lock cleared (-rgc). The card is back on the driver default behaviour.'
        exit 0
    }

    'Detect' {
        Show-GpuInfo $info $arch $support
        $profiles = Load-Profiles
        $key = Get-ProfileKey $info
        if ($profiles.ContainsKey($key)) {
            $p = $profiles[$key]
            Write-Host '  SAVED PROFILE'
            Write-Host ('    Safe clock    : ' + $p.safeClock + ' MHz  (target ' + $p.targetTemp + ' C)')
            Write-Host ('    Found at      : ' + $p.foundAt)
            Write-Host ''
        }
        exit 0
    }

    'Status' {
        Show-GpuInfo $info $arch $support
        $profiles = Load-Profiles
        $key = Get-ProfileKey $info
        if ($profiles.ContainsKey($key)) {
            $p = $profiles[$key]
            Write-Host ('  Saved profile : ' + $p.safeClock + ' MHz (target ' + $p.targetTemp + ' C, ' + $p.foundAt + ')')
        }
        else {
            Write-Host '  Saved profile : none'
        }
        $load = Test-UnderLoad $info
        $loadText = 'IDLE'
        if ($load.IsLoaded) { $loadText = 'UNDER LOAD' }
        Write-Host ('  Load state    : utilization ' + $load.Util + '%, power ' + $load.PowerPct + '% -> ' + $loadText)
        Write-Host ''
        exit 0
    }

    'Fixed' {
        if ($Clock -le 0) { Write-Log 'ERROR: Fixed mode requires -Clock <MHz>.'; exit 1 }
        $target = $Clock
    }

    'Percent' {
        if ($Percent -le 0 -or $Percent -gt 100) { Write-Log 'ERROR: -Percent must be between 1 and 100.'; exit 1 }
        if ($null -eq $info.MaxClock -or $info.MaxClock -le 0) { Write-Log 'ERROR: could not read maximum clock.'; exit 1 }
        $target = [int][math]::Round($info.MaxClock * $Percent / 100.0)
    }

    'Auto' {
        $target = 0
    }
}

# ------------------------------------------------------------------ hand-off

function Invoke-After {
    param([int]$ClockTarget, [string]$Label)

    Write-Log "Target clock: $ClockTarget MHz ($Label)"

    switch ($After) {

        'Watch' {
            $watchdog = Join-Path (Split-Path $PSScriptRoot -Parent) 'watchdog\gpu-clock-watchdog.ps1'
            if (-not (Test-Path $watchdog)) {
                Write-Log "WARNING: watchdog not found at $watchdog - applying and keeping the lock instead."
                if (Set-ClockLock $ClockTarget) { Write-Log "Lock applied: $ClockTarget MHz" }
                return
            }
            Write-Log 'Handing over to the watchdog: holds the lock while GPU work runs, releases it when work stops.'
            if ($ProcessName.Count -gt 0) {
                & $watchdog -GpuIndex $GpuIndex -TargetClock $ClockTarget -ProcessName $ProcessName
            }
            else {
                & $watchdog -GpuIndex $GpuIndex -TargetClock $ClockTarget
            }
        }

        'Keep' {
            if (Set-ClockLock $ClockTarget) {
                Write-Log "Lock applied and left in place: $ClockTarget MHz"
                Write-Log 'It stays until you clear it (-Mode Clear), reboot, or driver reload.'
            }
        }

        'Release' {
            if (Set-ClockLock $ClockTarget) {
                Write-Log "Lock applied: $ClockTarget MHz"
                Start-Sleep -Seconds 2
                Clear-ClockLock
                Write-Log 'Lock released (-rgc).'
            }
        }
    }
}

# ------------------------------------------------------------------ auto mode

if ($Mode -eq 'Auto') {

    Show-RiskNotice
    Write-Log "Auto mode - target $TargetTemp C (ceiling $MaxTemp C / fan $MaxFan%)"
    Write-Log "card: $($info.Name) | max $($info.MaxClock) MHz | now $($info.CoreClock) MHz | $($info.Temp) C"

    if ($support -eq 'no') {
        Write-Log 'ERROR: clock locking is not supported on this architecture (pre-Volta).'
        exit 2
    }

    $load = Test-UnderLoad $info
    if (-not $load.IsLoaded -and -not $Force) {
        Write-Log "WARNING: the card does not look busy (utilization $($load.Util)%, power $($load.PowerPct)%)."
        Write-Log 'Temperature-based tuning is meaningless without load.'
        Write-Log 'Start your miner / render / AI job, then run this again.'
        Write-Log 'Add -Force to try anyway.'
        exit 3
    }

    Write-Log "Settling at stock clocks for $SettleSeconds seconds..."
    Start-Sleep -Seconds $SettleSeconds
    $probe = Get-GpuInfo

    if ($null -ne $probe.Temp -and $probe.Temp -le $TargetTemp) {
        Write-Log "Stock already below target ($($probe.Temp) C <= $TargetTemp C) -> no lock needed."
        Write-Log 'The card manages itself under this load. Use a lower -TargetTemp if you want a cooler card.'
        exit 0
    }

    $cap = [int]$info.MaxClock
    if ($null -ne $info.CoreClock -and $info.CoreClock -gt 0 -and $info.CoreClock -lt $cap) {
        $cap = [int]$info.CoreClock
        Write-Log "Search starts at the current clock ($cap MHz) rather than the maximum."
    }
    $found = $false
    $steps = 0

    while ($cap -gt 600 -and $steps -lt $MaxSteps) {
        $steps++
        $cap = $cap - $StepCoarse
        if (-not (Set-ClockLock $cap)) { throw 'Could not apply clock lock (permission or support problem).' }
        Write-Log "Trying $cap MHz, waiting $StepSeconds s..."
        Start-Sleep -Seconds $StepSeconds
        $i = Get-GpuInfo
        Write-Log ("  result: {0} C, fan {1}%, {2} W, {3} MHz" -f $i.Temp, $i.Fan, $i.Power, $i.CoreClock)
        if ($null -ne $i.Temp -and $i.Temp -le $TargetTemp) { $found = $true; break }
    }

    if (-not $found) {
        Write-Log 'ERROR: reached 600 MHz without meeting the target. Releasing the lock.'
        Clear-ClockLock
        exit 4
    }

    # fine tuning: step back up 50 MHz while we stay 2 C below target
    while ($true) {
        $try = $cap + $StepFine
        if ($try -ge $info.MaxClock) { break }
        if (-not (Set-ClockLock $try)) { break }
        Start-Sleep -Seconds $StepSeconds
        $i = Get-GpuInfo
        if ($null -ne $i.Temp -and $i.Temp -le ($TargetTemp - 2)) {
            Write-Log ("  step up accepted: {0} MHz / {1} C" -f $try, $i.Temp)
            $cap = $try
        }
        else {
            Write-Log ("  step up rejected: {0} MHz / {1} C -> back to {2} MHz" -f $try, $i.Temp, $cap)
            Set-ClockLock $cap | Out-Null
            break
        }
    }

    Write-Log "SAFE CLOCK FOUND: $cap MHz (target $TargetTemp C)"
    Save-Profile $info $cap $TargetTemp

    Invoke-After -ClockTarget $cap -Label 'auto'
    exit 0
}

# ------------------------------------------------------------------ fixed / percent

Show-RiskNotice
Invoke-After -ClockTarget $target -Label $Mode.ToLower()
exit 0
