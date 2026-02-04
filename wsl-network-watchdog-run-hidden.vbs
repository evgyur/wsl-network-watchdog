Set sh = CreateObject("Wscript.Shell")
scriptPath = "D:\.github\wsl-network-watchdog\wsl-network-watchdog.ps1"
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & scriptPath & """", 0, False
