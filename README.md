# Channels DVR Docker Container

A Debian-based Docker container for [Channels DVR](https://getchannels.com/) with TCP hardening that fixes NVIDIA Shield TV streaming issues, plus hardware transcoding support.

## Why This Exists

Channels DVR streams work perfectly on most clients but can suffer from connection stability issues on Linux/Docker **when streaming to NVIDIA Shield TV**:
- Streams die after ~6 minutes
- TCP connections get stuck in ESTABLISHED state
- Only affects NVIDIA Shield TV — other clients (phones, tablets, web browsers, Apple TV) work fine

### The Fix: TCP Hardening

This container applies three layers of TCP hardening:

1. **`tcp_retries2=8`** (sysctl) — Reduces dead connection timeout from ~15 minutes to ~51 seconds. This is a kernel-level parameter that Go cannot override.

2. **`TCP_USER_TIMEOUT`** (eBPF) — Sets a per-socket timeout on every TCP connection via an eBPF sock_ops program. If no data is acknowledged within 60 seconds, the kernel aborts the connection. This is scoped to the container's cgroup and does not affect host processes. Go doesn't set this option, and LD_PRELOAD can't inject it (Go bypasses libc). eBPF hooks at the kernel level, making it the only way to set per-socket options on a Go binary without modifying its source.

3. **Additional sysctls** — `tcp_slow_start_after_idle=0`, `tcp_no_metrics_save=1`, `tcp_mtu_probing=1` for streaming optimization.

This container also uses **Debian Bookworm** (glibc) instead of Alpine (musl) for broader compatibility.

## Features

- **TCP hardening** — eBPF TCP_USER_TIMEOUT + sysctl tuning that fixes Shield TV streaming
- **Debian glibc base** — Broader compatibility vs Alpine/musl
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
  --privileged \
  -e PUID=99 \
  -e PGID=100 \
  -e TZ=America/New_York \
  -e TCP_TUNING=1 \
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
    privileged: true
    restart: unless-stopped
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

### TCP Hardening Without Privileged Mode (Host Method)

If you prefer not to run the container in privileged mode, set `tcp_retries2` directly on the host. Since `--net=host` shares the host's network namespace, the container inherits the setting automatically.

```bash
# Run once (takes effect immediately):
sysctl -w net.ipv4.tcp_retries2=8

# Make persistent across reboots:
# Linux: Add to /etc/sysctl.d/99-channels-dvr.conf
echo "net.ipv4.tcp_retries2 = 8" > /etc/sysctl.d/99-channels-dvr.conf

# Unraid: Add to /boot/config/go (runs at boot)
echo 'sysctl -w net.ipv4.tcp_retries2=8' >> /boot/config/go
```

Then use Docker Compose without `privileged` or `TCP_TUNING`:

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

### Core Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `PUID` | 99 | User ID for file permissions (99 = nobody on Unraid) |
| `PGID` | 100 | Group ID for file permissions (100 = users on Unraid) |
| `TZ` | America/New_York | Timezone for scheduling |

### TCP Hardening

| Variable | Default | Description |
|----------|---------|-------------|
| `TCP_TUNING` | 0 | Set to `1` to enable TCP hardening (sysctl + eBPF + streaming optimizations). Requires `--privileged`. |
| `TCP_RETRIES2` | 8 | Max TCP retransmission attempts. Default kernel value is 15 (~15 min timeout). Setting to 8 gives ~51 second timeout for dead connections. |
| `TCP_USER_TIMEOUT_MS` | 60000 | Per-socket timeout in milliseconds, set via eBPF. If no data is ACK'd within this time, the connection is aborted. 60000 = 60 seconds. |

**Note:** `tcp_retries2` affects the host system with `--net=host` (restored on shutdown). `TCP_USER_TIMEOUT` is scoped to the container's cgroup via eBPF and does not affect host processes. The eBPF feature requires kernel >= 5.3 with `CONFIG_CGROUP_BPF` (Unraid 6.10+). If eBPF is unavailable, the container falls back to `tcp_retries2` only.

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
   - Privileged: `on` (for TCP hardening)
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

### Why tcp_retries2 Works

`tcp_retries2` is a kernel-level sysctl parameter that controls the maximum number of TCP retransmission attempts. Unlike TCP keepalive settings (which Go overrides via `setsockopt()`), there is **no per-socket option** for `tcp_retries2` — it can only be set system-wide via sysctl. Go cannot override it.

When a client (Shield TV) stops acknowledging data:
1. The kernel retransmits with exponential backoff
2. With default `tcp_retries2=15`, this takes ~15 minutes before cleanup
3. With `tcp_retries2=8`, dead connections are cleaned up in ~51 seconds

### Why eBPF TCP_USER_TIMEOUT

`TCP_USER_TIMEOUT` is a per-socket option that tells the kernel: "abort this connection if transmitted data is not acknowledged within N milliseconds." Go does **not** set this option, and `LD_PRELOAD` cannot inject it (Go bypasses libc via raw syscalls).

This container uses an **eBPF sock_ops program** that hooks into the kernel at TCP connection establishment (`BPF_SOCK_OPS_ACTIVE_ESTABLISHED_CB` / `BPF_SOCK_OPS_PASSIVE_ESTABLISHED_CB`) and calls `bpf_setsockopt()` to set `TCP_USER_TIMEOUT` on every socket. The program is attached to the container's cgroup, so it only affects connections from processes inside the container.

Windows sets `TcpMaxDataRetransmissions=5` by default (~93-189s timeout). Our `TCP_USER_TIMEOUT=60000ms` (60s) provides similar behavior on Linux.

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

### Verify eBPF TCP_USER_TIMEOUT
```bash
# Check BPF program is loaded
docker exec channels-dvr bpftool prog show pinned /sys/fs/bpf/tcp_user_timeout

# Check cgroup attachment
docker exec channels-dvr bpftool cgroup show /sys/fs/cgroup/

# Verify timeout on live sockets (look for "timeout:" in output)
docker exec channels-dvr ss -tino | grep 8089
```

## Building Locally

```bash
docker build -t channels-dvr .
```

## License

This Docker image is provided as-is. Channels DVR is a commercial product — see [getchannels.com](https://getchannels.com/) for licensing.
