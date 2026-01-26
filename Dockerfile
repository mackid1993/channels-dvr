# Channels DVR Docker Container
# Based on linuxserver.io Ubuntu base (stable, well-maintained)
# Features:
#   - Proper PUID/PGID user mapping (no root-owned files)
#   - Intel QuickSync support
#   - TVE (TV Everywhere) with Google Chrome

FROM ghcr.io/linuxserver/baseimage-ubuntu:noble

# Build args for versioning
ARG BUILD_DATE
ARG VERSION

LABEL maintainer="mackid1993"
LABEL org.opencontainers.image.title="Channels DVR"
LABEL org.opencontainers.image.description="Channels DVR Server with TVE support and Intel QuickSync"
LABEL org.opencontainers.image.source="https://github.com/mackid1993/channels-dvr"
LABEL org.opencontainers.image.version="${VERSION}"
LABEL org.opencontainers.image.created="${BUILD_DATE}"

# Environment variables - linuxserver.io style
ENV PUID=99
ENV PGID=100
ENV TZ=America/New_York
ENV UMASK=022

# Channels DVR paths
ENV CHANNELS_DVR_DIR=/channels-dvr
ENV CHANNELS_SHARES_DIR=/shares/DVR

# Install dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Core utilities
    curl \
    ca-certificates \
    wget \
    gnupg \
    # TVE support (xvfb for headless browser)
    xvfb \
    # Video processing
    ffmpeg \
    # Networking tools
    iproute2 \
    && rm -rf /var/lib/apt/lists/*

# Install Google Chrome for TVE (chromium in Noble is snap-only, doesn't work in Docker)
RUN curl -fsSL https://dl-ssl.google.com/linux/linux_signing_key.pub | \
    gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg && \
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" | \
    tee /etc/apt/sources.list.d/google-chrome.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends google-chrome-stable && \
    rm -rf /var/lib/apt/lists/*

# Add Intel GPU repository for QuickSync (amd64 only)
RUN if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
    wget -qO - https://repositories.intel.com/gpu/intel-graphics.key | \
    gpg --yes --dearmor --output /usr/share/keyrings/intel-graphics.gpg && \
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/intel-graphics.gpg] https://repositories.intel.com/gpu/ubuntu noble unified" | \
    tee /etc/apt/sources.list.d/intel-gpu-noble.list && \
    apt-get update && apt-get install -y --no-install-recommends \
    intel-media-va-driver-non-free \
    libmfx-gen1 \
    libvpl2 \
    vainfo && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*; \
    fi

# NVIDIA support: No packages needed in container!
# NVIDIA drivers are injected at runtime via --gpus all or --runtime=nvidia
# The host's libnvidia-encode/decode are mounted automatically by nvidia-container-toolkit

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

