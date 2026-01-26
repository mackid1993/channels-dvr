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

### sysctl TCP tuning

Attempted kernel-level TCP tuning:
```bash
sysctl -w net.ipv4.tcp_keepalive_time=300
```

**Result:** Did not work. Go overrides kernel TCP keepalive settings at the socket level via `setsockopt()`.

### Adding Linux capabilities

Tried adding NET_ADMIN, NET_RAW, SYS_NICE capabilities and disabling seccomp.

**Result:** Not needed. The simple Debian base works without any special capabilities.

## The Actual Fix

**Use Debian Bookworm (glibc) instead of Alpine (musl).**

That's it. No TCP tuning, no LD_PRELOAD, no special capabilities needed.

| Container | Base | libc | Result |
|-----------|------|------|--------|
| FancyBits official | Alpine | musl | Fails on Shield |
| This container | Debian Bookworm | glibc | Works on Shield |

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

## Files

| File | Purpose |
|------|---------|
| `Dockerfile` | Simple Debian-based container, no TCP hacks |
| `entrypoint.sh` | User setup and application launch |
| `unraid-template.xml` | Unraid Community Applications template |
| `.github/workflows/docker-build.yml` | Monthly rebuilds and manual triggers |
| `.github/workflows/auto-commit.yml` | Weekly ping to keep repo active (uses [skip ci]) |
| `README.md` | User documentation |
| `CLAUDE.md` | This development log |

## Lessons Learned

1. **Don't overcomplicate it** - The fix was using the right base image, not adding TCP tuning hacks
2. **LD_PRELOAD is dangerous** - Intercepting all socket calls has unpredictable side effects
3. **musl vs glibc matters** - Go applications can behave differently on different libc implementations
4. **NVIDIA Shield is picky** - It's more sensitive to TCP connection handling than other streaming clients
5. **Test the simple solution first** - Before adding complexity, try the minimal approach
