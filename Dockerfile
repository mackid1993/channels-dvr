# Channels DVR Docker Container
# Features:
#   - Proper PUID/PGID user mapping (no root-owned files)
#   - Intel QuickSync support
#   - NVIDIA GPU support (via nvidia-container-toolkit)
#   - TVE (TV Everywhere) with Google Chrome

FROM debian:bookworm-slim

# Build args for versioning
ARG BUILD_DATE
ARG VERSION

LABEL maintainer="mackid1993"
LABEL org.opencontainers.image.title="Channels DVR"
LABEL org.opencontainers.image.description="Channels DVR Server with TVE support and hardware transcoding"
LABEL org.opencontainers.image.source="https://github.com/mackid1993/channels-dvr"
LABEL org.opencontainers.image.version="${VERSION}"
LABEL org.opencontainers.image.created="${BUILD_DATE}"

# Environment variables
ENV PUID=99
ENV PGID=100
ENV TZ=America/New_York

# NVIDIA driver capabilities
ENV NVIDIA_DRIVER_CAPABILITIES="compute,video,utility"

# Install tini and core dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    tini \
    curl \
    ca-certificates \
    wget \
    gnupg \
    xvfb \
    ffmpeg \
    iproute2 \
    gosu \
    && rm -rf /var/lib/apt/lists/*

# Install Google Chrome for TVE (amd64 only)
RUN if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
    curl -fsSL https://dl-ssl.google.com/linux/linux_signing_key.pub | \
    gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg && \
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" > \
    /etc/apt/sources.list.d/google-chrome.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends google-chrome-stable && \
    rm -rf /var/lib/apt/lists/*; \
    fi

# Install Intel GPU drivers for QuickSync (amd64 only)
RUN if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
    wget -qO - https://repositories.intel.com/gpu/intel-graphics.key | \
    gpg --dearmor -o /usr/share/keyrings/intel-graphics.gpg && \
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/intel-graphics.gpg] https://repositories.intel.com/gpu/ubuntu jammy unified" > \
    /etc/apt/sources.list.d/intel-gpu.list && \
    apt-get update && apt-get install -y --no-install-recommends \
    intel-media-va-driver-non-free \
    libmfx-gen1 \
    libvpl2 && \
    rm -rf /var/lib/apt/lists/*; \
    fi

# NVIDIA: Drivers injected at runtime via --gpus all or --runtime=nvidia

# Create directories
RUN mkdir -p /channels-dvr /shares/DVR

# Copy entrypoint script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

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

ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
CMD ["/channels-dvr/channels-dvr/latest/channels-dvr"]
