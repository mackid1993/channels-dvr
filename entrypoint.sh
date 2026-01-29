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

# Ensure group exists with correct GID
groupadd -o -g "$PGID" channels 2>/dev/null || groupmod -g "$PGID" channels 2>/dev/null || true

# Create or update user
if ! getent passwd channels > /dev/null 2>&1; then
    echo "Creating user channels with UID=$PUID GID=$PGID"
    useradd -o -u "$PUID" -g "$PGID" -d /channels-dvr -s /bin/bash channels >/dev/null 2>&1
else
    CURRENT_UID=$(id -u channels 2>/dev/null || echo "")
    CURRENT_GID=$(id -g channels 2>/dev/null || echo "")
    if [ "$CURRENT_UID" != "$PUID" ] || [ "$CURRENT_GID" != "$PGID" ]; then
        echo "Updating user channels: UID $CURRENT_UID->$PUID GID $CURRENT_GID->$PGID"
        usermod -o -u "$PUID" -g "$PGID" channels >/dev/null 2>&1 || true
    fi
fi

# Set ownership of directories (top-level only, no recursive scan)
mkdir -p /channels-dvr/data
CURRENT_UID=$(stat -c %u /channels-dvr/data 2>/dev/null || echo "")
CURRENT_GID=$(stat -c %g /channels-dvr/data 2>/dev/null || echo "")
if [ "$CURRENT_UID" != "$PUID" ] || [ "$CURRENT_GID" != "$PGID" ]; then
    echo "Setting permissions..."
    chown channels:channels /channels-dvr /channels-dvr/data 2>/dev/null || true
    chown channels:channels /shares/DVR 2>/dev/null || true
fi

# Verify write access
for dir in /channels-dvr /channels-dvr/data /shares/DVR; do
    if [ -d "$dir" ] && ! gosu channels touch "$dir/.write_test" 2>/dev/null; then
        echo "WARNING: Cannot write to $dir (check PUID/PGID)"
    else
        rm -f "$dir/.write_test" 2>/dev/null
    fi
done

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

# Build DVR arguments
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
echo "  Web UI: http://${SERVER_IP:-localhost}:${CHANNELS_PORT:-8089}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Set umask (default 0000 for Unraid SMB compatibility)
umask "${UMASK:-0000}"

# Run DVR
cd /channels-dvr/data
exec gosu channels ../latest/channels-dvr "${DVR_ARGS[@]}"
