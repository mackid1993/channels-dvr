#!/bin/bash
# =============================================================================
# Channels DVR Setup Script
# Downloads the Channels DVR binary directly from CDN
# =============================================================================

set -e

CHANNELS_DIR="${CHANNELS_DVR_DIR:-/channels-dvr}"
HOST="https://cdn.channelsdvr.net/dvr"

# Get OS and arch
os=$(uname -s | tr '[A-Z]' '[a-z]')
arch=$(uname -m)

# Map architecture to Channels naming
case "${arch}" in
    x86_64)
        arch="x86_64"
        ;;
    aarch64)
        arch="aarch64"
        ;;
    armv7l)
        arch="arm"
        ;;
esac

PLATFORM="${os}-${arch}"
echo "Platform: ${PLATFORM}"
echo "Install directory: ${CHANNELS_DIR}"

# Create directory if it doesn't exist
mkdir -p "${CHANNELS_DIR}"
cd "${CHANNELS_DIR}"

# Get latest version
echo "Fetching latest version..."
VERSION=$(curl -fsSL "${HOST}/latest.txt")

if [ -z "${VERSION}" ]; then
    echo "ERROR: Could not get latest version"
    exit 1
fi

echo "Latest version: ${VERSION}"

# Download URL
DOWNLOAD_URL="${HOST}/${PLATFORM}/channels-dvr-${VERSION}.tar.gz"
echo "Downloading from: ${DOWNLOAD_URL}"

# Download and extract
curl -fL "${DOWNLOAD_URL}" | tar xz

# Make executable
chmod +x channels-dvr

echo "Channels DVR ${VERSION} installation complete!"
ls -la "${CHANNELS_DIR}/channels-dvr"