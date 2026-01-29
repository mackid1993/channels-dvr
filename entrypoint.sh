#!/bin/bash
set -e

# =============================================================================
# Channels DVR Entrypoint Script
# Handles PUID/PGID user mapping and first-run setup
# =============================================================================

PUID=${PUID:-99}
PGID=${PGID:-100}

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Channels DVR - Starting"
echo "  UID: $PUID | GID: $PGID"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Create/recreate group with correct GID
groupdel channels 2>/dev/null || true
groupadd -o -g "$PGID" channels

# Create user if it doesn't exist
if ! getent passwd channels > /dev/null 2>&1; then
    useradd -o -u "$PUID" -g "$PGID" -d /channels-dvr -s /bin/bash channels 2>/dev/null
else
    usermod -o -u "$PUID" -g "$PGID" channels 2>/dev/null || true
fi

# Create directories and set ownership only on first run or PUID/PGID change
mkdir -p /channels-dvr/data
CURRENT_UID=$(stat -c %u /channels-dvr/data 2>/dev/null || echo "")
CURRENT_GID=$(stat -c %g /channels-dvr/data 2>/dev/null || echo "")
if [ ! -f /channels-dvr/data/.initialized ] || [ "$CURRENT_UID" != "$PUID" ] || [ "$CURRENT_GID" != "$PGID" ]; then
    echo "Setting permissions (first run or PUID/PGID change detected)..."
    chown channels:channels /channels-dvr /channels-dvr/data 2>/dev/null || true
    chown channels:channels /shares/DVR 2>/dev/null || true
    touch /channels-dvr/data/.initialized
    chown channels:channels /channels-dvr/data/.initialized
fi

# Download Channels DVR if not present (first run only)
if [ ! -f /channels-dvr/latest/channels-dvr ]; then
    echo "Channels DVR not found, downloading..."
    cd /
    gosu channels curl -f -s https://getchannels.com/dvr/setup.sh | DOWNLOAD_ONLY=1 gosu channels sh
    echo "Download complete!"
else
    echo "Channels DVR found, skipping download"
fi

# Verify binary exists
if [ ! -f /channels-dvr/latest/channels-dvr ]; then
    echo "FATAL: Channels DVR binary not found!"
    exit 1
fi

# Check for Intel GPU
if [ -e /dev/dri ]; then
    echo "Intel GPU detected at /dev/dri"
    for grp in video render; do
        getent group "$grp" >/dev/null && usermod -aG "$grp" channels 2>/dev/null || true
    done
fi

# Check for NVIDIA GPU
if [ -e /dev/nvidia0 ]; then
    echo "NVIDIA GPU detected"
    getent group video >/dev/null && usermod -aG video channels 2>/dev/null || true
fi

# Build DVR arguments (matching official FancyBits run.sh)
DVR_ARGS=(-dir /channels-dvr/data)
if [ -n "$CHANNELS_HOST" ]; then
    DVR_ARGS+=(-host "$CHANNELS_HOST")
fi
if [ -n "$CHANNELS_PORT" ]; then
    DVR_ARGS+=(-port "$CHANNELS_PORT")
fi

# Get server IP address
SERVER_IP=$(hostname -I | awk '{print $1}')

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Starting Channels DVR Server"
echo "  Web UI: http://${SERVER_IP:-localhost}:8089"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Set umask (default 0000 for Unraid SMB compatibility)
umask "${UMASK:-0000}"

# Run DVR from data directory (matching official FancyBits layout)
cd /channels-dvr/data
exec gosu channels ../latest/channels-dvr "${DVR_ARGS[@]}"
