param(
    [switch]$DesktopShortcut
)

$ErrorActionPreference = 'Stop'

$src = $PSScriptRoot
$root = Join-Path $env:LOCALAPPDATA 'gpu-clock-tools'
$app = Join-Path $root 'app'

Write-Host ''
Write-Host '  Installing GPU Clock Tools...' -ForegroundColor Cyan
Write-Host "  Target: $app"

New-Item -ItemType Directory -Force -Path $app | Out-Null

foreach ($item in @('tuner', 'watchdog')) {
    $dst = Join-Path $app $item
    if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
    Copy-Item (Join-Path $src $item) $app -Recurse -Force
}

foreach ($f in @('launch.bat', 'uninstall.bat', 'uninstall.ps1', 'README.md', 'DISCLAIMER.md', 'LICENSE')) {
    $p = Join-Path $src $f
    if (Test-Path $p) { Copy-Item $p $app -Force }
}

# Start menu shortcut (no autostart, no registry entries)
$ws = New-Object -ComObject WScript.Shell
$lnkPath = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\GPU Clock Tools.lnk'
$lnk = $ws.CreateShortcut($lnkPath)
$lnk.TargetPath = Join-Path $app 'launch.bat'
$lnk.WorkingDirectory = $app
$lnk.IconLocation = "$env:SystemRoot\System32\shell32.dll,13"
$lnk.Description = 'GPU clock tuner and workload watchdog'
$lnk.Save()
Write-Host "  Shortcut: $lnkPath"

if ($DesktopShortcut) {
    $deskPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'GPU Clock Tools.lnk'
    $d = $ws.CreateShortcut($deskPath)
    $d.TargetPath = Join-Path $app 'launch.bat'
    $d.WorkingDirectory = $app
    $d.IconLocation = "$env:SystemRoot\System32\shell32.dll,13"
    $d.Save()
    Write-Host "  Desktop shortcut: $deskPath"
}

Write-Host ''
Write-Host '  Done. Open "GPU Clock Tools" from the Start menu.' -ForegroundColor Green
Write-Host '  Nothing starts automatically at boot.' -ForegroundColor Green
Write-Host ''
Write-Host '  To remove everything later, run:' -ForegroundColor DarkGray
Write-Host "    $app\uninstall.bat" -ForegroundColor DarkGray
Write-Host ''
Start-Sleep -Seconds 4
