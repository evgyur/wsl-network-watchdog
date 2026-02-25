CreateObject("WScript.Shell").Run "powershell.exe -ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File """ & "C:\wsl-watchdog\wsl-network-watchdog.ps1" & """", 0, False
