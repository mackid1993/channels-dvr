# Channels DVR Docker Container

A custom Docker container for [Channels DVR](https://getchannels.com/) with TCP connection tuning to fix streaming stability issues on Linux.

## Why This Exists

Channels DVR works flawlessly on Windows but can suffer from connection stability issues on Linux/Docker, **specifically when streaming to NVIDIA Shield TV**:
- Streams would die after ~6 minutes
- TCP connections would get stuck in ESTABLISHED state
- Conntrack entries would pile up (10-12 stale connections)

**Note:** Most clients work fine. This TCP tuning specifically addresses issues with NVIDIA Shield TV streaming.

The root cause: Linux kernel TCP defaults combined with Go's networking behavior cause connections to hang instead of being cleaned up properly. The Shield appears to be particularly sensitive to this.

### Why sysctl Doesn't Work

The obvious fix would be kernel TCP tuning via sysctl:
```bash
sysctl net.ipv4.tcp_keepalive_time=300
```

**This doesn't work because:**
1. Channels DVR is written in Go
2. Go overrides kernel TCP defaults by calling `setsockopt()` on every socket
3. Your sysctl settings get ignored

### The Solution: libkeepalive + TCP_USER_TIMEOUT

This container uses [libkeepalive](https://github.com/msantos/libkeepalive) via `LD_PRELOAD` to set socket options at the application level:

- **TCP_USER_TIMEOUT** - Forces cleanup of connections with unacknowledged data
- **TCP_NODELAY** - Disables Nagle's algorithm for lower latency

Go doesn't override `TCP_USER_TIMEOUT`, so this setting persists and cleans up stuck connections.

**Result:** Conntrack entries stay at 2-3 instead of piling up to 10-12. Streams are stable.

## Features

- **Simple & Stable**: Debian Bookworm base with minimal tini init system
- **TCP Connection Tuning**: libkeepalive for stable streaming
- **PUID/PGID Support**: Proper user mapping for Unraid and other systems
- **TV Everywhere (TVE)**: Google Chrome for TVE authentication
- **Intel QuickSync**: Hardware transcoding support
- **NVIDIA GPU**: Support via nvidia-container-toolkit
- **Auto-updates**: App handles its own updates (including pre-releases)

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
      # TCP tuning (optional - defaults are usually fine)
      # - TCP_USER_TIMEOUT=600000
      # - TCP_NODELAY=1
    volumes:
      - /path/to/config:/channels-dvr
      - /path/to/recordings:/shares/DVR
    devices:
      - /dev/dri:/dev/dri
```

## Environment Variables

### Core Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `PUID` | 99 | User ID for file permissions (99 = nobody on Unraid) |
| `PGID` | 100 | Group ID for file permissions (100 = users on Unraid) |
| `TZ` | America/New_York | Timezone for scheduling |

### TCP Tuning (Advanced)

These settings are applied via libkeepalive and help fix connection stability issues on Linux.

| Variable | Default | Description |
|----------|---------|-------------|
| `TCP_USER_TIMEOUT` | 600000 | Hard timeout (ms) for connections with unacknowledged data. Forces cleanup of stuck connections after 10 minutes. Set to 0 to disable. |
| `TCP_NODELAY` | 1 | Disables Nagle's algorithm (1=disabled, 0=enabled). Reduces latency for streaming. |

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

The Unraid template includes TCP tuning variables in the advanced section.

## Ports

| Port | Protocol | Description |
|------|----------|-------------|
| 8089 | TCP | Web interface and API |
| 1900 | UDP | SSDP/UPnP discovery |
| 5353 | UDP | Bonjour/mDNS |

**Note:** `--net=host` is recommended for proper discovery.

## Technical Details

### Why Not s6-overlay?

Previous versions used linuxserver.io's base with s6-overlay. This added complexity and was suspected of contributing to networking issues. This container uses:
- **tini** - Minimal init for zombie process reaping
- **gosu** - Simple user switching

### libkeepalive Libraries

Three variants are built and preloaded via `LD_PRELOAD`:
- `libkeepalive.so` - Hooks `connect()` for outgoing connections
- `libkeepalive_listen.so` - Hooks `listen()` for server sockets
- `libkeepalive_socket.so` - Hooks `socket()` for all sockets

This ensures TCP options are applied regardless of how Go creates its sockets.

### Why Go Ignores sysctl

Go's net package calls `setsockopt()` on every socket it creates, setting its own TCP keepalive values (~15 seconds). This overrides any kernel defaults set via sysctl. However, Go doesn't set `TCP_USER_TIMEOUT`, so libkeepalive's setting persists.

## Troubleshooting

### Check TCP Settings
```bash
docker exec channels-dvr env | grep TCP
```

### Check Active Connections
```bash
docker exec channels-dvr ss -tno | grep 8089
```

### Check Conntrack Entries
```bash
cat /proc/net/nf_conntrack | grep 8089
```

## Building Locally

```bash
docker build -t channels-dvr .
```

## License

This Docker image is provided as-is. Channels DVR is a commercial product - see [getchannels.com](https://getchannels.com/) for licensing.
