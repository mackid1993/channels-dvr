#!/bin/bash
# =============================================================================
# Channels DVR Setup Script
# Downloads and installs the Channels DVR binary
# =============================================================================

set -e

CHANNELS_DIR="${CHANNELS_DVR_DIR:-/channels-dvr}"
ARCH=$(uname -m)

# Map architecture
case "${ARCH}" in
    x86_64)
        PLATFORM="linux_amd64"
        ;;
    aarch64|arm64)
        PLATFORM="linux_arm64"
        ;;
    armv7l)
        PLATFORM="linux_arm"
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

# Determine version to download
if [ -n "${DVR_VERSION}" ]; then
    echo "Downloading specific version: ${DVR_VERSION}"
    URL="https://dl.getchannels.com/dvr/${PLATFORM}/channels-dvr-${DVR_VERSION}"
else
    echo "Downloading latest version..."
    URL="https://dl.getchannels.com/dvr/${PLATFORM}/channels-dvr"
fi

# Download the binary
echo "Downloading from: ${URL}"
curl -f -L -o channels-dvr.new "${URL}"

# Make executable
chmod +x channels-dvr.new

# Check if download-only mode
if [ "${DOWNLOAD_ONLY}" = "1" ]; then
    echo "Download complete (DOWNLOAD_ONLY mode)"
    mv channels-dvr.new channels-dvr
    exit 0
fi

# Replace existing binary
if [ -f channels-dvr ]; then
    echo "Replacing existing binary..."
    rm -f channels-dvr.old
    mv channels-dvr channels-dvr.old 2>/dev/null || true
fi

mv channels-dvr.new channels-dvr

echo "Channels DVR installation complete!"

