# Channels DVR Docker Container

A Debian-based Docker container for [Channels DVR](https://getchannels.com/) that fixes NVIDIA Shield TV streaming issues and includes hardware transcoding support.

## Why This Exists

Channels DVR streams work perfectly on Windows but can suffer from connection stability issues on Linux/Docker, **specifically when streaming to NVIDIA Shield TV**:
- Streams die after ~6 minutes
- TCP connections get stuck in ESTABLISHED state
- Only affects NVIDIA Shield TV — other clients (phones, tablets, web browsers, Apple TV) work fine

### Root Cause: musl vs glibc

The official FancyBits Docker image uses **Alpine Linux** (musl libc). This container uses **Debian Bookworm** (glibc), which handles TCP connections correctly with NVIDIA Shield TV.

| Container | Base | libc | Shield TV Result |
|-----------|------|------|-----------------|
| FancyBits official | Alpine | musl | Streams die at ~6 min |
| **This container** | **Debian Bookworm** | **glibc** | **Stable** |

Go applications behave differently on musl vs glibc when managing TCP sockets. Shield TV is particularly sensitive to these differences.

## Features

- **Debian glibc base** — Fixes Shield TV streaming stability vs Alpine/musl
- **PUID/PGID support** — Proper user mapping for Unraid and other systems
- **TV Everywhere (TVE)** — Google Chrome for TVE authentication
- **Intel QuickSync** — Hardware transcoding support
- **NVIDIA GPU** — Support via nvidia-container-toolkit
- **TCP hardening** — Optional kernel-level TCP timeout tuning
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

### With TCP Hardening

If you experience dead/stuck connections, enable TCP timeout tuning:

```yaml
version: "3.8"
services:
  channels-dvr:
    image: ghcr.io/mackid1993/channels-dvr:latest
    container_name: channels-dvr
    network_mode: host
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
    environment:
      - PUID=99
      - PGID=100
      - TZ=America/New_York
      - TCP_TUNING=1
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

### TCP Hardening (Optional)

These settings reduce the time it takes to clean up dead TCP connections. Useful if you experience stuck streams or stale connections.

| Variable | Default | Description |
|----------|---------|-------------|
| `TCP_TUNING` | 0 | Set to `1` to enable TCP timeout hardening. Requires `--cap-add=NET_ADMIN`. |
| `TCP_RETRIES2` | 8 | Max TCP retransmission attempts. Default kernel value is 15 (~15 min timeout). Setting to 8 gives ~51 second timeout for dead connections. |

**Note:** With `--net=host`, these settings affect the host system. This is generally acceptable for a dedicated media server. If you prefer not to modify host settings, you can set `tcp_retries2` directly on the host instead:

```bash
# On the host (e.g., in Unraid's /boot/config/go):
sysctl -w net.ipv4.tcp_retries2=8
```

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

TCP hardening variables are available in the advanced section of the Unraid template.

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
- **tini** — Minimal init for zombie process reaping
- **gosu** — Simple user switching

### Why LD_PRELOAD Doesn't Work with Go

Earlier versions attempted to use [libkeepalive](https://github.com/msantos/libkeepalive) via `LD_PRELOAD` to inject TCP socket options (like `TCP_USER_TIMEOUT`) into the Go binary. **This approach is fundamentally flawed.**

Go's runtime on Linux uses raw syscalls via assembly (`RawSyscall6` → `SYS_ACCEPT4`, `SYS_CONNECT`, etc.), completely bypassing libc. `LD_PRELOAD` intercepts libc function wrappers, not kernel syscalls, so it **cannot** intercept Go's network operations.

The `LD_PRELOAD` only affected other processes in the container (Chrome, curl, wget), causing unpredictable behavior without ever reaching the DVR binary's sockets.

### Why tcp_retries2 Works

`tcp_retries2` is a kernel-level sysctl parameter that controls the maximum number of TCP retransmission attempts. Unlike TCP keepalive settings (which Go overrides via `setsockopt()`), there is **no per-socket option** for `tcp_retries2` — it can only be set system-wide via sysctl. Go cannot override it.

This matters for streaming because when a client (Shield TV) stops acknowledging data:
1. The kernel retransmits with exponential backoff
2. With default `tcp_retries2=15`, this takes ~15 minutes before the connection is cleaned up
3. With `tcp_retries2=8`, dead connections are cleaned up in ~51 seconds

## Troubleshooting

### Check Active Connections
```bash
docker exec channels-dvr ss -tno | grep 8089
```

### Check Conntrack Entries
```bash
cat /proc/net/nf_conntrack | grep 8089
```

### Verify TCP Tuning is Active
```bash
docker exec channels-dvr sysctl net.ipv4.tcp_retries2
```

## Building Locally

```bash
docker build -t channels-dvr .
```

## License

This Docker image is provided as-is. Channels DVR is a commercial product — see [getchannels.com](https://getchannels.com/) for licensing.
