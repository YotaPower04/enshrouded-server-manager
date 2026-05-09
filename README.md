# Enshrouded Server Manager

A PyQt6 desktop app for managing a dedicated Enshrouded server on Linux. Runs the Windows server binary through GE-Proton (Wine-based), with a system tray icon and a tabbed GUI for everything you need.

## Features

- **Server tab** — Start/stop the server, see live status
- **Logs tab** — Live log output from the server
- **Worlds tab** — Manage multiple save worlds
- **Resource Server tab** — Configure the in-game resource server
- **Configuration tab** — Edit server name, password, player slots, and more
- System tray icon with quick controls
- First-run setup wizard — auto-generates the world and migrates saves to a managed layout
- Port conflict detection on startup

## Requirements

- Linux (any distro with Python 3.8+)
- Python 3.8+ with `venv`
- `curl` and `tar`
- Internet connection (installer downloads the server and GE-Proton)

## Installation

Download the latest release zip, extract it, and run:

```bash
bash install.sh
```

The installer handles everything: downloading SteamCMD, the Enshrouded server, GE-Proton, setting up a Python venv with PyQt6, and creating desktop shortcuts.

## Port Forwarding

For players outside your local network to connect, forward these ports on your router to this machine:

| Port  | Protocol | Purpose            |
|-------|----------|--------------------|
| 15636 | UDP      | Game traffic       |
| 15637 | UDP      | Steam server query |

If you have a software firewall:

```bash
# firewalld
sudo firewall-cmd --add-port=15636/udp --add-port=15637/udp --permanent
sudo firewall-cmd --reload

# ufw
sudo ufw allow 15636/udp && sudo ufw allow 15637/udp
```

## First Run

On first launch the manager will automatically start the server to generate the world files. Once the world is ready, click **Complete Setup Now** — the manager will move the save files to its managed layout and restart. After that, normal operation begins.

## Launching Manually

If you need to launch without a desktop shortcut:

```bash
/path/to/your/install/launch.sh
```
