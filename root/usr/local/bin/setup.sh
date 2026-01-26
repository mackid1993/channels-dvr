#!/bin/bash
# =============================================================================
# Channels DVR Setup Script
# Downloads and installs the Channels DVR binary using official method
# =============================================================================

set -e

CHANNELS_DIR="${CHANNELS_DVR_DIR:-/channels-dvr}"

echo "Install directory: ${CHANNELS_DIR}"

# Create directory if it doesn't exist
mkdir -p "${CHANNELS_DIR}"
cd "${CHANNELS_DIR}"

# Use official Channels setup script
echo "Downloading Channels DVR using official installer..."
curl -f -s https://getchannels.com/dvr/setup.sh | sh

echo "Channels DVR installation complete!"