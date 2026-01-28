# Channels DVR Docker Container

A Debian-based Docker container for [Channels DVR](https://getchannels.com/) with hardware transcoding support.

## Features

- **Debian glibc base** — Stable base image
- **PUID/PGID support** — Proper user mapping for Unraid and other systems
- **TV Everywhere (TVE)** — Google Chrome for TVE authentication
- **Intel QuickSync** — Hardware transcoding support
- **NVIDIA GPU** — Support via nvidia-container-toolkit
- **Auto-updates** — App handles its own updates (including pre-releases)

## Quick Start

```bash
docker run -d \
  --name channels-dvr \
  --net=host \
  -e PUID=99 \
  -e PGID=100 \
  -e TZ=America/New_York \
  -v /path/to/config:/channels-dvr \
  -v /path/to/recordings:/shares/DVR \
  --device /dev/dri:/dev/dri \
  ghcr.io/mackid1993/channels-dvr:latest
```

## Docker Compose

```yaml
version: "3.8"
services:
  channels-dvr:
    image: ghcr.io/mackid1993/channels-dvr:latest
    container_name: channels-dvr
    network_mode: host
    restart: unless-stopped
    environment:
      - PUID=99
      - PGID=100
      - TZ=America/New_York
    volumes:
      - /path/to/config:/channels-dvr
      - /path/to/recordings:/shares/DVR
    devices:
      - /dev/dri:/dev/dri
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PUID` | 99 | User ID for file permissions (99 = nobody on Unraid) |
| `PGID` | 100 | Group ID for file permissions (100 = users on Unraid) |
| `TZ` | America/New_York | Timezone for scheduling |

### GPU Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `NVIDIA_DRIVER_CAPABILITIES` | compute,video,utility | NVIDIA capabilities for GPU transcoding |

## Volumes

| Path | Description |
|------|-------------|
| `/channels-dvr` | Config directory and Channels DVR binary |
| `/shares/DVR` | Recordings storage |

## Hardware Transcoding

### Intel QuickSync

Pass through the Intel GPU:

```bash
--device /dev/dri:/dev/dri
```

### NVIDIA GPU

Use nvidia-container-toolkit:

```bash
docker run --gpus all ...
```

Or with docker-compose:

```yaml
deploy:
  resources:
    reservations:
      devices:
        - capabilities: [gpu]
```

## Unraid Installation

1. Go to Docker tab
2. Add Container
3. Use template URL or manually configure:
   - Repository: `ghcr.io/mackid1993/channels-dvr:latest`
   - Network: `host`
   - Add path mappings and environment variables as shown above

## Ports

| Port | Protocol | Description |
|------|----------|-------------|
| 8089 | TCP | Web interface and API |
| 1900 | UDP | SSDP/UPnP discovery |
| 5353 | UDP | Bonjour/mDNS |

**Note:** `--net=host` is recommended for proper discovery.

## Building Locally

```bash
docker build -t channels-dvr .
```

## License

This Docker image is provided as-is. Channels DVR is a commercial product — see [getchannels.com](https://getchannels.com/) for licensing.
