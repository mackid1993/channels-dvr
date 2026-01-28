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
mkdir -p /channels-dvr/data
chown -R channels:channels /channels-dvr
chown channels:channels /shares/DVR 2>/dev/null || true

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
fi

# Check for NVIDIA GPU
if command -v nvidia-smi &> /dev/null; then
    echo "NVIDIA GPU detected"
fi

# TCP timeout hardening (opt-in)
# Reduces tcp_retries2 to clean up dead connections faster (~51sec vs ~15min)
# Note: With --net=host this affects the host. Requires --privileged for /proc/sys write access.
SYSCTL_MODIFIED=false
ORIGINAL_TCP_RETRIES2=15
if [ "${TCP_TUNING:-0}" = "1" ]; then
    ORIGINAL_TCP_RETRIES2=$(sysctl -n net.ipv4.tcp_retries2 2>/dev/null || echo "15")
    echo "TCP tuning enabled (tcp_retries2=${TCP_RETRIES2:-8})"
    if sysctl -w net.ipv4.tcp_retries2="${TCP_RETRIES2:-8}" > /dev/null 2>&1; then
        SYSCTL_MODIFIED=true
        echo "  tcp_retries2 set to ${TCP_RETRIES2:-8} (was $ORIGINAL_TCP_RETRIES2)"
    else
        echo "  WARNING: Could not set tcp_retries2. /proc/sys is read-only."
        echo "  Option 1: Run container with --privileged"
        echo "  Option 2: Set on host: sysctl -w net.ipv4.tcp_retries2=${TCP_RETRIES2:-8}"
    fi
fi

# Build DVR arguments (matching official FancyBits run.sh)
DVR_ARGS="-dir /channels-dvr/data"
if [ -n "$CHANNELS_HOST" ]; then
    DVR_ARGS="$DVR_ARGS -host $CHANNELS_HOST"
fi
if [ -n "$CHANNELS_PORT" ]; then
    DVR_ARGS="$DVR_ARGS -port $CHANNELS_PORT"
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Starting Channels DVR Server"
echo "  Web UI: http://localhost:8089"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Disable set -e for signal handling (wait returns non-zero on signal)
set +e

# Clean up TCP tuning on shutdown, then forward signal to DVR
cleanup() {
    if [ "$SYSCTL_MODIFIED" = "true" ]; then
        echo "Restoring tcp_retries2 to $ORIGINAL_TCP_RETRIES2..."
        sysctl -w net.ipv4.tcp_retries2="$ORIGINAL_TCP_RETRIES2" || true
    fi
    kill -TERM "$DVR_PID" 2>/dev/null
}
trap cleanup SIGTERM SIGINT

# Run DVR from data directory (matching official FancyBits layout)
cd /channels-dvr/data
gosu channels ../latest/channels-dvr $DVR_ARGS &
DVR_PID=$!
wait "$DVR_PID"
exit $?
