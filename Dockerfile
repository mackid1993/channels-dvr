# Channels DVR Docker Container (amd64 only)
# Features:
#   - Proper PUID/PGID user mapping (no root-owned files)
#   - Intel QuickSync support
#   - NVIDIA GPU support (via nvidia-container-toolkit)
#   - TVE (TV Everywhere) with Google Chrome

FROM debian:bookworm-slim

ARG BUILD_DATE
ARG VERSION

LABEL maintainer="mackid1993"
LABEL org.opencontainers.image.title="Channels DVR"
LABEL org.opencontainers.image.description="Channels DVR Server with TVE support and hardware transcoding"
LABEL org.opencontainers.image.source="https://github.com/mackid1993/channels-dvr"
LABEL org.opencontainers.image.version="${VERSION}"
LABEL org.opencontainers.image.created="${BUILD_DATE}"

ENV PUID=99
ENV PGID=100
ENV TZ=America/New_York
# NVIDIA GPU support (requires --runtime=nvidia or --gpus all)
ENV NVIDIA_VISIBLE_DEVICES=all
ENV NVIDIA_DRIVER_CAPABILITIES=compute,video,utility

# Install tini and core dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    tini curl ca-certificates wget gnupg xvfb ffmpeg iproute2 gosu \
    && rm -rf /var/lib/apt/lists/*

# Install Google Chrome for TVE
RUN curl -fsSL https://dl-ssl.google.com/linux/linux_signing_key.pub | \
    gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg && \
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" > \
    /etc/apt/sources.list.d/google-chrome.list && \
    apt-get update && apt-get install -y --no-install-recommends google-chrome-stable && \
    rm -rf /var/lib/apt/lists/* && \
    mv /usr/bin/google-chrome-stable /usr/bin/google-chrome-stable-real && \
    printf '#!/bin/bash\nexec /usr/bin/google-chrome-stable-real --no-sandbox "$@"\n' > /usr/bin/google-chrome-stable && \
    chmod +x /usr/bin/google-chrome-stable

# Install Intel GPU drivers for QuickSync
RUN wget -qO - https://repositories.intel.com/gpu/intel-graphics.key | \
    gpg --dearmor -o /usr/share/keyrings/intel-graphics.gpg && \
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/intel-graphics.gpg] https://repositories.intel.com/gpu/debian bookworm unified" > \
    /etc/apt/sources.list.d/intel-gpu.list && \
    apt-get update && apt-get install -y --no-install-recommends \
    intel-media-va-driver-non-free libmfx-gen1 libvpl2 && \
    rm -rf /var/lib/apt/lists/*

# Create directories
RUN mkdir -p /channels-dvr/data /shares/DVR

# Copy entrypoint script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8089/tcp 1900/udp 5353/udp

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:8089/ || exit 1

VOLUME ["/channels-dvr", "/shares/DVR"]

ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
