# Channels DVR Docker

A Docker container for [Channels DVR Server](https://getchannels.com/dvr-server/) based on linuxserver.io's Ubuntu Noble base image.

## Why This Exists

The official `fancybits/channels-dvr` container:
- Runs as root (creates root-owned files)
- Has stale dependencies (12+ months old)
- No PUID/PGID mapping

This container uses the linuxserver.io Ubuntu Noble base with proper user mapping and fresh dependencies.

## Features

- **linuxserver.io Ubuntu Noble base** - Well-maintained, stable
- **TV Everywhere (TVE) support** - Chromium and xvfb included
- **Intel QuickSync support** - VA-API drivers from Intel's repo
- **NVIDIA support** - Works with `--gpus all` (drivers from host)
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
    volumes:
      - /mnt/user/appdata/channels-dvr:/channels-dvr
      - /mnt/user/data/DVR:/shares/DVR
    devices:
      - /dev/dri:/dev/dri
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PUID` | 99 | User ID (99 = nobody on Unraid) |
| `PGID` | 100 | Group ID (100 = users on Unraid) |
| `TZ` | America/New_York | Timezone |
| `UMASK` | 022 | File creation mask |
| `UPDATE_ON_START` | true | Check for Channels DVR updates on container start |
| `DVR_VERSION` | (latest) | Specific version to download |

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

**Note:** `--net=host` is recommended for proper discovery.

## Hardware Transcoding

### Intel QuickSync

```bash
--device /dev/dri:/dev/dri
```

### NVIDIA

```bash
docker run -d \
  --name channels-dvr \
  --net=host \
  --gpus all \
  -e NVIDIA_VISIBLE_DEVICES=all \
  ...
```

## Updating to a Specific Version

```bash
docker exec -it channels-dvr bash -c "DVR_VERSION=2024.01.15.1234 /usr/local/bin/setup.sh"
docker restart channels-dvr
```

## Migrating from Official Container

Your existing `/channels-dvr` configuration directory is fully compatible:

1. Stop the old container
2. Start this container with the same volume mounts
3. Your settings, recordings, and guide data will be preserved

## License

This project is provided as-is. Channels DVR is a product of [Fancy Bits, LLC](https://getchannels.com/).
