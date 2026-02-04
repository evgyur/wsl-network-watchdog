' Launcher: runs wsl-network-watchdog.ps1 with no window (for scheduled task).
' The install script overwrites the path below with your actual script path.
Set sh = CreateObject("Wscript.Shell")
scriptPath = "C:\wsl-watchdog\wsl-network-watchdog.ps1"
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & scriptPath & """", 0, False
