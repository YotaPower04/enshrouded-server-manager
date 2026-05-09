#!/bin/bash
# Enshrouded Dedicated Server Manager — Installer
# Supports any Linux distro with Python 3.8+, curl, and tar.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENSHROUDED_APP_ID="2278520"
STEAMCMD_URL="https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz"
GE_PROTON_API="https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases/latest"

# Global — set by install_ge_proton(), consumed by setup_manager()
GE_PROTON_DIR=""
INSTALL_DIR=""
PYTHON=""

# ---------------------------------------------------------------------------
# Colour helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[ OK ]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()     { echo -e "${RED}[ERR ]${NC} $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Step 1: Verify prerequisites
# ---------------------------------------------------------------------------
check_prerequisites() {
    info "Checking prerequisites..."

    # Python 3.8+
    for cmd in python3 python; do
        if command -v "$cmd" &>/dev/null; then
            if "$cmd" -c "import sys; sys.exit(0 if sys.version_info >= (3,8) else 1)" 2>/dev/null; then
                PYTHON="$cmd"
                break
            fi
        fi
    done
    [[ -n "$PYTHON" ]] || die "Python 3.8 or newer is required. Install it with your package manager (e.g. sudo apt install python3)."
    success "Python: $($PYTHON --version)"

    # venv
    "$PYTHON" -m venv --help &>/dev/null \
        || die "Python venv module missing. Install it (e.g. sudo apt install python3-venv)."
    success "Python venv: OK"

    # curl
    command -v curl &>/dev/null || die "curl is required (sudo apt install curl / sudo dnf install curl)."
    success "curl: $(curl --version | head -1)"

    # tar
    command -v tar &>/dev/null || die "tar is required."
    success "tar: OK"
}

