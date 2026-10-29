param(
    [switch]$KeepProfile
)

$ErrorActionPreference = 'SilentlyContinue'

$root = Join-Path $env:LOCALAPPDATA 'gpu-clock-tools'
$lnkPath = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\GPU Clock Tools.lnk'
$deskPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'GPU Clock Tools.lnk'

Write-Host ''
Write-Host '  Removing GPU Clock Tools...' -ForegroundColor Cyan

# 1) stop any running instance (watchdog, tuner, launcher)
$stopped = 0
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object {
    $_.ProcessId -ne $PID -and
    $_.CommandLine -and
    $_.CommandLine -match '-File.*(gpu-clock-watchdog|gpu-tune)\.ps1'
} | ForEach-Object {
    Stop-Process -Id $_.ProcessId -Force
    $stopped++
}
Write-Host "  Stopped processes: $stopped"

# 2) release any clock lock so the card returns to driver defaults
& nvidia-smi -i 0 -rgc 2>&1 | Out-Null
$probe = & nvidia-smi --query-gpu=clocks.gr --format=csv,noheader 2>&1
Write-Host "  Clock lock released (card now reports: $probe)"

# 3) shortcuts
foreach ($p in @($lnkPath, $deskPath)) {
    if (Test-Path $p) { Remove-Item $p -Force; Write-Host "  Removed shortcut: $p" }
}

# 4) profile / logs / app folder
if (Test-Path $root) {
    if ($KeepProfile -and (Test-Path (Join-Path $root 'gpu-profile.json'))) {
        Write-Host '  Keeping gpu-profile.json (-KeepProfile)'
        Get-ChildItem $root -Exclude 'gpu-profile.json' | Remove-Item -Recurse -Force
    }
    else {
        Remove-Item $root -Recurse -Force
        Write-Host "  Removed: $root"
    }
}

# 5) nothing else was ever installed
Write-Host ''
Write-Host '  No scheduled tasks, services or registry entries were created.' -ForegroundColor Green
Write-Host '  Nothing starts at boot.' -ForegroundColor Green
Write-Host ''

# the script itself may live inside the removed folder - finish from temp
if (-not (Test-Path $root)) {
    Write-Host '  Done. Nothing is left on this machine.' -ForegroundColor Green
}
Start-Sleep -Seconds 4
