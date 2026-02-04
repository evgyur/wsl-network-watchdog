# Start wsl-vpnkit distro in background (VPN network for WSL).
# Used by task "WSL VPNKit (Logon)" and by watchdog.
Start-Process -FilePath "wsl.exe" -ArgumentList "-d wsl-vpnkit", "--cd /app", "wsl-vpnkit" -WindowStyle Hidden
