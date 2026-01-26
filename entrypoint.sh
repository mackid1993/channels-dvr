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

# Create group if it doesn't exist
if ! getent group channels > /dev/null 2>&1; then
    groupadd -o -g "$PGID" channels
else
    groupmod -o -g "$PGID" channels 2>/dev/null || true
fi

# Create user if it doesn't exist
if ! getent passwd channels > /dev/null 2>&1; then
    useradd -o -u "$PUID" -g "$PGID" -d /channels-dvr -s /bin/bash channels
else
    usermod -o -u "$PUID" -g "$PGID" channels 2>/dev/null || true
fi

# Set ownership of directories
echo "Setting permissions..."
chown -R channels:channels /channels-dvr
chown channels:channels /shares/DVR 2>/dev/null || true

# Download Channels DVR if not present (first run only)
if [ ! -f /channels-dvr/channels-dvr/latest/channels-dvr ]; then
    echo "Channels DVR not found, downloading..."
    cd /channels-dvr
    gosu channels curl -f -s https://getchannels.com/dvr/setup.sh | DOWNLOAD_ONLY=1 gosu channels sh
    echo "Download complete!"
else
    echo "Channels DVR found, skipping download"
fi

# Verify binary exists
if [ ! -f /channels-dvr/channels-dvr/latest/channels-dvr ]; then
    echo "FATAL: Channels DVR binary not found!"
    exit 1
fi

# Check for Intel GPU
if [ -e /dev/dri ]; then
    echo "Intel GPU detected at /dev/dri"
fi

# Check for NVIDIA GPU
if command -v nvidia-smi &> /dev/null; then
    echo "NVIDIA GPU detected"
fi

# TCP buffer tuning for stable streaming (may require host network mode)
# These settings help prevent buffer underruns during streaming
sysctl -w net.core.rmem_max=16777216 2>/dev/null && echo "TCP rmem_max set to 16MB" || true
sysctl -w net.core.wmem_max=16777216 2>/dev/null && echo "TCP wmem_max set to 16MB" || true
sysctl -w net.ipv4.tcp_rmem="4096 87380 16777216" 2>/dev/null && echo "TCP rmem tuned" || true
sysctl -w net.ipv4.tcp_wmem="4096 65536 16777216" 2>/dev/null && echo "TCP wmem tuned" || true

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Starting Channels DVR Server"
echo "  Web UI: http://localhost:8089"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Run the command as the channels user with high I/O priority
cd /channels-dvr
# ionice: best-effort I/O class (2), highest priority (0) - WORKS in containers
# nice: higher CPU priority (-10) - requires CAP_SYS_NICE, may not apply
exec ionice -c 2 -n 0 nice -n -10 gosu channels "$@"
