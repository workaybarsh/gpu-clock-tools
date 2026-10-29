<#
.SYNOPSIS
    gpu-clock-watchdog - keeps a GPU clock cap while a workload is running.

.DESCRIPTION
    Watches for GPU work, holds a clock ceiling while it runs, and releases the
    ceiling when the work stops.

    WORKLOAD DETECTION (three ways, best one is automatic):

      1. Auto (default)
         Samples the Windows "GPU Engine" performance counters and finds the
         process that is actually using the GPU. Works for any workload -
         miner, renderer, AI inference - without knowing its name.

      2. -ProcessName
         Watch one or more named processes instead. Use this when you want to
         be explicit (for example a launcher that starts the real worker).

      3. Any GPU load
         With -LoadOnly, the lock is held whenever total GPU utilization is
         above -LoadThreshold, regardless of which process causes it.

    WHERE THE CLOCK VALUE COMES FROM (first match wins):

      1. -TargetClock <MHz>
      2. -Percent <n>  (percentage of the card's maximum clock)
      3. gpu-profile.json produced by gpu-tune -Mode Auto

    SAFETY:
      If the temperature or the fan reaches its ceiling, the cap is lowered
      further automatically. The cap is never raised above the card maximum.

    LOCK LIFE CYCLE:
      Released with -rgc when the workload ends, when you press Ctrl+C, or when
      -MissLimit consecutive polls find no work. Pass -KeepLock to leave the
      cap in place after exit instead.

.PARAMETER GpuIndex
    Which card. 0 = first, 1 = second.

.PARAMETER TargetClock
    Clock ceiling in MHz.

.PARAMETER Percent
    Percentage of the maximum clock (for example 76).

.PARAMETER ProcessName
    Process names to watch, without .exe. Overrides auto detection.

.PARAMETER LoadOnly
    Hold the lock whenever the GPU is busy, without tracking a process.

.PARAMETER LoadThreshold
    GPU utilization percentage that counts as "busy" (default 20).

.PARAMETER UseProfile
    Read gpu-profile.json written by gpu-tune. This is the default when neither
    -TargetClock nor -Percent is given.

.PARAMETER ProfilePath
    Where to look for the profile. Defaults to
    %LOCALAPPDATA%\gpu-clock-tools\gpu-profile.json

.PARAMETER PollSeconds
    How often the workload is checked (default 10).

.PARAMETER MissLimit
    Consecutive polls without work before the lock is released and the tool
    exits (default 3).

.PARAMETER RefreshSeconds
    How often the lock is re-applied while work continues (default 60).
    Covers driver resets, sleep and resume.

.PARAMETER MaxTemp
    Emergency temperature ceiling in Celsius (default 80).

.PARAMETER MaxFan
    Emergency fan ceiling in percent (default 85).

.EXAMPLE
    .\gpu-clock-watchdog.ps1

    Uses gpu-profile.json if present, otherwise asks for a target.

.EXAMPLE
    .\gpu-clock-watchdog.ps1 -TargetClock 1900

.EXAMPLE
    .\gpu-clock-watchdog.ps1 -Percent 76 -ProcessName YOUR_MINER

.EXAMPLE
    .\gpu-clock-watchdog.ps1 -LoadOnly -LoadThreshold 30

.NOTES
    Requires administrator rights (nvidia-smi -lgc).
    Clock locking needs Volta or newer. Pre-Volta cards (GTX 10 series and older)
    return "not supported"; this tool reports that and stops.
    Use at your own risk - see DISCLAIMER.md.
#>

param(
    [int]$GpuIndex = 0,

    [int]$TargetClock = 0,
    [int]$Percent = 0,

    [string[]]$ProcessName = @(),
    [switch]$LoadOnly,
    [int]$LoadThreshold = 20,

    [switch]$UseProfile,
    [string]$ProfilePath = '',

    [int]$PollSeconds = 10,
    [int]$MissLimit = 3,
    [int]$RefreshSeconds = 60,

    [int]$MaxTemp = 80,
    [int]$MaxFan = 85,
    [int]$SafetyStep = 50,

    [string]$LogFile = '',

    [switch]$KeepLock,
    [switch]$DryRun,
    [switch]$Info
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

function Get-GpuState {
    $fields = 'name,clocks.max.gr,clocks.gr,power.draw,power.limit,temperature.gpu,fan.speed,utilization.gpu'
    $r = Invoke-Smi @('-i', "$script:Gpu", "--query-gpu=$fields", '--format=csv,noheader,nounits')
    if ($r.Code -ne 0) { throw "Could not read nvidia-smi: $($r.Text)" }
    $p = $r.Text -split ','
    if ($p.Count -lt 8) { throw "Unexpected nvidia-smi output: $($r.Text)" }
    return [pscustomobject]@{
        Name       = $p[0].Trim()
        MaxClock   = (To-Num $p[1])
        CoreClock  = (To-Num $p[2])
        Power      = (To-Num $p[3])
        PowerLimit = (To-Num $p[4])
        Temp       = (To-Num $p[5])
        Fan        = (To-Num $p[6])
        Util       = (To-Num $p[7])
    }
}

# ------------------------------------------------------------------ GPU engine counters

function Get-GpuEnginePath {
    try {
        $set = Get-Counter -ListSet 'GPU Engine' -ErrorAction Stop
        $hit = $set.Paths | Where-Object { $_ -match 'utilization' } | Select-Object -First 1
        if ($hit) { return $hit }
        if ($set.Paths.Count -gt 0) { return $set.Paths[0] }
    }
    catch { }
    return '\GPU Engine(*)\Utilization Percentage'
}

function Get-GpuUsers {
    # Returns per-PID GPU utilization (percent, averaged over ~3 seconds).
    param([int]$Samples = 3, [int]$IntervalSeconds = 1)

    $result = @{}
    $path = Get-GpuEnginePath
    try {
        $data = Get-Counter -Counter $path -SampleInterval $IntervalSeconds -MaxSamples $Samples -ErrorAction Stop
    }
    catch {
        return $result
    }

    foreach ($sample in $data) {
        foreach ($c in $sample.CounterSamples) {
            if ($c.InstanceName -match '^pid_([0-9]+)_') {
                $procId = [int]$Matches[1]
                if (-not $result.ContainsKey($procId)) { $result[$procId] = 0.0 }
                $result[$procId] = $result[$procId] + $c.CookedValue
            }
        }
    }

    $avg = @{}
    foreach ($k in $result.Keys) { $avg[$k] = $result[$k] / [double]$Samples }
    return $avg
}

function Get-TopGpuUser {
    param([double]$Minimum = 20)
    $users = Get-GpuUsers
    if ($users.Count -eq 0) { return $null }

    $bestPid = $null
    $bestVal = 0.0
    foreach ($k in $users.Keys) {
        if ($users[$k] -gt $bestVal) { $bestVal = $users[$k]; $bestPid = $k }
    }
    if ($null -eq $bestPid) { return $null }
    if ($bestVal -lt $Minimum) { return $null }

    $proc = Get-Process -Id $bestPid -ErrorAction SilentlyContinue
    $procName = ''
    if ($proc) { $procName = $proc.ProcessName }

    return [pscustomobject]@{
        Pid     = $bestPid
        Name    = $procName
        Percent = [math]::Round($bestVal, 1)
    }
}

# ------------------------------------------------------------------ clock control

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

# ------------------------------------------------------------------ profile

function Get-ProfileClock {
    param($State)
    if (-not (Test-Path $ProfilePath)) { return $null }
    try {
        $obj = Get-Content $ProfilePath -Raw -Encoding utf8 | ConvertFrom-Json
        if (-not $obj -or -not $obj.profiles) { return $null }
        $deviceId = $null
        $r = Invoke-Smi @('-i', "$script:Gpu", '--query-gpu=pci.device_id', '--format=csv,noheader')
        if ($r.Code -eq 0) { $deviceId = $r.Text.Trim() }
        $wanted = (($deviceId + '|' + $State.Name) -replace '[^A-Za-z0-9]+', '_')
        foreach ($p in $obj.profiles.PSObject.Properties) {
            if ($p.Name -eq $wanted) { return [int]$p.Value.safeClock }
        }
        foreach ($p in $obj.profiles.PSObject.Properties) {
            if ($p.Value.name -eq $State.Name) { return [int]$p.Value.safeClock }
        }
        return $null
    }
    catch { return $null }
}

# ------------------------------------------------------------------ resolve target

$state = Get-GpuState
$source = ''
$target = 0

if ($TargetClock -gt 0) {
    $target = $TargetClock
    $source = 'parameter -TargetClock'
}
elseif ($Percent -gt 0 -and $Percent -le 100) {
    if ($null -eq $state.MaxClock -or $state.MaxClock -le 0) { throw 'Could not read the maximum clock.' }
    $target = [int][math]::Round($state.MaxClock * $Percent / 100.0)
    $source = "parameter -Percent $Percent"
}
else {
    $p = Get-ProfileClock $state
    if ($p) {
        $target = $p
        $source = "profile ($ProfilePath)"
    }
}

if ($Info) {
    Write-Log "card: $($state.Name) | max $($state.MaxClock) MHz | now $($state.CoreClock) MHz | $($state.Temp) C"
    if ($target -gt 0) { Write-Log "target: $target MHz from $source" }
    else { Write-Log 'target: NONE - provide -TargetClock, -Percent or a gpu-profile.json' }
    $top = Get-TopGpuUser -Minimum $LoadThreshold
    if ($top) { Write-Log "current GPU user: $($top.Name) (PID $($top.Pid)) at $($top.Percent)%" }
    else { Write-Log 'current GPU user: none above threshold' }
    Write-Log "poll ${PollSeconds}s | miss limit $MissLimit | refresh ${RefreshSeconds}s"
    exit 0
}

if ($target -le 0) {
    Write-Log 'ERROR: no clock target. Use -TargetClock <MHz>, -Percent <n>, or run gpu-tune -Mode Auto first.'
    exit 1
}

# ------------------------------------------------------------------ main loop

$watch = @($ProcessName | Where-Object { $_ })
$mode = 'auto'
if ($watch.Count -gt 0) { $mode = 'process' }
elseif ($LoadOnly) { $mode = 'load' }

$locked = $false
$lastApply = [datetime]::MinValue
$miss = 0
$safe = $target

Write-Log "watchdog started (PID $PID)"
Write-Log "card: $($state.Name) | lock target $target MHz from $source"
switch ($mode) {
    'process' { Write-Log "watching processes: $($watch -join ', ')" }
    'load' { Write-Log "watching total GPU load, threshold $LoadThreshold%" }
    default { Write-Log 'watching the top GPU consumer (auto detection)' }
}

try {
    while ($true) {
        $worked = $false
        $who = ''

        if ($mode -eq 'process') {
            foreach ($n in $watch) {
                if (Get-Process -Name $n -ErrorAction SilentlyContinue) { $worked = $true; $who = $n; break }
            }
        }
        elseif ($mode -eq 'load') {
            $s = Get-GpuState
            if ($null -ne $s.Util -and $s.Util -ge $LoadThreshold) { $worked = $true; $who = "load $($s.Util)%" }
        }
        else {
            $top = Get-TopGpuUser -Minimum $LoadThreshold
            if ($top) { $worked = $true; $who = "$($top.Name) [PID $($top.Pid)] $($top.Percent)%" }
        }

        if (-not $worked) {
            $miss++
            if ($miss -ge $MissLimit) {
                Write-Log 'No GPU work detected -> stopping.'
                break
            }
            Start-Sleep -Seconds $PollSeconds
            continue
        }

        if ($miss -gt 0) { Write-Log "Work detected again: $who" }
        $miss = 0

        $needApply = (-not $locked)
        if ($RefreshSeconds -gt 0 -and $locked -and ((Get-Date) - $lastApply).TotalSeconds -ge $RefreshSeconds) { $needApply = $true }

        if ($needApply) {
            if (Set-ClockLock $safe) {
                if (-not $locked) { Write-Log "Lock applied: $safe MHz (work: $who)" }
                $locked = $true
                $lastApply = Get-Date
            }
            else {
                Write-Log 'Could not apply the clock lock. Administrator rights or card support missing.'
                break
            }
        }

        $s = Get-GpuState
        $t = 0; if ($null -ne $s.Temp) { $t = $s.Temp }
        $f = 0; if ($null -ne $s.Fan) { $f = $s.Fan }

        if ($t -ge $MaxTemp -or $f -ge $MaxFan) {
            $safe = [math]::Max(600, $safe - $SafetyStep)
            Write-Log "SAFETY: $t C / fan $f% -> lowered to $safe MHz"
            if (-not (Set-ClockLock $safe)) { break }
            $lastApply = Get-Date
        }

        Start-Sleep -Seconds $PollSeconds
    }
}
finally {
    if ($locked) {
        if ($KeepLock) {
            Write-Log "Lock left in place: $safe MHz."
        }
        else {
            Clear-ClockLock
            Write-Log 'Lock released (-rgc).'
        }
    }
}

exit 0
