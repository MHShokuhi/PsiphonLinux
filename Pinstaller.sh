#! /bin/bash

set -e

# Variables
INSTALL_DIR="/etc/psiphon"
CONFIG_URL="https://raw.githubusercontent.com/090ebier/PsiphonLinux/main/psiphon.config"
STARTUP_SCRIPT_URL="https://raw.githubusercontent.com/090ebier/PsiphonLinux/main/psiphon"
SERVICE_FILE="/etc/systemd/system/psiphon.service"

# Detect architecture -> choose binary
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64)
    BINARY_NAME="psiphon-tunnel-core-x86_64"
    BINARY_URL="https://raw.githubusercontent.com/090ebier/PsiphonLinux/refs/heads/main/psiphon-tunnel-core-x86_64"
    ;;
  aarch64|arm64)
    BINARY_NAME="psiphon-tunnel-core-arm64"
    BINARY_URL="https://raw.githubusercontent.com/090ebier/PsiphonLinux/refs/heads/main/psiphon-tunnel-core-arm64"
    ;;
  *)
    echo "ERROR: Unsupported architecture: $ARCH"
    exit 1
    ;;
esac

echo "Detected architecture: $ARCH"
echo "Using binary: $BINARY_NAME"

# Create necessary directories
mkdir -p "$INSTALL_DIR"

# Download necessary scripts and files
echo "Starting downloads..."
wget -O "$INSTALL_DIR/$BINARY_NAME" "$BINARY_URL" --quiet
wget -O "$INSTALL_DIR/psiphon.config" "$CONFIG_URL" --quiet
wget -O "/usr/bin/psiphon" "$STARTUP_SCRIPT_URL" --quiet
echo "Downloads finished."

# Set permissions
chmod +x "$INSTALL_DIR/$BINARY_NAME"
chmod +x /usr/bin/psiphon

# Create systemd service file
echo "Creating Psiphon service..."
cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=Psiphon Service
After=network.target

[Service]
ExecStart=$INSTALL_DIR/$BINARY_NAME -config $INSTALL_DIR/psiphon.config
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd to recognize the new service
systemctl daemon-reload

# Enable and start the Psiphon service
systemctl enable psiphon
systemctl restart psiphon

# Post-install checks
echo "Running post-install checks..."

if test -f "$INSTALL_DIR/$BINARY_NAME"; then
    echo "Psiphon binary found."
else
    echo "ERROR: Psiphon binary not found!"
fi

if test -f "$INSTALL_DIR/psiphon.config"; then
    echo "Psiphon configuration found."
else
    echo "ERROR: Psiphon configuration not found!"
fi

if test -f /usr/bin/psiphon; then
    echo "Psiphon startup script found."
else
    echo "ERROR: Psiphon startup script not found!"
fi

if systemctl is-active --quiet psiphon; then
    echo "Psiphon service is running."
else
    echo "ERROR: Psiphon service is not running!"
    systemctl status psiphon --no-pager || true
    journalctl -u psiphon --no-pager -n 50 || true
fi

# Finish installation
echo "Installation completed. Psiphon service is now running in the background."
echo "You can manage the service with 'sudo systemctl [start|stop|status] psiphon'."