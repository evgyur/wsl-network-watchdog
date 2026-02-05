# WSL Network Watchdog
# Runs from Windows; monitors WSL internet. If WSL loses connectivity, restarts WSL (wsl --shutdown).
# Usage:
#   .\wsl-network-watchdog.ps1              # foreground, one check then exit (for testing)
#   .\wsl-network-watchdog.ps1 -Daemon      # loop forever, check every CheckIntervalSeconds
#   Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSScriptRoot\wsl-network-watchdog.ps1`" -Daemon" -WindowStyle Hidden
# Optional: run as Scheduled Task every 2–5 min (single check per run, no -Daemon).

param(
    [switch]$Daemon,
    [int]$CheckIntervalSeconds = 120,
    [int]$FailuresBeforeRestart = 2,
    [string]$CheckUrl = "https://api.telegram.org",
    [string]$LogPath = "",
    [string]$GatewayServiceName = "openclaw-gateway",
    [string]$VpnkitServiceName = "",
    [string]$WslDistroName = "Ubuntu"
)

$ErrorActionPreference = "Continue"
if (-not $LogPath) {
    $LogPath = Join-Path $PSScriptRoot "wsl-network-watchdog.log"
}
$StatePath = Join-Path $PSScriptRoot "wsl-network-watchdog.state"

function Write-WatchdogLog {
    param([string]$Message, [string]$Level = "INFO")
    $line = "{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}" -f (Get-Date), $Level, $Message
    Add-Content -LiteralPath $LogPath -Value $line -ErrorAction SilentlyContinue
    if ($Level -eq "ERROR" -or $Level -eq "WARN") { Write-Host $line }
}

function Get-PersistedFailures {
    if (-not (Test-Path -LiteralPath $StatePath)) { return 0 }
    $line = Get-Content -LiteralPath $StatePath -TotalCount 1 -ErrorAction SilentlyContinue
    if ($line -match "^\d+$") { return [int]$line }
    return 0
}

function Set-PersistedFailures {
    param([int]$Count)
    Set-Content -LiteralPath $StatePath -Value $Count.ToString() -ErrorAction SilentlyContinue
}

function Test-WslNetwork {
    try {
        $code = wsl -e bash -c "curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 $CheckUrl" 2>$null
        return ($code -match "^(200|302)$")
    } catch {
        return $false
    }
}

function Restart-Wsl {
    Set-PersistedFailures 0
    Write-WatchdogLog "WSL network down after $FailuresBeforeRestart failures. Running wsl --shutdown..." "WARN"
    try {
        wsl --shutdown 2>$null
        if ($LASTEXITCODE -ne 0) { wsl --shutdown }
    } catch {
        Write-WatchdogLog "wsl --shutdown failed: $_" "ERROR"
        return $false
    }
    Write-WatchdogLog "wsl --shutdown done. Waiting 5s..." "INFO"
    Start-Sleep -Seconds 5
    # Trigger WSL start and verify
    $check = wsl -e bash -c "curl -s -o /dev/null -w '%{http_code}' --connect-timeout 8 $CheckUrl" 2>$null
    if ($check -match "^(200|302)$") {
        Write-WatchdogLog "WSL restarted; network OK (HTTP $check)." "INFO"
        if ($GatewayServiceName) {
            wsl -e bash -c "systemctl --user start $GatewayServiceName 2>/dev/null; exit 0" 2>$null
        }
        if ($VpnkitServiceName) {
            wsl -e bash -c "sudo -n systemctl start $VpnkitServiceName 2>/dev/null; exit 0" 2>$null
        }
        Start-Sleep -Seconds 2
        Ensure-VpnkitDistroStarted
        Ensure-WslKeepalive
        Set-PersistedFailures 0
        return $true
    }
    Write-WatchdogLog "WSL back but network still not OK (got $check)." "WARN"
    return $false
}

# Ensure gateway service is running in WSL (idempotent; skip if $GatewayServiceName is empty)
function Ensure-GatewayStarted {
    if (-not $GatewayServiceName) { return }
    wsl -e bash -lc "systemctl --user start $GatewayServiceName 2>/dev/null; exit 0" 2>$null
}

# Check if gateway service is active in WSL
function Test-GatewayRunning {
    if (-not $GatewayServiceName) { return $true }
    try {
        $status = wsl -e bash -c "systemctl --user is-active $GatewayServiceName 2>/dev/null" 2>$null
        return ($status -eq "active")
    } catch {
        return $false
    }
}

# Restart gateway service in WSL (e.g. after crash)
function Restart-Gateway {
    if (-not $GatewayServiceName) { return }
    wsl -e bash -lc "systemctl --user restart $GatewayServiceName 2>/dev/null; exit 0" 2>$null
}

# Ensure wsl-vpnkit (system) service is running in WSL. Uses sudo -n (no prompt); skip if empty or sudo fails.
function Ensure-VpnkitStarted {
    if (-not $VpnkitServiceName) { return }
    wsl -e bash -c "sudo -n systemctl start $VpnkitServiceName 2>/dev/null; exit 0" 2>$null
}

