#!/usr/bin/env bash
# TabCircle Linux Installer & Autostart Setup
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
AUTOSTART_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"
DESKTOP_FILE="$AUTOSTART_DIR/tabcircle.desktop"
PID_FILE="/tmp/tabcircle_helper.pid"
LOG_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/tabcircle"
LOG_FILE="$LOG_DIR/helper.log"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/tabcircle"
CONFIG_FILE="$CONFIG_DIR/config.json"

usage() {
    echo "Usage: $0 [--install] [--uninstall] [--restart] [--status] [--low-resource]"
    echo "  --install       Install dependencies and register autostart (default)"
    echo "  --low-resource  Configure low-resource / favicon-only mode (minimal RAM/CPU)"
    echo "  --restart       Restart running helper daemon"
    echo "  --uninstall     Remove autostart and terminate running helper"
    echo "  --status        Check if helper is running and autostart is active"
    exit 1
}

# Accurate helper PID check (ignores editors, grep, py_compile)
get_helper_pid() {
    if [ -f "$PID_FILE" ]; then
        local pid
        pid="$(cat "$PID_FILE" 2>/dev/null || true)"
        if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
            if grep -q -a -E "python.*app\.py" "/proc/$pid/cmdline" 2>/dev/null; then
                echo "$pid"
                return 0
            fi
        fi
    fi
    # Fallback to strict pgrep matching python interpreter running app.py
    local pgrep_pid
    pgrep_pid="$(pgrep -f "^python[0-9.]* .*linux-helper/app\.py" 2>/dev/null | head -n 1 || true)"
    if [ -n "$pgrep_pid" ]; then
        echo "$pgrep_pid"
        return 0
    fi
    return 1
}

stop_helper() {
    local pid
    pid="$(get_helper_pid || true)"
    if [ -n "$pid" ]; then
        kill "$pid" 2>/dev/null || true
        sleep 0.3
        if [ -d "/proc/$pid" ]; then
            kill -9 "$pid" 2>/dev/null || true
        fi
        echo "✓ Terminated TabCircle helper process (PID $pid)."
    else
        echo "✓ No active TabCircle helper process found."
    fi
    rm -f "$PID_FILE" 2>/dev/null || true
}

MODE="--install"
LOW_RESOURCE=false

for arg in "$@"; do
    case "$arg" in
        --low-resource)
            LOW_RESOURCE=true
            ;;
        --restart)
            MODE="--restart"
            ;;
        --uninstall)
            MODE="--uninstall"
            ;;
        --status)
            MODE="--status"
            ;;
        --install)
            MODE="--install"
            ;;
        -h|--help)
            usage
            ;;
        *)
            usage
            ;;
    esac
done

case "$MODE" in
    --restart)
        echo "==> Restarting TabCircle Helper..."
        stop_helper
        echo "==> Starting TabCircle helper daemon in background..."
        nohup python3 "$PROJECT_DIR/linux-helper/app.py" >/dev/null 2>&1 &
        sleep 0.5
        started_pid="$(get_helper_pid || true)"
        if [ -n "$started_pid" ]; then
            echo "✓ TabCircle helper restarted successfully (PID $started_pid)."
        else
            echo "Warning: Helper daemon may not have started. Check logs: $LOG_FILE"
        fi
        exit 0
        ;;
    --uninstall)
        echo "==> Uninstalling TabCircle Helper..."
        if [ -f "$DESKTOP_FILE" ]; then
            rm -f "$DESKTOP_FILE"
            echo "✓ Removed $DESKTOP_FILE"
        fi
        stop_helper
        echo "TabCircle Linux Helper uninstalled."
        exit 0
        ;;
    --status)
        echo "==> TabCircle Status:"
        if [ -f "$DESKTOP_FILE" ]; then
            echo "✓ Autostart desktop file: Present ($DESKTOP_FILE)"
        else
            echo "✗ Autostart desktop file: Not installed"
        fi
        helper_pid="$(get_helper_pid || true)"
        if [ -n "$helper_pid" ]; then
            echo "✓ Helper daemon: Running (PID $helper_pid)"
        else
            echo "✗ Helper daemon: Not running"
        fi
        if [ -f "$CONFIG_FILE" ] && grep -q '"low_resource_mode":\s*true' "$CONFIG_FILE" 2>/dev/null; then
            echo "  Mode: Low-resource (favicon-only, screenshots disabled)"
        else
            echo "  Mode: Standard (rich visual screenshot cards)"
        fi
        if [ -f "$LOG_FILE" ]; then
            echo "  Log file: $LOG_FILE (last 3 lines:)"
            tail -n 3 "$LOG_FILE" 2>/dev/null | sed 's/^/    /' || true
        fi
        exit 0
        ;;
    --install)
        ;;