# ---------------------------------------------------------------------------
# Step 2: Choose install directory
# ---------------------------------------------------------------------------
choose_install_dir() {
    echo ""
    echo "Where would you like to install the Enshrouded server?"
    echo "All server files, saves, and manager files will live inside this folder."
    echo ""
    local default_dir="$HOME/enshrouded-server"
    read -rp "Install directory [${default_dir}]: " raw_dir
    raw_dir="${raw_dir:-$default_dir}"
    raw_dir="${raw_dir/#\~/$HOME}"
    INSTALL_DIR="$(realpath -m "$raw_dir")"

    if [[ -d "$INSTALL_DIR" ]] && [[ -n "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]]; then
        warn "Directory already exists and is not empty: $INSTALL_DIR"
        read -rp "Continue anyway? [y/N]: " confirm
        [[ "${confirm,,}" == "y" ]] || { info "Aborted."; exit 0; }
    fi
    echo ""
    info "Install directory: $INSTALL_DIR"
}

# ---------------------------------------------------------------------------
# Step 3: Create directory layout
# ---------------------------------------------------------------------------
create_dirs() {
    info "Creating directory structure..."
    mkdir -p \
        "$INSTALL_DIR/server" \
        "$INSTALL_DIR/saves/worlds" \
        "$INSTALL_DIR/saves/logs" \
        "$INSTALL_DIR/proton" \
        "$INSTALL_DIR/steamcmd"
    success "Directories created."
}

# ---------------------------------------------------------------------------
# Step 4: Download SteamCMD
# ---------------------------------------------------------------------------
install_steamcmd() {
    info "Downloading SteamCMD..."
    curl -sSL "$STEAMCMD_URL" | tar -xz -C "$INSTALL_DIR/steamcmd"
    # First run: accept EULA / do initial self-update (may exit non-zero — ignore)
    "$INSTALL_DIR/steamcmd/steamcmd.sh" +quit 2>/dev/null || true
    success "SteamCMD installed."
}

# ---------------------------------------------------------------------------
# Step 5: Download Enshrouded Dedicated Server via SteamCMD
# ---------------------------------------------------------------------------
download_server() {
    info "Downloading Enshrouded Dedicated Server (this may take several minutes)..."
    # SteamCMD doesn't handle spaces in +force_install_dir even when shell-quoted.
    # Use a temp symlink if the path contains spaces.
    local server_dir="$INSTALL_DIR/server"
    local tmp_link=""
    if [[ "$server_dir" == *" "* ]]; then
        tmp_link=$(mktemp -d -u /tmp/esm_XXXXXX)
        ln -s "$INSTALL_DIR" "$tmp_link"
        server_dir="$tmp_link/server"
    fi

    "$INSTALL_DIR/steamcmd/steamcmd.sh" \
        +@sSteamCmdForcePlatformType windows \
        +force_install_dir "$server_dir" \
        +login anonymous \
        +app_update "$ENSHROUDED_APP_ID" validate \
        +quit

    [[ -n "$tmp_link" ]] && rm -f "$tmp_link"
    success "Enshrouded Dedicated Server downloaded."

    info "Removing SteamCMD..."
    rm -rf "$INSTALL_DIR/steamcmd"
    success "SteamCMD removed."
}

# ---------------------------------------------------------------------------
# Step 5b: Patch server .exe PE subsystem (suppresses Wine console window)
# ---------------------------------------------------------------------------
patch_server_exe() {
    local exe="$INSTALL_DIR/server/enshrouded_server.exe"
    if [[ ! -f "$exe" ]]; then
        warn "enshrouded_server.exe not found — skipping PE patch."
        return
    fi
    info "Patching server executable (suppress Wine console window)..."
    "$PYTHON" - "$exe" <<'PYEOF'
import sys, struct
from pathlib import Path

exe = Path(sys.argv[1])
try:
    with open(exe, 'r+b') as f:
        if f.read(2) != b'MZ':
            print("  Not a valid PE file — skipping.")
            sys.exit(0)
        f.seek(0x3C)
        pe_offset = struct.unpack('<I', f.read(4))[0]
        f.seek(pe_offset)
        if f.read(4) != b'PE\x00\x00':
            print("  PE signature not found — skipping.")
            sys.exit(0)
        # Subsystem field: pe_offset + 4 (sig) + 20 (COFF) + 68 (opt header offset)
        subsystem_off = pe_offset + 4 + 20 + 68
        f.seek(subsystem_off)
        current = struct.unpack('<H', f.read(2))[0]
        if current == 3:
            f.seek(subsystem_off)
            f.write(struct.pack('<H', 2))
            print("  Patched: CONSOLE (3) → WINDOWS (2).")
        else:
            print(f"  Already patched or unexpected subsystem ({current}) — no change.")
except OSError as e:
    print(f"  Warning: could not patch: {e}")
PYEOF
    success "PE patch done."
}

# ---------------------------------------------------------------------------
# Step 6: Download latest GE-Proton
# ---------------------------------------------------------------------------
install_ge_proton() {
    info "Fetching latest GE-Proton release info from GitHub..."
    local tmp_json
    tmp_json=$(mktemp)
    curl -sSL -H "Accept: application/vnd.github+json" "$GE_PROTON_API" > "$tmp_json" \
        || { rm -f "$tmp_json"; die "Failed to reach GitHub API. Check your internet connection."; }

    # Parse JSON with Python (no jq dependency)
    local parsed
    parsed=$("$PYTHON" - "$tmp_json" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
for asset in data.get("assets", []):
    name = asset["name"]
    if name.endswith(".tar.gz") and "GE-Proton" in name:
        print(asset["browser_download_url"])
        print(name)
        break
PYEOF
    )
    rm -f "$tmp_json"

    local tarball_url tarball_name
    tarball_url=$(echo "$parsed" | sed -n '1p')
    tarball_name=$(echo "$parsed" | sed -n '2p')
    [[ -n "$tarball_url" ]] || die "Could not find GE-Proton tarball in GitHub API response."

    info "Downloading $tarball_name..."
    curl -L --progress-bar -o "/tmp/$tarball_name" "$tarball_url"

    info "Extracting GE-Proton to $INSTALL_DIR/proton/ ..."
    tar -xf "/tmp/$tarball_name" -C "$INSTALL_DIR/proton"
    rm -f "/tmp/$tarball_name"

    # Locate the extracted versioned directory (e.g. GE-Proton10-25)
    GE_PROTON_DIR=$(find "$INSTALL_DIR/proton" -maxdepth 1 -type d -name 'GE-Proton*' | sort -V | tail -1)
    [[ -n "$GE_PROTON_DIR" ]] || die "Could not find extracted GE-Proton directory."
    success "GE-Proton installed: $(basename "$GE_PROTON_DIR")"
}

# ---------------------------------------------------------------------------
# Helper: stop a running manager instance before updating files
# ---------------------------------------------------------------------------
stop_running_manager() {
    local pid_file="$INSTALL_DIR/manager.pid"
    [[ -f "$pid_file" ]] || return 0
    local pid
    pid=$(cat "$pid_file" 2>/dev/null || true)
    [[ -n "$pid" ]] || return 0
    if kill -0 "$pid" 2>/dev/null; then
        info "Stopping running manager (PID $pid)..."
        kill "$pid" 2>/dev/null || true
        local waited=0
        while kill -0 "$pid" 2>/dev/null && [[ $waited -lt 10 ]]; do
            sleep 1
            waited=$((waited + 1))
        done
        if kill -0 "$pid" 2>/dev/null; then
            warn "Manager did not stop gracefully — sending SIGKILL..."
            kill -9 "$pid" 2>/dev/null || true
            sleep 1
        fi
        success "Manager stopped."
    fi
    rm -f "$pid_file"
}

# ---------------------------------------------------------------------------
# Step 7: Python venv, PyQt6, manager script, install.json, launch.sh
# ---------------------------------------------------------------------------
setup_manager() {
    info "Creating Python virtual environment..."
    "$PYTHON" -m venv "$INSTALL_DIR/venv"
    success "venv created."

    info "Installing PyQt6 (this may take a minute)..."
    "$INSTALL_DIR/venv/bin/pip" install --quiet --upgrade pip
    "$INSTALL_DIR/venv/bin/pip" install --quiet PyQt6
    success "PyQt6 installed."

    info "Copying manager script..."
    stop_running_manager
    cp "$REPO_DIR/enshrouded_manager.py" "$INSTALL_DIR/enshrouded_manager.py"
    success "Manager script copied."

    info "Writing install.json..."
    "$PYTHON" -c "
import json
from pathlib import Path
cfg = {'install_dir': '${INSTALL_DIR}', 'ge_proton_dir': '${GE_PROTON_DIR}'}
Path('${INSTALL_DIR}/install.json').write_text(json.dumps(cfg, indent=4) + '\n')
print('  install_dir:', cfg['install_dir'])
print('  ge_proton_dir:', cfg['ge_proton_dir'])
"

    info "Writing launch.sh..."
    cat > "$INSTALL_DIR/launch.sh" <<'LAUNCH'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/venv/bin/python" "$SCRIPT_DIR/enshrouded_manager.py" >> "$SCRIPT_DIR/error.log" 2>&1
LAUNCH
    chmod +x "$INSTALL_DIR/launch.sh"
    success "launch.sh written."
}

# ---------------------------------------------------------------------------
# Step 8: Optional desktop shortcut + autostart
# ---------------------------------------------------------------------------
setup_desktop() {
    echo ""
    read -rp "Create desktop shortcut and autostart on login? [Y/n]: " yn
    [[ "${yn,,}" != "n" ]] || return

    local app_dir="$HOME/.local/share/applications"
    local auto_dir="$HOME/.config/autostart"
    local desk_dir
    desk_dir="${XDG_DESKTOP_DIR:-$HOME/Desktop}"
    mkdir -p "$app_dir" "$auto_dir"

    # Exec path must be double-quoted in the .desktop file to handle spaces.
    local entry
    entry="$(cat <<ENTRY
[Desktop Entry]
Name=Enshrouded Server Manager
Comment=Manage your Enshrouded dedicated server
Exec="${INSTALL_DIR}/launch.sh"
Icon=applications-games
Terminal=false
Type=Application
Categories=Game;
StartupNotify=false
ENTRY
)"

    echo "$entry" > "$app_dir/enshrouded-manager.desktop"
    echo "$entry" > "$auto_dir/enshrouded-manager.desktop"
    chmod +x "$app_dir/enshrouded-manager.desktop"

    # Desktop icon
    if [[ -d "$desk_dir" ]]; then
        echo "$entry" > "$desk_dir/enshrouded-manager.desktop"
        chmod +x "$desk_dir/enshrouded-manager.desktop"
        # Mark as trusted on GNOME so the icon is launchable without a dialog.
        if command -v gio &>/dev/null; then
            gio set "$desk_dir/enshrouded-manager.desktop" metadata::trusted true 2>/dev/null || true
        fi
        success "Desktop icon created at: $desk_dir/enshrouded-manager.desktop"
    else
        warn "Desktop directory not found ($desk_dir) — skipping desktop icon."
    fi

    success "App menu entry and autostart created."
}

# ---------------------------------------------------------------------------
# Port forwarding instructions
# ---------------------------------------------------------------------------
print_port_info() {
    local local_ip
    local_ip=$(timeout 3 hostname -I 2>/dev/null | awk '{print $1}') || local_ip="<your local IP>"

    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}  IMPORTANT: Router / Firewall Configuration Required${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "  Players outside your local network can only connect if you forward"
    echo "  these ports on your router to this machine:"
    echo ""
    echo -e "    ${CYAN}15636  UDP${NC}  — Game traffic"
    echo -e "    ${CYAN}15637  UDP${NC}  — Steam server query"
    echo ""
    echo "  How to set up port forwarding:"
    echo "    1. Log in to your router's admin page (usually http://192.168.1.1"
    echo "       or http://192.168.0.1 — check your router's label)."
    echo "    2. Navigate to 'Port Forwarding', 'Virtual Server', or 'NAT'."
    echo "    3. Add two UDP rules for ports 15636 and 15637, pointing to:"
    echo -e "       ${CYAN}${local_ip}${NC}  (this machine's current local IP)"
    echo "    4. For a permanent setup, assign this machine a static local IP"
    echo "       (DHCP reservation in your router) so the rules stay valid."
    echo ""
    echo "  If you also have a software firewall, open the ports:"
    echo -e "    ${CYAN}firewalld:${NC}"
    echo "      sudo firewall-cmd --add-port=15636/udp --add-port=15637/udp --permanent"
    echo "      sudo firewall-cmd --reload"
    echo -e "    ${CYAN}ufw:${NC}"
    echo "      sudo ufw allow 15636/udp && sudo ufw allow 15637/udp"
    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║        Enshrouded Dedicated Server Manager — Installer               ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    check_prerequisites
    choose_install_dir
    create_dirs
    install_steamcmd
    download_server
    patch_server_exe
    install_ge_proton
    setup_manager
    setup_desktop
    print_port_info

    echo ""
    success "Installation complete!"
    echo ""
    echo "  To launch the server manager:"
    echo -e "    ${CYAN}${INSTALL_DIR}/launch.sh${NC}"
    echo ""
    echo "  On first launch, go to the Configuration tab to set your server"
    echo "  name and password, then press Start on the Server tab."
    echo ""
}

main "$@"
