#!/bin/bash
set -euo pipefail

echo "[+] PaperCut VM setup starting..."

SHARED_FOLDER="/mnt/papercut_share"
GUEST_USER="osboxes"
GUEST_PASS="osboxes.org"

# ----------------------------
# Installer path (FIXED)
# ----------------------------
INSTALLER_SRC="$SHARED_FOLDER/files/pcng-setup-19.2.7.62200-linux-x64.sh"
INSTALLER="/tmp/pcng-setup.sh"

if [[ ! -f "$INSTALLER_SRC" ]]; then
    echo "[!] Installer not found at: $INSTALLER_SRC"
    exit 1
fi

cp "$INSTALLER_SRC" "$INSTALLER"
chmod +x "$INSTALLER"

# ----------------------------
# Dependencies (minimal + safe)
# ----------------------------
echo "[+] Installing dependencies..."
echo "$GUEST_PASS" | sudo -S apt-get update -y
echo "$GUEST_PASS" | sudo -S apt-get install -y \
    cups \
    printer-driver-cups-pdf \
    ghostscript \
    netcat-openbsd \
    virtualbox-guest-utils

# ----------------------------
# PaperCut user
# ----------------------------
if ! id papercut >/dev/null 2>&1; then
    echo "[+] Creating papercut user..."
    echo "$GUEST_PASS" | sudo -S useradd --system \
        --home-dir /home/papercut \
        --create-home \
        --shell /bin/bash \
        papercut
fi

# ----------------------------
# Install PaperCut (realistic handling)
# ----------------------------
echo "[+] Running PaperCut installer..."
echo "$GUEST_PASS" | sudo -Su papercut bash "$INSTALLER" --non-interactive

# Some installers require post-step script; only run if exists
if [[ -f /home/papercut/MUST-RUN-AS-ROOT ]]; then
    echo "[+] Running post-install root script..."
    echo "$GUEST_PASS" | sudo -S bash /home/papercut/MUST-RUN-AS-ROOT
fi

# ----------------------------
# Paths (guarded)
# ----------------------------
PC_HOME="/home/papercut/server"
BIN_DIR="$PC_HOME/bin/linux-x64"
CONF_FILE="$PC_HOME/server.properties"

# ----------------------------
# SSL config (only if tool exists)
# ----------------------------
if [[ -x "$BIN_DIR/create-ssl-keystore" ]]; then
    echo "$GUEST_PASS" | sudo -Su papercut "$BIN_DIR/create-ssl-keystore" -f -keystoreentry standard || true
fi

# ----------------------------
# Config tuning (safe edits)
# ----------------------------
if [[ -f "$CONF_FILE" ]]; then
    echo "$GUEST_PASS" | sudo -S sed -i 's/^server\.https\.port=.*/server.https.port=9192/' "$CONF_FILE" || true
    echo "$GUEST_PASS" | sudo -S sed -i 's/^server\.https\.enabled=.*/server.https.enabled=on/' "$CONF_FILE" || true
fi

# ----------------------------
# CUPS setup (VM-safe)
# ----------------------------
echo "[+] Configuring CUPS..."

echo "$GUEST_PASS" | sudo -S systemctl enable cups || true
echo "$GUEST_PASS" | sudo -S systemctl restart cups || true

lpadmin -p "Test_Printer" -v "file:/tmp/print_output" -m raw -E || true

if [[ -L /home/papercut/providers/print/linux-x64/cups-print-provider ]]; then
    echo "$GUEST_PASS" | sudo -S ln -sf \
        /home/papercut/providers/print/linux-x64/cups-print-provider \
        /usr/lib/cups/backend/papercut || true
fi

# ----------------------------
# PaperCut service handling (more robust)
# ----------------------------
echo "[+] Restarting PaperCut services (if installed)..."

echo "$GUEST_PASS" | sudo -S systemctl stop pc-app-server 2>/dev/null || true
echo "$GUEST_PASS" | sudo -S systemctl start pc-app-server 2>/dev/null || true

# ----------------------------
# Enable features (ONLY if db-tools exists)
# ----------------------------
DB_TOOLS="/home/papercut/server/bin/linux-x64/db-tools"

if [[ -x "$DB_TOOLS" ]]; then
    echo "[+] Enabling config flags..."
    echo "y" | echo "$GUEST_PASS" | sudo -S -u papercut "$DB_TOOLS" set-config print-and-device.script.enabled Y || true
    echo "y" | echo "$GUEST_PASS" | sudo -S -u papercut "$DB_TOOLS" set-config print.script.sandboxed N || true
fi

# ----------------------------
# Wait for service
# ----------------------------
echo "[+] Waiting for PaperCut web interface..."

for i in {1..60}; do
    if nc -z localhost 9191; then
        echo "[✔] PaperCut is up at http://localhost:9191/app"
        exit 0
    fi
    sleep 3
done

echo "[!] Timeout waiting for PaperCut"
exit 1