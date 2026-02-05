# WSL Network Watchdog

A Windows PowerShell script that monitors WSL (Windows Subsystem for Linux) network connectivity. If WSL loses internet access, it restarts WSL automatically. Optional: ensure a systemd user service (e.g. a gateway or bot) is running inside WSL and restart it if it crashes.

**Use case:** WSL sometimes loses network after sleep, VPN changes, or Windows updates. This watchdog runs as a scheduled task every 2 minutes, checks connectivity from inside WSL, and runs `wsl --shutdown` if the check fails twice in a row—bringing WSL back with working network. No secrets are stored in the repo; the installer may ask for your Windows password so the task runs without showing a window.

---

## WSL networking stack (two parts)

This repo includes two pieces that work together on Windows + WSL:

| Part | Role |
|------|------|
| **[wsl-vpnkit](wsl-vpnkit/)** (submodule) | Gives WSL 2 network when the Windows host is on VPN. Uses [gvisor-tap-vsock](https://github.com/containers/gvisor-tap-vsock); no admin or VPN settings on Windows. Set up once (distro or standalone + systemd), then WSL has internet through VPN. |
| **This watchdog** | Detects when WSL has lost network (sleep, VPN toggle, Windows update) and runs `wsl --shutdown` to restore it. Runs every 2 minutes as a scheduled task. |

**Typical setup:** Install and run **wsl-vpnkit** in WSL (see [wsl-vpnkit/README.md](wsl-vpnkit/README.md)) so that WSL works over VPN. Then install **this watchdog** on Windows so that if the network still drops, WSL is restarted automatically and comes back with connectivity. The watchdog can also **check and restart wsl-vpnkit** if it crashes — use `-VpnkitServiceName "wsl-vpnkit"` (and passwordless `sudo systemctl` in WSL).

To clone with the submodule:
```powershell
git clone --recurse-submodules https://github.com/evgyur/wsl-network-watchdog.git
# or, if already cloned:
git submodule update --init --recursive
```

---

## Requirements

- **Windows 10/11** with WSL 2
- **PowerShell** (built-in)
- **curl** inside WSL (usually present in Ubuntu/Debian)

Optional: a **systemd user service** in WSL (e.g. `openclaw-gateway`, `my-bot.service`) to start/restart when WSL or the service is down.

---

## Quick Start

1. **Download** this folder (or clone the repo) to your PC, e.g. `C:\wsl-watchdog\`.

2. **Open PowerShell** and go to that folder:
   ```powershell
   cd C:\wsl-watchdog
   ```

3. **Install scheduled tasks** (runs at startup, at logon, and every 2 min):
   ```powershell
   .\wsl-network-watchdog-install-task.ps1
   ```
   When prompted, enter your **Windows password** so the "Every 2 min" task runs in the background without flashing a window. (You can press Enter to skip; the task will still run but may briefly show a window every 2 minutes.)

4. **Done.** The watchdog will:
   - Check WSL network every 2 minutes (via a reachable URL, default `https://api.telegram.org`).
   - If the check fails **twice in a row**, run `wsl --shutdown`, wait 5 seconds, then verify network again.
   - If you use the default gateway service name, it will also start/restart that service in WSL when needed.

Log file: `wsl-network-watchdog.log` in the same folder.

---

## What Gets Installed

| Task | When it runs |
|------|----------------|
| **WSL Network Watchdog (Startup)** | About 1 minute after Windows starts |
| **WSL Network Watchdog (Logon)** | When you log in to Windows |
| **WSL Network Watchdog (Every 2 min)** | Every 2 minutes while you are logged in (or always if you used `-RunWhenLocked`) |

Each run runs the main script once: one network check, optional gateway check/restart, and exit. No long-running process.

---

## Uninstall

```powershell
cd C:\wsl-watchdog
.\wsl-network-watchdog-install-task.ps1 -Uninstall
```

---

## Repo contents

| Item | Purpose |
|------|---------|
| `wsl-vpnkit/` | **Submodule** — [sakai135/wsl-vpnkit](https://github.com/sakai135/wsl-vpnkit): WSL 2 network over VPN. See [wsl-vpnkit/README.md](wsl-vpnkit/README.md) for setup. |
| `wsl-network-watchdog.ps1` | Main script: checks WSL network, restarts WSL if needed, optionally starts/restarts a gateway service. |
| `wsl-network-watchdog-install-task.ps1` | Installs or removes the three scheduled tasks. |
| `wsl-network-watchdog-run-hidden.vbs` | Helper: run the main script with no window (path inside is updated when you run the installer). |

---

## Options

### Main script (`wsl-network-watchdog.ps1`)

Run once (e.g. for testing):

```powershell
.\wsl-network-watchdog.ps1
```

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-Daemon` | — | Loop forever, check every `-CheckIntervalSeconds`. |
| `-CheckIntervalSeconds` | 120 | Seconds between checks in daemon mode. |
| `-FailuresBeforeRestart` | 2 | Consecutive failures before running `wsl --shutdown`. |
| `-CheckUrl` | `https://api.telegram.org` | URL used to test connectivity from WSL (should return 200 or 302). |
| `-LogPath` | same folder, `wsl-network-watchdog.log` | Log file path. |
| `-GatewayServiceName` | `openclaw-gateway` | systemd **user** service name in WSL to start/restart. Use `""` to disable gateway logic. |
| `-VpnkitServiceName` | `""` | systemd **system** service name in WSL (e.g. `wsl-vpnkit`) to start/restart when it crashes. Use `""` to skip. Requires passwordless `sudo systemctl` in WSL. |
| `-WslDistroName` | `Ubuntu` | WSL distro name for the keepalive process (`wsl -d <name> sleep infinity`). Prevents WSL from auto-terminating due to idle timeout. Use `""` to disable. |

Examples:

```powershell
# Use a different URL for the check
.\wsl-network-watchdog.ps1 -CheckUrl "https://google.com"

# No gateway service (only network + WSL restart)
.\wsl-network-watchdog.ps1 -GatewayServiceName ""

# Different gateway service name
.\wsl-network-watchdog.ps1 -GatewayServiceName "my-bot.service"

# Also check and restart wsl-vpnkit (system service) when it crashes
.\wsl-network-watchdog.ps1 -VpnkitServiceName "wsl-vpnkit"
```

### Install script (`wsl-network-watchdog-install-task.ps1`)

| Parameter | Description |
|-----------|-------------|
| (none) | Install tasks; prompts for password so "Every 2 min" runs without a window. |
| `-RunWhenLocked` | Install so tasks run even when the PC is locked or before you log in (prompts for Windows password). |
| `-Uninstall` | Remove all three tasks. |

---

## How It Works

1. **Network check:** The script runs `wsl -e bash -c "curl ... $CheckUrl"`. That starts WSL if it is not running and tests outbound connectivity from inside WSL.
2. **Failure count:** If the check fails, a failure count is stored in `wsl-network-watchdog.state`. If it reaches `FailuresBeforeRestart` (default 2), the script runs `wsl --shutdown`, waits 5 seconds, then checks again.
3. **Gateway (optional):** If `GatewayServiceName` is set, after a successful network check the script ensures the service is started and, if it is not active, runs `systemctl --user restart $GatewayServiceName` in WSL.
4. **WSL keepalive:** On Windows 11, WSL 2 auto-terminates the VM after `vmIdleTimeout` (default 60 seconds) if there is no active `wsl.exe` process on the Windows side — even if services are running inside WSL. The watchdog ensures a hidden `wsl -d <Distro> sleep infinity` process is always running, preventing the VM from shutting down. This runs at script startup and after every successful check or WSL restart.

No credentials or secrets are stored in the repository. The installer may ask for your Windows password so that the "Every 2 min" task can run in the background; that password is stored only in Windows Task Scheduler for that task.

---

## Troubleshooting

- **"Access denied" when installing tasks**  
  Run PowerShell as Administrator (right-click → Run as administrator), then run the install script again.

- **Window flashes every 2 minutes**  
  Run the install script again and enter your Windows password when prompted for the "Every 2 min" task. That makes the task run in the background with no window.

- **Watchdog runs but WSL still has no network**  
  Check the log: `wsl-network-watchdog.log`. If you see "WSL restarted; network OK" but WSL still has no internet, the issue may be DNS or firewall. Try from Windows: `wsl --shutdown`, then open WSL again and test.

- **No gateway / different service name**  
  Use `-GatewayServiceName ""` to disable gateway logic, or pass your service name when running the script. The scheduled task runs the script without extra parameters, so to change the gateway name for the scheduled task you would need to edit the task action in Task Scheduler and add `-GatewayServiceName "your-service"` to the PowerShell command line.

- **WSL keeps shutting down / services restart every 1–2 minutes**  
  On Windows 11, WSL 2 shuts the VM down after 60 seconds of idle (no Windows-side `wsl.exe` process). The watchdog now auto-starts a hidden `wsl -d Ubuntu sleep infinity` keepalive to prevent this. If it still happens, create `%USERPROFILE%\.wslconfig` with `[wsl2]` and `vmIdleTimeout=-1` and restart WSL.

- **wsl-vpnkit: keep it running**  
  The [wsl-vpnkit](wsl-vpnkit/) service file has `Restart=always`, so systemd will restart it if it crashes. To have **this watchdog** also check and restart wsl-vpnkit every run (e.g. after WSL wake), add `-VpnkitServiceName "wsl-vpnkit"` to the task. That uses `sudo systemctl start/restart wsl-vpnkit` in WSL — configure [passwordless sudo](https://github.com/sakai135/wsl-vpnkit#setup-systemd) for `systemctl` so the watchdog can restart it without prompting.

---

## License

MIT License. See [LICENSE](LICENSE) in this folder.
