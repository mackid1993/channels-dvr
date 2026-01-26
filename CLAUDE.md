# Claude Development Log

This document explains the work done to create this Channels DVR container and fix the TCP connection stability issues.

## Problem Statement

Channels DVR streaming worked perfectly on Windows but had severe issues on Linux/Docker **when streaming to NVIDIA Shield TV**:
- Streams would die after approximately 6 minutes
- TCP connections would get stuck in ESTABLISHED state
- Conntrack entries would pile up (10-12 stale connections instead of 2-3)
- Connections would not be cleaned up properly

**Important:** This issue does not affect most clients. Other devices (phones, tablets, web browsers, Apple TV, etc.) work fine. The NVIDIA Shield TV appears to be particularly sensitive to TCP connection handling on Linux.

## Investigation

### Initial Hypothesis: s6-overlay

The original container used linuxserver.io's Ubuntu Noble base with s6-overlay. s6-overlay is a complex init system that manages processes and signals. It was suspected of interfering with network connections.

**Action:** Rebuilt the container from scratch using:
- Debian Bookworm slim (simpler, more stable)
- tini (minimal init system, just handles zombie reaping)
- gosu (simple user switching without s6's complexity)

**Result:** Issue persisted. s6-overlay was not the cause.

### Second Hypothesis: Kernel TCP Settings

Attempted to tune TCP keepalive via sysctl:
```bash
sysctl -w net.ipv4.tcp_keepalive_time=300
sysctl -w net.ipv4.tcp_keepalive_intvl=60
sysctl -w net.ipv4.tcp_keepalive_probes=3
```

**Result:** Did not work. Connections still died at ~6 minutes.

### Root Cause Discovery: Go Overrides sysctl

Channels DVR is written in Go. Investigation revealed:

1. Go's `net` package calls `setsockopt()` on every socket it creates
2. Go sets its own TCP keepalive values (~15 seconds)
3. This **overrides** any kernel defaults set via sysctl
4. sysctl settings are effectively ignored for Go applications

This explains why the same application works on Windows (different TCP stack behavior) but fails on Linux.

### Solution: libkeepalive + TCP_USER_TIMEOUT

[libkeepalive](https://github.com/msantos/libkeepalive) is an `LD_PRELOAD` library that intercepts socket creation and sets TCP options.

**Key insight:** While Go overrides `TCP_KEEPIDLE`, `TCP_KEEPINTVL`, and `TCP_KEEPCNT`, it does **NOT** override `TCP_USER_TIMEOUT`.

`TCP_USER_TIMEOUT` is a hard limit on how long a connection can have unacknowledged data before being forcibly closed. This is exactly what was needed to clean up stuck connections.

**Implementation:**
1. Build all three libkeepalive variants (socket, listen, connect hooks)
2. Set `LD_PRELOAD` to load all three libraries
3. Set `TCP_USER_TIMEOUT=600000` (10 minutes in milliseconds)
4. Set `TCP_NODELAY=1` (disable Nagle's algorithm)

**Result:** Conntrack entries stay at 2-3 instead of 10-12. Streams are stable.

## What Was Tried and Didn't Work

### TCP Keepalive Timing via libkeepalive

Attempted to set:
- `TCP_KEEPIDLE=300`
- `TCP_KEEPINTVL=60`
- `TCP_KEEPCNT=5`

**Result:** Go still overrides these values. Verified with `ss -tno` showing ~15 second keepalive timers instead of 300 seconds.

These settings were removed from the final configuration since they have no effect on Go applications.

### Environment Variables in entrypoint.sh

Initially set TCP environment variables in `entrypoint.sh`:
```bash
export TCP_USER_TIMEOUT=600000
```

**Result:** Variables were not passed through `gosu` to the channels-dvr process.

**Fix:** Moved all TCP environment variables to Dockerfile `ENV` directives, which are properly inherited by all processes.

### Single libkeepalive Library

Initially only built `libkeepalive_socket.so`.

**Result:** Unclear if Go was using `socket()` calls that would be intercepted.

**Fix:** Build and load all three variants to cover all possible socket creation paths:
- `libkeepalive.so` - hooks `connect()`
- `libkeepalive_listen.so` - hooks `listen()`
- `libkeepalive_socket.so` - hooks `socket()`

## Final Configuration

### Dockerfile TCP Settings
```dockerfile
ENV TCP_USER_TIMEOUT=600000
ENV TCP_NODELAY=1
ENV LD_PRELOAD=/usr/lib/libkeepalive.so:/usr/lib/libkeepalive_listen.so:/usr/lib/libkeepalive_socket.so
```

### libkeepalive Build
```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends gcc libc6-dev git \
    && git clone --depth 1 https://github.com/msantos/libkeepalive.git /tmp/libkeepalive \
    && cd /tmp/libkeepalive \
    && gcc -D_GNU_SOURCE -nostartfiles -shared -fPIC -o libkeepalive.so keepalive.c libkeepalive.c -ldl \
    && gcc -D_GNU_SOURCE -nostartfiles -shared -fPIC -o libkeepalive_listen.so keepalive.c libkeepalive_listen.c -ldl \
    && gcc -D_GNU_SOURCE -nostartfiles -shared -fPIC -o libkeepalive_socket.so keepalive.c libkeepalive_socket.c -ldl \
    && cp libkeepalive.so libkeepalive_listen.so libkeepalive_socket.so /usr/lib/ \
    && cd / && rm -rf /tmp/libkeepalive \
    && apt-get purge -y gcc libc6-dev git \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*
```

## Container Architecture

### Base Image
- **Debian Bookworm slim** - Minimal, stable base
- Chosen over Ubuntu Noble due to simpler networking stack

### Init System
- **tini** - Minimal init that only handles zombie process reaping
- Replaces s6-overlay's complex process management

### User Management
- **gosu** - Simple setuid wrapper for dropping privileges
- Handles PUID/PGID without s6's complexity

### TVE Support
- **Google Chrome** - For TV Everywhere authentication
- Wrapper script adds `--no-sandbox` for Docker compatibility

### Hardware Transcoding
- **Intel QuickSync** - via intel-media-va-driver-non-free
- **NVIDIA GPU** - via runtime injection (nvidia-container-toolkit)

## Verification Commands

Check TCP settings are applied:
```bash
docker exec channels-dvr env | grep TCP
```

Check active connections:
```bash
docker exec channels-dvr ss -tno | grep 8089
```

Check conntrack entries (from host):
```bash
cat /proc/net/nf_conntrack | grep 8089
```

## Files Modified

| File | Purpose |
|------|---------|
| `Dockerfile` | Container build with libkeepalive and TCP settings |
| `entrypoint.sh` | Simplified startup script (TCP settings moved to Dockerfile) |
| `unraid-template.xml` | Unraid template with TCP tuning variables |
| `.github/workflows/docker-build.yml` | CI/CD for building and pushing to GHCR |
| `README.md` | User documentation |
| `CLAUDE.md` | This development log |

## Lessons Learned

1. **Go overrides kernel TCP defaults** - sysctl is not effective for Go applications
2. **TCP_USER_TIMEOUT is the key** - It's not commonly set by applications, so LD_PRELOAD can inject it
3. **Environment variables must be in Dockerfile** - `export` in entrypoint.sh doesn't survive `exec gosu`
4. **Simple is better** - tini + gosu is more reliable than s6-overlay for this use case
5. **Test at the socket level** - `ss -tno` shows the actual socket options, not what you think you set
