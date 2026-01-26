#!/bin/sh
# =============================================================================
# Channels DVR Setup Script
# Downloads and runs the official installer from getchannels.com
# =============================================================================

set -e

CHANNELS_DIR="${CHANNELS_DVR_DIR:-/channels-dvr}"

echo "Install directory: ${CHANNELS_DIR}"

# Create directory if it doesn't exist
mkdir -p "${CHANNELS_DIR}"
cd "${CHANNELS_DIR}"

# Download and run the official Channels DVR installer
echo "Running official Channels DVR installer..."
curl -f -s https://getchannels.com/dvr/setup.sh | sh

echo "Channels DVR installation complete!"
ls -la "${CHANNELS_DIR}/channels-dvr"