function Test-VpnkitRunning {
    if (-not $VpnkitServiceName) { return $true }
    try {
        $status = wsl -e bash -c "sudo -n systemctl is-active $VpnkitServiceName 2>/dev/null" 2>$null
        return ($status -eq "active")
    } catch {
        return $false
    }
}

function Restart-Vpnkit {
    if (-not $VpnkitServiceName) { return }
    wsl -e bash -c "sudo -n systemctl restart $VpnkitServiceName 2>/dev/null; exit 0" 2>$null
}

# Ensure wsl-vpnkit distro is running (VPN network for WSL). Starts it in background if Stopped.
function Ensure-VpnkitDistroStarted {
    try {
        # wsl -l -v outputs UTF-16LE with null bytes; strip them to get ASCII
        $raw = wsl -l -v 2>&1 | Out-String
        $list = $raw -replace '\x00', ''
        if ($list -match 'wsl-vpnkit\s+Running') { return }
        $startScript = Join-Path $PSScriptRoot "wsl-vpnkit-start.ps1"
        if (Test-Path -LiteralPath $startScript) {
            & $startScript
        } else {
            Start-Process -FilePath "wsl.exe" -ArgumentList "-d wsl-vpnkit", "--cd /app", "wsl-vpnkit" -WindowStyle Hidden -ErrorAction SilentlyContinue
        }
        Write-WatchdogLog "wsl-vpnkit distro was stopped; started in background." "WARN"
    } catch { }
}

# Ensure a persistent "wsl -d <Distro> sleep infinity" process exists on the Windows side.
# Without it, WSL 2 auto-terminates the VM after vmIdleTimeout (default 60 s on Win 11),
# killing all services inside (gateway, bots, etc.) even though they are still running.
function Ensure-WslKeepalive {
    if (-not $WslDistroName) { return }
    try {
        $procs = Get-WmiObject Win32_Process -Filter "Name='wsl.exe'" -ErrorAction SilentlyContinue
        foreach ($p in $procs) {
            if ($p.CommandLine -and $p.CommandLine -match "-d\s+$([regex]::Escape($WslDistroName))\s+sleep\s+infinity") {
                return  # already running
            }
        }
        # No keepalive found — start one hidden
        Start-Process -FilePath "wsl.exe" -ArgumentList "-d", $WslDistroName, "sleep", "infinity" -WindowStyle Hidden -ErrorAction Stop
        Write-WatchdogLog "WSL keepalive started (wsl -d $WslDistroName sleep infinity)." "INFO"
    } catch {
        Write-WatchdogLog "Failed to start WSL keepalive: $_" "WARN"
    }
}

# Single check (uses persisted failure count for scheduled-task runs)
function Invoke-OneCheck {
    $Script:ConsecutiveFailures = Get-PersistedFailures
    if (Test-WslNetwork) {
        if ($Script:ConsecutiveFailures -gt 0) {
            Write-WatchdogLog "WSL network OK again (recovered)." "INFO"
        }
        Set-PersistedFailures 0
        # WSL is up and has network; ensure gateway runs (e.g. after cold boot)
        Ensure-GatewayStarted
        # If gateway is down (crashed), restart it
        if (-not (Test-GatewayRunning)) {
            Write-WatchdogLog "Gateway ($GatewayServiceName) not active; restarting." "WARN"
            Restart-Gateway
        }
        # Optional: ensure wsl-vpnkit (system service) is running
        Ensure-VpnkitStarted
        if ($VpnkitServiceName -and -not (Test-VpnkitRunning)) {
            Write-WatchdogLog "Vpnkit ($VpnkitServiceName) not active; restarting (needs passwordless sudo in WSL)." "WARN"
            Restart-Vpnkit
        }
        # Ensure wsl-vpnkit distro is running (VPN network)
        Ensure-VpnkitDistroStarted
        # Keep WSL VM alive so services don't get killed by idle timeout
        Ensure-WslKeepalive
        return
    }
    $Script:ConsecutiveFailures++
    Set-PersistedFailures $Script:ConsecutiveFailures
    Write-WatchdogLog "WSL network check failed ($Script:ConsecutiveFailures/$FailuresBeforeRestart)." "WARN"
    if ($Script:ConsecutiveFailures -ge $FailuresBeforeRestart) {
        Restart-Wsl
    }
}

Write-WatchdogLog "Watchdog started. CheckUrl=$CheckUrl Interval=${CheckIntervalSeconds}s FailuresBeforeRestart=$FailuresBeforeRestart Gateway=$GatewayServiceName Vpnkit=$VpnkitServiceName Distro=$WslDistroName Log=$LogPath"
Ensure-WslKeepalive
Invoke-OneCheck

if (-not $Daemon) {
    Write-WatchdogLog "Single check done (no -Daemon)."
    exit 0
}

Write-WatchdogLog "Daemon mode: checking every ${CheckIntervalSeconds}s."
while ($true) {
    Start-Sleep -Seconds $CheckIntervalSeconds
    Invoke-OneCheck
}
