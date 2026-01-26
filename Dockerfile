# Channels DVR Docker Container
# Based on linuxserver.io Ubuntu base (stable, well-maintained)
# Fixes:
#   - Proper PUID/PGID user mapping (no root-owned files)
#   - TCP connection tuning (fixes black screen / connection drops)
#   - Intel QuickSync support
#   - TVE (TV Everywhere) with Chromium

FROM ghcr.io/linuxserver/baseimage-ubuntu:noble

LABEL maintainer="mackid1993"
LABEL description="Channels DVR Server with TVE support, Intel QuickSync, and TCP fixes"
LABEL org.opencontainers.image.source="https://github.com/YOURUSER/channels-dvr-docker"

# Environment variables - linuxserver.io style
ENV PUID=99
ENV PGID=100
ENV TZ=America/New_York
ENV UMASK=022

# Channels DVR paths
ENV CHANNELS_DVR_DIR=/channels-dvr
ENV CHANNELS_SHARES_DIR=/shares/DVR

# TCP tuning
ENV TCP_WMEM_DEFAULT=1048576
ENV TCP_RMEM_DEFAULT=1048576

# Update on container start
ENV UPDATE_ON_START=true

# Install dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Core utilities
    curl \
    ca-certificates \
    wget \
    # TVE support (same as fancybits uses chromium + xvfb)
    chromium-browser \
    xvfb \
    # Video processing
    ffmpeg \
    # Intel QuickSync / VA-API
    intel-media-va-driver-non-free \
    vainfo \
    # Networking tools
    iproute2 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Create directories
RUN mkdir -p /channels-dvr /shares/DVR /data

# Copy root filesystem (s6-overlay scripts and setup.sh)
COPY root/ /

# Make scripts executable
RUN chmod +x /usr/local/bin/setup.sh \
    && chmod +x /etc/s6-overlay/s6-rc.d/init-channels-config/run \
    && chmod +x /etc/s6-overlay/s6-rc.d/svc-channels/run

# Expose ports
# 8089 - Web interface and API
# 1900 - SSDP/UPnP discovery
# 5353 - Bonjour/mDNS
EXPOSE 8089/tcp
EXPOSE 1900/udp
EXPOSE 5353/udp

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:8089/ || exit 1

# Volumes
VOLUME ["/channels-dvr", "/shares/DVR"]