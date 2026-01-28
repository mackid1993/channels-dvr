# Claude Development Log

This document explains the work done to create this Channels DVR container and fix the NVIDIA Shield TV streaming issues.

## Problem Statement

Channels DVR streaming worked perfectly on Windows but had severe issues on Linux/Docker **when streaming to NVIDIA Shield TV**:
- Streams would die after approximately 6 minutes
- TCP connections would get stuck
- Issue only affected NVIDIA Shield TV - other clients (phones, tablets, web browsers, Apple TV) worked fine

## Root Cause

**The official FancyBits Docker image uses Alpine Linux**, which uses **musl libc**. This Debian-based container uses **glibc**, which handles TCP connections differently and works correctly with NVIDIA Shield TV.

The Go application (Channels DVR) behaves differently on musl vs glibc when managing TCP sockets. Shield TV is particularly sensitive to these differences.

## What We Tried (and didn't work)

### TCP Tuning via libkeepalive

We attempted to use [libkeepalive](https://github.com/msantos/libkeepalive) with `LD_PRELOAD` to inject TCP socket options:

```dockerfile
ENV TCP_USER_TIMEOUT=600000
ENV TCP_NODELAY=1
ENV LD_PRELOAD=/usr/lib/libkeepalive.so
```

**Result:** Made things worse. `LD_PRELOAD` intercepted ALL socket calls in the container (not just Channels DVR, but also Chrome, curl, etc.), causing unpredictable behavior. Streams died at 6-15 minutes depending on TCP_USER_TIMEOUT value.

**Why it was fundamentally flawed:** Go's runtime on Linux uses raw syscalls via assembly (`RawSyscall6` → `SYS_ACCEPT4`, `SYS_CONNECT`, etc.), completely bypassing libc. `LD_PRELOAD` intercepts libc function wrappers, not kernel syscalls. This means **LD_PRELOAD cannot intercept Go's network operations at all.** The libkeepalive library never reached the DVR binary's sockets — it only affected Chrome, curl, and other C programs in the container.

### sysctl TCP keepalive tuning

Attempted kernel-level TCP keepalive tuning:
```bash
sysctl -w net.ipv4.tcp_keepalive_time=300
```

**Result:** Did not work. Go overrides kernel TCP keepalive settings at the socket level via `setsockopt()`. Go sets `TCP_KEEPIDLE=15s`, `TCP_KEEPINTVL=15s` on every socket it creates.

### Adding Linux capabilities

Tried adding NET_ADMIN, NET_RAW, SYS_NICE capabilities and disabling seccomp.

**Result:** Not needed for the glibc fix. `CAP_NET_ADMIN` alone is also insufficient for sysctl writes — Docker mounts `/proc/sys` as read-only in all non-privileged containers. Only `--privileged` removes this restriction. Capabilities are only needed for the optional `tcp_retries2` hardening via `--privileged` (see below).

### Go Runtime Tuning (GODEBUG/GOGC)

Attempted tuning Go's runtime behavior:
```dockerfile
ENV GODEBUG=asyncpreemptoff=1
ENV GOGC=50
```

**Result:** Not validated as helpful. `GODEBUG=asyncpreemptoff=1` disables async preemption (intended to prevent epoll event loss), and `GOGC=50` increases GC frequency (intended to reduce race condition window). Both were speculative additions during debugging. Since the glibc fix resolved the issue independently, these were unfalsifiable — removed to keep the container simple.

## The Actual Fix

**Primary: Use Debian Bookworm (glibc) instead of Alpine (musl).**

| Container | Base | libc | Result |
|-----------|------|------|--------|
| FancyBits official | Alpine | musl | Fails on Shield |
| This container | Debian Bookworm | glibc | Works on Shield |

**Secondary: Opt-in `tcp_retries2` hardening.**

For additional TCP timeout protection, the container supports reducing `net.ipv4.tcp_retries2` via sysctl. This kernel-level parameter controls the max number of TCP retransmission attempts. Unlike keepalive settings, **Go cannot override `tcp_retries2`** because there is no per-socket `setsockopt()` for it — it's kernel-only.

- Default: `tcp_retries2=15` (~15 minute timeout for dead connections)
- Tuned: `tcp_retries2=8` (~51 second timeout)
- Enabled via `TCP_TUNING=1` environment variable
- Requires `--privileged` (Docker mounts `/proc/sys` read-only; `--cap-add=NET_ADMIN` alone is insufficient)
- Alternatively, set `tcp_retries2` directly on the host (no container privileges needed)
- With `--net=host`, this affects the host system

## Container Architecture

### Base Image
- **Debian Bookworm slim** - Uses glibc, which works correctly with Shield TV
- Minimal footprint while maintaining compatibility

### Init System
- **tini** - Minimal init that only handles zombie process reaping
- No complex process management that could interfere with networking

### User Management
- **gosu** - Simple setuid wrapper for dropping privileges
- Handles PUID/PGID for proper file ownership

### TVE Support
- **Google Chrome** - For TV Everywhere authentication
- Wrapper script adds `--no-sandbox` for Docker compatibility

### Hardware Transcoding
- **Intel QuickSync** - via intel-media-va-driver-non-free
- **NVIDIA GPU** - via environment variables (NVIDIA_VISIBLE_DEVICES)

## Verification

Check active connections:
```bash
docker exec channels-dvr ss -tno | grep 8089
```

Expected output shows ESTABLISHED connections with active keepalive timers.

Check TCP tuning:
```bash
docker exec channels-dvr sysctl net.ipv4.tcp_retries2
```

## Files

| File | Purpose |
|------|---------|
| `Dockerfile` | Debian-based container with opt-in TCP hardening |
| `entrypoint.sh` | User setup, TCP tuning, and application launch |
| `unraid-template.xml` | Unraid Community Applications template |
| `.github/workflows/docker-build.yml` | Monthly rebuilds and manual triggers |
| `.github/workflows/auto-commit.yml` | Weekly ping to keep repo active (uses [skip ci]) |
| `README.md` | User documentation |
| `CLAUDE.md` | This development log |

## Lessons Learned

1. **Don't overcomplicate it** - The fix was using the right base image, not adding TCP tuning hacks
2. **LD_PRELOAD doesn't work with Go** - Go bypasses libc entirely for socket operations, using raw syscalls via assembly. LD_PRELOAD can only intercept libc wrappers, not kernel syscalls
3. **musl vs glibc matters** - Go applications can behave differently on different libc implementations
4. **NVIDIA Shield is picky** - It's more sensitive to TCP connection handling than other streaming clients
5. **Test the simple solution first** - Before adding complexity, try the minimal approach
6. **Distinguish what Go can vs cannot override** - Go overrides keepalive settings (per-socket setsockopt) but cannot override `tcp_retries2` (kernel-only sysctl). Target the knobs Go can't touch
7. **Avoid unfalsifiable fixes** - Once the real fix works, remove speculative tuning that can't be independently validated
