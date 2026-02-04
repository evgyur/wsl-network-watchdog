# Install WSL Network Watchdog as scheduled tasks so it runs always and after reboot.
# Run from Windows (PowerShell). If you get "Access denied", right-click PowerShell -> Run as Administrator.
#
# Usage:
#   .\wsl-network-watchdog-install-task.ps1                    # Asks for password so "Every 2 min" runs without window
#   .\wsl-network-watchdog-install-task.ps1 -RunWhenLocked    # All tasks run when locked (prompts for password)
#   .\wsl-network-watchdog-install-task.ps1 -Uninstall        # Remove all tasks

param(
    [switch]$RunWhenLocked,
    [switch]$Uninstall
)

$ErrorActionPreference = "Stop"
$TaskBase = "WSL Network Watchdog"
$TaskStartup = "$TaskBase (Startup)"
$TaskLogon = "$TaskBase (Logon)"
$TaskRepeat = "$TaskBase (Every 2 min)"
$TaskVpnkitLogon = "WSL VPNKit (Logon)"
$ScriptDir = $PSScriptRoot
$WatchdogScript = Join-Path $ScriptDir "wsl-network-watchdog.ps1"
$VpnkitStartScript = Join-Path $ScriptDir "wsl-vpnkit-start.ps1"
$VpnkitTr = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$VpnkitStartScript`""

if (-not (Test-Path -LiteralPath $WatchdogScript)) {
    Write-Host "ERROR: Not found: $WatchdogScript" -ForegroundColor Red
    exit 1
}

$Arg = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$WatchdogScript`""
$Tr = "powershell.exe $Arg"
# VBS launcher: no window at all (stops Task Scheduler from flashing a console)
$VbsPath = Join-Path $ScriptDir "wsl-network-watchdog-run-hidden.vbs"
$VbsContent = @"
Set sh = CreateObject("Wscript.Shell")
scriptPath = "$WatchdogScript"
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & scriptPath & """", 0, False
"@
Set-Content -LiteralPath $VbsPath -Value $VbsContent -Encoding ASCII
$TrHidden = "wscript.exe `"$VbsPath`""

function Remove-Tasks {
    $null = cmd /c "schtasks /Delete /TN `"$TaskStartup`" /F 2>nul"
    $null = cmd /c "schtasks /Delete /TN `"$TaskLogon`" /F 2>nul"
    $null = cmd /c "schtasks /Delete /TN `"$TaskRepeat`" /F 2>nul"
    $null = cmd /c "schtasks /Delete /TN `"$TaskVpnkitLogon`" /F 2>nul"
}

if ($Uninstall) {
    Remove-Tasks
    Write-Host "Tasks '$TaskBase' removed." -ForegroundColor Green
    exit 0
}

Remove-Tasks

$ErrorActionPreference = "Continue"
if ($RunWhenLocked) {
    $SecurePass = Read-Host "Enter your Windows password (stored in task so it runs when locked)" -AsSecureString
    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePass)
    $Pass = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
    schtasks /Create /TN $TaskStartup /TR $Tr /SC ONSTART /RU $env:USERNAME /RP $Pass /RL HIGHEST /DELAY 0001:00 /F 2>$null
    schtasks /Create /TN $TaskLogon /TR $Tr /SC ONLOGON /RU $env:USERNAME /RP $Pass /RL HIGHEST /F 2>$null
    schtasks /Create /TN $TaskRepeat /TR $TrHidden /SC MINUTE /MO 2 /RU $env:USERNAME /RP $Pass /RL HIGHEST /F 2>$null
    schtasks /Create /TN $TaskVpnkitLogon /TR $VpnkitTr /SC ONLOGON /RU $env:USERNAME /RP $Pass /RL HIGHEST /F 2>$null
    Write-Host "Tasks installed (run when locked): at startup (1 min delay), at logon, every 2 min, VPNKit at logon." -ForegroundColor Green
} else {
    schtasks /Create /TN $TaskStartup /TR $Tr /SC ONSTART /RU $env:USERNAME /DELAY 0001:00 /F 2>$null
    schtasks /Create /TN $TaskLogon /TR $Tr /SC ONLOGON /RU $env:USERNAME /F 2>$null
    schtasks /Create /TN $TaskVpnkitLogon /TR $VpnkitTr /SC ONLOGON /RU $env:USERNAME /F 2>$null
    Write-Host "To run 'Every 2 min' WITHOUT a flashing window, the task must run in background (needs your Windows password once)." -ForegroundColor Yellow
    $PassRepeat = Read-Host "Enter your Windows password for 'Every 2 min' task (or press Enter to skip; window may flash every 2 min)"
    if ($PassRepeat -and $PassRepeat.Trim().Length -gt 0) {
        schtasks /Create /TN $TaskRepeat /TR $Tr /SC MINUTE /MO 2 /RU $env:USERNAME /RP $PassRepeat /RL HIGHEST /F 2>$null
        Write-Host "Tasks installed. 'Every 2 min' runs in background (no window)." -ForegroundColor Green
    } else {
        schtasks /Create /TN $TaskRepeat /TR $TrHidden /SC MINUTE /MO 2 /RU $env:USERNAME /F 2>$null
        Write-Host "Tasks installed. 'Every 2 min' may briefly show a window; run again and enter password to fix." -ForegroundColor Green
    }
}
$ErrorActionPreference = "Stop"

$null = cmd /c "schtasks /Run /TN `"$TaskRepeat`" 2>nul"
Write-Host "Log: $ScriptDir\wsl-network-watchdog.log (task runs every 2 min; first run in 2 min if manual trigger failed)." -ForegroundColor Gray
if (-not $RunWhenLocked) {
    Write-Host "To run after reboot without logging in, run again with: -RunWhenLocked" -ForegroundColor Gray
}
