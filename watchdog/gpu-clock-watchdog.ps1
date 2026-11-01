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
         This mode survives GPU idle phases inside a long job (scene loading,
         encode passes) because it tracks the process, not the utilization.

      3. Any GPU load
         With -LoadOnly, the lock is held whenever total GPU utilization is
         above -LoadThreshold, regardless of which process causes it.

    WHERE THE CLOCK VALUE COMES FROM (first match wins):

      1. -TargetClock <MHz>
      2. -Percent <n>  (percentage of the card's maximum clock)
      3. gpu-profile.json produced by gpu-tune -Mode Auto

    SAFETY:
      If the temperature or the fan reaches its ceiling, the cap is lowered
      further automatically. With -TargetTemp the card is also held at or
      below that working temperature, not just below the emergency ceiling.
      The cap is never raised above the card maximum.

    LOCK LIFE CYCLE:
      Released with -rgc when the workload ends, when you press Ctrl+C, or when
      -MissLimit consecutive polls find no work. Pass -KeepLock to leave the
      cap in place after exit instead.

      Closing the console window with the X button terminates PowerShell without
      running cleanup, so the cap can be left behind. Use Ctrl+C.

      Only one instance runs at a time: a named mutex ("Local\gpu-clock-tools-
      watchdog") makes a second copy exit without touching the clocks, so two
      watchdogs can never release each other's cap.

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
    How often the workload is checked (default 10). The payload sampling time is
    subtracted from this interval, so it is a real cycle time.

.PARAMETER MissLimit
    Consecutive polls without work before the lock is released and the tool
    exits (default 3). Use 0 to wait forever and keep the cap for the whole
    session (daemon style).

.PARAMETER RefreshSeconds
    How often the lock is re-applied while work continues (default 60).
    Covers driver resets, sleep and resume.

.PARAMETER TargetTemp
    Working temperature to hold while the work runs, in Celsius (0 = off).
    When the measured temperature stays at or above it, the ceiling is lowered
    by SafetyStep MHz. Pass the value the tuner found.

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
    .\gpu-clock-watchdog.ps1 -TargetClock 1900 -TargetTemp 65 -ProcessName YOUR_MINER

.EXAMPLE
    .\gpu-clock-watchdog.ps1 -LoadOnly -LoadThreshold 30

.EXAMPLE
    .\gpu-clock-watchdog.ps1 -TargetClock 1900 -MissLimit 0

    Never gives up: holds the cap until Ctrl+C, even across idle gaps.

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

    [int]$TargetTemp = 0,
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
    # PowerShell's [double] cast happens to be culture-invariant, but
    # [double]::TryParse is not. In cultures where "." is the thousands
    # separator, a culture-sensitive read of "62.09" returns 6209 - enough to
    # make the safety logic throttle a cool card down by several steps. Pin the
    # invariant culture so every caller sees the same number.
    param($Value)
    if ($null -eq $Value) { return $null }
    $s = ("$Value").Trim()
    $d = 0.0
    if ([double]::TryParse($s, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $d }
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

function Get-CurrentClock {
    $r = Invoke-Smi @('-i', "$script:Gpu", '--query-gpu=clocks.gr', '--format=csv,noheader,nounits')
    if ($r.Code -ne 0) { return $null }
    return (To-Num $r.Text)
}

function Wait-Poll {
    # Sleeps the remainder of the poll interval. Detection costs a few seconds
    # (three 1 s counter samples), so a plain "sleep PollSeconds" made every
    # cycle about 13 s instead of 10 s.
    param([datetime]$CycleStart)
    $elapsed = ((Get-Date) - $CycleStart).TotalSeconds
    $sleep = $PollSeconds - $elapsed
    if ($sleep -lt 1) { $sleep = 1 }
    Start-Sleep -Milliseconds ([int]($sleep * 1000))
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
    param([int]$Mhz, [switch]$Quiet)

    if ($DryRun) {
        if (-not $Quiet) { Write-Log "[DryRun] would run: -lgc $Mhz" }
        return $true
    }

    # -eow (--error-on-warning) is deliberately NOT used. It turned any driver
    # warning into a non-zero exit code, which made this function return false
    # and aborted the whole session - leaving the card unlocked for the rest of
    # the job. Warnings are logged instead, and the result is verified by
    # reading the clock back.
    $r = Invoke-Smi @('-i', "$script:Gpu", '-lgc', "$Mhz")
    if ($r.Code -ne 0) {
        Write-Log "ERROR -lgc $Mhz : $($r.Text)"
        return $false
    }
    if ($r.Text) { Write-Log "nvidia-smi: $($r.Text)" }

    Start-Sleep -Milliseconds 800
    $now = Get-CurrentClock

    if ($null -ne $now -and $now -gt ($Mhz + 50)) {
        Write-Log "WARNING: asked for $Mhz MHz but the card reports $now MHz - retrying once."
        Start-Sleep -Seconds 2
        $r2 = Invoke-Smi @('-i', "$script:Gpu", '-lgc', "$Mhz")
        if ($r2.Code -ne 0) {
            Write-Log "ERROR -lgc $Mhz (retry) : $($r2.Text)"
            return $false
        }
        Start-Sleep -Milliseconds 800
        $now = Get-CurrentClock
        if ($null -ne $now -and $now -gt ($Mhz + 50)) {
            Write-Log "ERROR: the clock cap did not take effect (asked $Mhz MHz, card reports $now MHz). Another tuning tool may be writing to NVML."
            return $false
        }
    }

    if (-not $Quiet) {
        if ($null -eq $now) { Write-Log "Lock applied: $Mhz MHz (clock read-back unavailable)." }
        else { Write-Log "Lock applied: $Mhz MHz (card reports $now MHz)." }
    }
    return $true
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
    if ($TargetTemp -gt 0) { Write-Log "working temperature: hold at or below $TargetTemp C" }
    else { Write-Log "working temperature: not tracked (emergency ceiling $MaxTemp C)" }
    if ($MissLimit -gt 0) { Write-Log "poll ${PollSeconds}s | miss limit $MissLimit | refresh ${RefreshSeconds}s" }
    else { Write-Log "poll ${PollSeconds}s | miss limit off (runs until Ctrl+C) | refresh ${RefreshSeconds}s" }
    if ($null -eq $state.Fan) { Write-Log 'fan speed: not reported by this card, fan ceiling disabled' }
    exit 0
}

if ($target -le 0) {
    Write-Log 'ERROR: no clock target. Use -TargetClock <MHz>, -Percent <n>, or run gpu-tune -Mode Auto first.'
    exit 1
}

# ------------------------------------------------------------------ single instance

# Two watchdogs used to be able to coexist: the one that exited first called
# -rgc and silently dropped the other one's cap. A named mutex makes the second
# copy exit before it touches anything.
$script:MutexName = 'Local\gpu-clock-tools-watchdog'
$script:Mutex = $null
$script:HaveMutex = $false

if (-not $DryRun) {
    try {
        $script:Mutex = New-Object System.Threading.Mutex($false, $script:MutexName)
        try { $script:HaveMutex = $script:Mutex.WaitOne(0) }
        catch [System.Threading.AbandonedMutexException] { $script:HaveMutex = $true }
    }
    catch {
        Write-Log "WARNING: single-instance check unavailable: $($_.Exception.Message)"
        $script:HaveMutex = $true
    }
    if (-not $script:HaveMutex) {
        Write-Log 'ERROR: another gpu-clock-watchdog is already holding a clock cap. Exiting without touching the clocks.'
        exit 5
    }
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
$script:counterBroken = $false

Write-Log "watchdog started (PID $PID)"
Write-Log "card: $($state.Name) | lock target $target MHz from $source"
if ($TargetTemp -gt 0) { Write-Log "working temperature target: $TargetTemp C (emergency ceiling $MaxTemp C)" }
switch ($mode) {
    'process' { Write-Log "watching processes: $($watch -join ', ')" }
    'load' { Write-Log "watching total GPU load, threshold $LoadThreshold%" }
    default { Write-Log 'watching the top GPU consumer (auto detection)' }
}
if ($MissLimit -le 0) { Write-Log 'miss limit disabled: the cap stays until Ctrl+C' }

try {
    while ($true) {
        $cycleStart = Get-Date
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
            $users = Get-GpuUsers
            if ($users.Count -eq 0) {
                if (-not $script:counterBroken) {
                    Write-Log 'GPU Engine counters unavailable -> falling back to total GPU utilization.'
                    $script:counterBroken = $true
                }
                $s = Get-GpuState
                if ($null -ne $s.Util -and $s.Util -ge $LoadThreshold) { $worked = $true; $who = "load $($s.Util)%" }
            }
            else {
                $bestPid = $null
                $bestVal = 0.0
                foreach ($k in $users.Keys) {
                    if ($users[$k] -gt $bestVal) { $bestVal = $users[$k]; $bestPid = $k }
                }
                if ($null -ne $bestPid -and $bestVal -ge $LoadThreshold) {
                    $proc = Get-Process -Id $bestPid -ErrorAction SilentlyContinue
                    $nm = ''
                    if ($proc) { $nm = $proc.ProcessName }
                    $worked = $true
                    $who = "$nm [PID $bestPid] $([math]::Round($bestVal, 1))%"
                }
            }
        }

        if (-not $worked) {
            $miss++
            if ($MissLimit -gt 0 -and $miss -ge $MissLimit) {
                Write-Log 'No GPU work detected -> stopping.'
                break
            }
            Wait-Poll -CycleStart $cycleStart
            continue
        }

        if ($miss -gt 0) { Write-Log "Work detected again: $who" }
        $miss = 0

        $needApply = (-not $locked)
        if ($RefreshSeconds -gt 0 -and $locked -and ((Get-Date) - $lastApply).TotalSeconds -ge $RefreshSeconds) { $needApply = $true }

        if ($needApply) {
            if (Set-ClockLock -Mhz $safe -Quiet $locked) {
                if (-not $locked) {
                    if ($DryRun) { Write-Log "[DryRun] would apply: $safe MHz (work: $who)" }
                    else { Write-Log "Lock applied: $safe MHz (work: $who)" }
                }
                $locked = $true
                $lastApply = Get-Date
            }
            else {
                Write-Log 'Could not apply the clock lock. Administrator rights or card support missing.'
                break
            }
        }

        $s = Get-GpuState
        $t = 0
        if ($null -ne $s.Temp) { $t = $s.Temp }
        $f = $null
        if ($null -ne $s.Fan) { $f = $s.Fan }

        # One reason per poll, so a hot card walks down in SafetyStep increments
        # instead of jumping. Stricter reasons win.
        $reason = ''
        if ($t -ge $MaxTemp) { $reason = "MAX TEMP $t C >= $MaxTemp C" }
        elseif ($null -ne $f -and $f -ge $MaxFan) { $reason = "MAX FAN $f% >= $MaxFan%" }
        elseif ($TargetTemp -gt 0 -and $t -ge $TargetTemp) { $reason = "WORKING TEMP $t C >= $TargetTemp C" }

        if ($reason) {
            $next = [math]::Max(600, $safe - $SafetyStep)
            if ($next -lt $safe) {
                Write-Log "SAFETY: $reason -> lowered to $next MHz"
                if (-not (Set-ClockLock -Mhz $next -Quiet $true)) { break }
                $safe = $next
                $lastApply = Get-Date
            }
        }

        Wait-Poll -CycleStart $cycleStart
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
    if ($script:HaveMutex -and $null -ne $script:Mutex) {
        try { $script:Mutex.ReleaseMutex() } catch { }
        $script:HaveMutex = $false
    }
    if ($null -ne $script:Mutex) {
        try { $script:Mutex.Dispose() } catch { }
    }
}

exit 0