esac

echo "========================================="
echo "  TabCircle Linux Helper Installation   "
echo "========================================="

# 1. Verify Python 3
if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: python3 is not installed. Please install Python 3 and re-run."
    exit 1
fi

# 2. Check dependencies (accommodate PEP 668 externally-managed environments)
echo "==> Checking dependencies..."
if python3 -c "import PyQt6, Xlib, websockets" >/dev/null 2>&1; then
    echo "✓ Python dependencies satisfied (PyQt6, python-xlib, websockets)."
else
    echo "==> Some Python dependencies are missing. Attempting installation..."
    REQ_FILE="$PROJECT_DIR/linux-helper/requirements.txt"
    if [ ! -f "$REQ_FILE" ]; then
        echo "Error: requirements file not found at $REQ_FILE"
        exit 1
    fi

    # Try apt on Debian/Ubuntu/Mint first to avoid PEP 668 errors
    if command -v apt-get >/dev/null 2>&1 && [ -w /var/lib/dpkg/lock-frontend 2>/dev/null ]; then
        apt-get install -y python3-pyqt6 python3-xlib python3-websockets || true
    elif command -v sudo >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
        echo "Installing system packages via apt..."
        sudo apt-get update -qq && sudo apt-get install -y -qq python3-pyqt6 python3-xlib python3-websockets || true
    fi

    # If still not satisfied, attempt user pip with break-system-packages fallback
    if ! python3 -c "import PyQt6, Xlib, websockets" >/dev/null 2>&1; then
        if command -v pip3 >/dev/null 2>&1; then
            pip3 install --user -r "$REQ_FILE" 2>/dev/null || \
            pip3 install --break-system-packages --user -r "$REQ_FILE" || true
        fi
    fi

    # Final check
    if ! python3 -c "import PyQt6, Xlib, websockets" >/dev/null 2>&1; then
        echo "Error: Failed to install required Python packages."
        echo "Please install them using your system package manager:"
        echo "  sudo apt install python3-pyqt6 python3-xlib python3-websockets"
        exit 1
    fi
    echo "✓ Python dependencies installed successfully."
fi

# 3. Configure settings & register autostart entry
if [ "$LOW_RESOURCE" = true ]; then
    mkdir -p "$CONFIG_DIR"
    cat << EOF > "$CONFIG_FILE"
{
  "low_resource_mode": true
}
EOF
    echo "✓ Configured low-resource mode in $CONFIG_FILE"
fi

echo "==> Registering session autostart..."
mkdir -p "$AUTOSTART_DIR"
mkdir -p "$LOG_DIR"

cat << EOF > "$DESKTOP_FILE"
[Desktop Entry]
Type=Application
Name=TabCircle Helper
Comment=Native companion daemon for TabCircle MRU browser tab switcher
Exec=python3 "$PROJECT_DIR/linux-helper/app.py"
Icon=$PROJECT_DIR/assets/icon-128.png
Terminal=false
Categories=Utility;
X-GNOME-Autostart-enabled=true
EOF

chmod 644 "$DESKTOP_FILE"
echo "✓ Created autostart entry: $DESKTOP_FILE"

# 4. Start helper in background if not already running
active_pid="$(get_helper_pid || true)"
if [ -n "$active_pid" ] && [ "$LOW_RESOURCE" = true ]; then
    echo "Restarting running helper (PID $active_pid) to apply low-resource mode..."
    stop_helper
    active_pid=""
fi

if [ -n "$active_pid" ]; then
    echo "✓ TabCircle helper is already running (PID $active_pid)."
else
    echo "==> Starting TabCircle helper daemon in background..."
    nohup python3 "$PROJECT_DIR/linux-helper/app.py" >/dev/null 2>&1 &
    sleep 0.5
    started_pid="$(get_helper_pid || true)"
    if [ -n "$started_pid" ]; then
        echo "✓ TabCircle helper started successfully (PID $started_pid)."
    else
        echo "Warning: Helper daemon may not have started. Check logs: $LOG_FILE"
    fi
fi

echo ""
echo "Installation complete!"
echo "- Browser extension: Unzip 'TabCircle-Extension.zip', then in chrome://extensions click 'Load unpacked'"
echo "- Helper daemon: Runs automatically on desktop login"
echo "- Helper controls: Run '$0 --status' or '$0 --uninstall'"
echo "- Helper logs: $LOG_FILE (automatic rotation up to 15MB)"
echo "- Tab cache: /tmp/tabcircle/tabs_cache.json"
