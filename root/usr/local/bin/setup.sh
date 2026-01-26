#!/bin/bash
# =============================================================================
# Channels DVR Setup Script
# Downloads the Channels DVR binary directly
# =============================================================================

set -e

CHANNELS_DIR="${CHANNELS_DVR_DIR:-/channels-dvr}"
ARCH=$(uname -m)

# Map architecture
case "${ARCH}" in
    x86_64)
        PLATFORM="linux-x86_64"
        ;;
    aarch64|arm64)
        PLATFORM="linux-aarch64"
        ;;
    armv7l)
        PLATFORM="linux-arm"
        ;;
    *)
        echo "Unsupported architecture: ${ARCH}"
        exit 1
        ;;
esac

echo "Platform: ${PLATFORM}"
echo "Install directory: ${CHANNELS_DIR}"

# Create directory if it doesn't exist
mkdir -p "${CHANNELS_DIR}"
cd "${CHANNELS_DIR}"

# Get latest version info
echo "Fetching latest version..."
LATEST_URL="https://getchannels.com/dvr/latest?os=${PLATFORM}"
DOWNLOAD_URL=$(curl -fsSL "${LATEST_URL}")

if [ -z "${DOWNLOAD_URL}" ]; then
    echo "ERROR: Could not get download URL"
    exit 1
fi

echo "Downloading from: ${DOWNLOAD_URL}"

# Download the binary
curl -fL -o channels-dvr.new "${DOWNLOAD_URL}"

# Make executable
chmod +x channels-dvr.new

# Replace existing binary
if [ -f channels-dvr ]; then
    echo "Replacing existing binary..."
    rm -f channels-dvr.old
    mv channels-dvr channels-dvr.old 2>/dev/null || true
fi

mv channels-dvr.new channels-dvr

echo "Channels DVR installation complete!"
ls -la "${CHANNELS_DIR}/channels-dvr"

