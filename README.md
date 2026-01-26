# Channels DVR Docker

A modern Docker container for [Channels DVR Server](https://getchannels.com/dvr-server/) with fixes for TCP connection stability issues.

## Why This Exists

The official `fancybits/channels-dvr` container hasn't been updated in over a year and has TCP connection issues when running under Docker on Unraid (and possibly other platforms). Symptoms include:

- Black screen on Shield TV clients
- Connection resets after ~10 minutes
- `epoll_ctl EPERM` errors in logs
- EAGAIN errors on socket writes
- Connections getting stuck in ESTABLISHED state

This container uses a modern Ubuntu 24.04 base and applies TCP tuning to address these issues.

## Features

- **Ubuntu 24.04** base image (vs unknown/outdated base in official image)
- **TCP connection tuning** - Larger socket buffers, aggressive keepalives, shorter conntrack timeouts
- **TV Everywhere (TVE) support** - Chromium and xvfb included
- **Intel QuickSync support** - VA-API drivers for hardware transcoding
- **Multi-architecture** - Builds for amd64 and arm64
- **User mapping** - PUID/PGID support for proper file permissions
- **Auto-updates** - Downloads latest Channels DVR binary on start

## Quick Start

### Docker Run

```bash
docker run -d \
  --name channels-dvr \
  --net=host \
  --restart=unless-stopped \
  -e PUID=99 \
  -e PGID=100 \
  -e TZ=America/New_York \
  -e UMASK=022 \
  -v /mnt/user/appdata/channels-dvr:/channels-dvr \
  -v /mnt/user/data/DVR:/shares/DVR \
  --device /dev/dri:/dev/dri \
  ghcr.io/YOUR_USERNAME/channels-dvr:latest
```

### Docker Compose

```yaml
version: "3.8"
services:
  channels-dvr:
    image: ghcr.io/YOUR_USERNAME/channels-dvr:latest
    container_name: channels-dvr
    network_mode: host
    restart: unless-stopped
    environment:
      - PUID=99
      - PGID=100
      - TZ=America/New_York
      - UMASK=022
    volumes:
      - /mnt/user/appdata/channels-dvr:/channels-dvr
      - /mnt/user/data/DVR:/shares/DVR
    devices:
      - /dev/dri:/dev/dri
```

### Unraid

Use the following template settings:

| Setting | Value |
|---------|-------|
| Network Type | Host |
| Repository | `ghcr.io/YOUR_USERNAME/channels-dvr:latest` |
| PUID | Your user ID (usually 99 on Unraid) |
| PGID | Your group ID (usually 100 on Unraid) |
| /channels-dvr | `/mnt/user/appdata/channels-dvr` |
| /shares/DVR | `/mnt/user/data/DVR` or your recordings location |
| /dev/dri | `/dev/dri` (for Intel QuickSync) |

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PUID` | 99 | User ID for the channels process (99 = nobody on Unraid) |
| `PGID` | 100 | Group ID for the channels process (100 = users on Unraid) |
| `TZ` | America/New_York | Timezone |
| `UMASK` | 022 | File creation mask (022 = 755 dirs, 644 files) |
| `UPDATE_ON_START` | true | Check for Channels DVR updates on container start |
| `DVR_VERSION` | (latest) | Specific version to download (e.g., `2024.01.15.1234`) |
| `TCP_WMEM_DEFAULT` | 1048576 | Default TCP write buffer size |
| `TCP_RMEM_DEFAULT` | 1048576 | Default TCP read buffer size |

## Permissions (Unraid-Friendly)

Unlike the official fancybits container which runs everything as root and creates root-owned files, this container:

- **Runs as your specified PUID/PGID** - All processes run as the mapped user
- **Creates files with correct ownership** - Recordings and config files owned by your user
- **Respects existing files** - Only fixes ownership on the config directory, not your existing recordings
- **Configurable umask** - Control file permissions for new recordings

### Unraid Defaults

The container defaults to `PUID=99` and `PGID=100` which maps to `nobody:users` on Unraid. This matches how most Unraid containers handle permissions.

### Common Permission Settings

| OS/Setup | PUID | PGID |
|----------|------|------|
| Unraid | 99 | 100 |
| Most Linux | 1000 | 1000 |
| Synology | 1026 | 100 |
| Custom | Check with `id username` | |

## Volumes

| Path | Description |
|------|-------------|
| `/channels-dvr` | Configuration and binary storage |
| `/shares/DVR` | Recording storage |

## Ports

| Port | Protocol | Description |
|------|----------|-------------|
| 8089 | TCP | Web interface and API |
| 1900 | UDP | SSDP/UPnP discovery |
| 5353 | UDP | Bonjour/mDNS |

**Note:** Using `--net=host` is recommended for proper discovery. If using bridge networking, you'll need to manually configure the server address in the Channels apps.

## Hardware Transcoding

### Intel QuickSync

Pass the DRI device to enable hardware transcoding:

```bash
--device /dev/dri:/dev/dri
```

### NVIDIA

For NVIDIA GPUs, use the nvidia runtime:

```bash
docker run -d \
  --name channels-dvr \
  --net=host \
  --runtime=nvidia \
  -e NVIDIA_VISIBLE_DEVICES=all \
  ...
```

## Updating to a Specific Version

You can download a specific version of Channels DVR:

```bash
docker exec -it channels-dvr bash -c "DVR_VERSION=2024.01.15.1234 /usr/local/bin/setup.sh"
docker restart channels-dvr
```

## TCP Tuning Details

This container applies the following TCP settings to address connection stability:

| Setting | Value | Purpose |
|---------|-------|---------|
| `net.core.wmem_default` | 1MB | Larger default write buffer |
| `net.core.rmem_default` | 1MB | Larger default read buffer |
| `net.ipv4.tcp_wmem` | 4K/1M/16M | TCP write buffer range |
| `net.ipv4.tcp_rmem` | 4K/1M/16M | TCP read buffer range |
| `net.ipv4.tcp_keepalive_time` | 60s | Start keepalive after 60s idle |
| `net.ipv4.tcp_keepalive_intvl` | 10s | Keepalive probe interval |
| `net.ipv4.tcp_keepalive_probes` | 6 | Probes before declaring dead |
| `nf_conntrack_tcp_timeout_established` | 1 hour | Conntrack timeout (vs 5 days default) |
| `nf_conntrack_tcp_be_liberal` | 1 | Accept out-of-window packets |

These settings require the container to run with sufficient privileges (or `--privileged`). If the settings can't be applied, the container will continue without them.

## Migrating from Official Container

Your existing `/channels-dvr` configuration directory is fully compatible. Simply:

1. Stop the old container
2. Start this container with the same volume mounts
3. Your settings, recordings, and guide data will be preserved

## Building Locally

```bash
git clone https://github.com/YOUR_USERNAME/channels-dvr-docker.git
cd channels-dvr-docker
docker build -t channels-dvr .
```

## License

This project is provided as-is. Channels DVR is a product of [Fancy Bits, LLC](https://getchannels.com/).
