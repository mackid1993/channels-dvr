#!/bin/sh
# =============================================================================
# Channels DVR Setup Script
# Based on official installer from getchannels.com
# =============================================================================

set -e

CHANNELS_DIR="${CHANNELS_DVR_DIR:-/channels-dvr}"
host="https://cdn.channelsdvr.net/dvr"

# Fetch function matching official installer
fetch() {
  curl -A "curl-dvr-installer-v1" -f -s "$1" -o "$2"
}

# Get OS and arch
os=$(uname -s | tr '[A-Z]' '[a-z]')
arch=$(uname -m)

echo "Platform: ${os}-${arch}"
echo "Install directory: ${CHANNELS_DIR}"

# Create directory if it doesn't exist
mkdir -p "${CHANNELS_DIR}"
cd "${CHANNELS_DIR}"

# Get latest version (or use DVR_VERSION env var if set)
echo "Fetching latest version..."
version=$(fetch "$host/latest.txt" - | tr -d '\r')

if [ -n "$DVR_VERSION" ]; then
  version="$DVR_VERSION"
fi

if [ -z "${version}" ]; then
    echo "ERROR: Could not get latest version"
    exit 1
fi

echo "Latest version: ${version}"

# Download URL - CDN always serves latest at fixed URL
download_url="${host}/${os}-${arch}/channels-dvr.tar.gz"
echo "Downloading version ${version} from: ${download_url}"

# Download and extract
fetch "${download_url}" - | tar xz

# Make executable
chmod +x channels-dvr

echo "Channels DVR ${version} installation complete!"
ls -la "${CHANNELS_DIR}/channels-dvr"