# Claude Development Log

This document explains the work done to create this Channels DVR container and fix the NVIDIA Shield TV streaming issues.

## Problem Statement

Channels DVR streaming worked perfectly on Windows but had severe issues on Linux/Docker **when streaming to NVIDIA Shield TV**:
- Streams would die after approximately 6 minutes
- TCP connections would get stuck in ESTABLISHED state
- Issue only affected NVIDIA Shield TV - other clients (phones, tablets, web browsers, Apple TV) worked fine

## Root Cause

**Dead TCP connections linger for ~15 minutes with the default kernel setting (`tcp_retries2=15`).** NVIDIA Shield TV is particularly sensitive to stale connections — they pile up and streams die.

The fix is reducing `tcp_retries2` to 8, which cleans up dead connections in ~51 seconds instead of ~15 minutes. This is a kernel-level sysctl parameter that **Go cannot override** — there is no per-socket `setsockopt()` for it, making it the only effective TCP tuning for Go applications.

The container also uses **Debian Bookworm** (glibc) instead of Alpine (musl) for broader TCP socket compatibility.

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

**Result:** `CAP_NET_ADMIN` alone is insufficient for sysctl writes — Docker mounts `/proc/sys` as **read-only** in all non-privileged containers via runc's `readonlyPaths`. No combination of capabilities changes this. Only `--privileged` removes the read-only mount restriction.

### Go Runtime Tuning (GODEBUG/GOGC)

Attempted tuning Go's runtime behavior:
```dockerfile
ENV GODEBUG=asyncpreemptoff=1
ENV GOGC=50
```

**Result:** Not validated as helpful. Both were speculative additions during debugging that couldn't be independently validated. Removed to keep the container simple.

### Redirecting stdout to /dev/null

Attempted to fix the logs page by redirecting DVR stdout/stderr to `/dev/null`:
```bash
exec gosu channels "$@" > /dev/null 2>&1
```

**Result:** Did not fix the logs page. The DVR binary writes `channels-dvr.log` to its data directory — the web UI reads from that file, not stdout. The real fix was passing `-dir /channels-dvr/data` (see below).

## The Actual Fix

### Primary: TCP hardening via `tcp_retries2`

| Setting | Value | Timeout |
|---------|-------|---------|
| Default | `tcp_retries2=15` | ~15 minutes for dead connections |
| **Tuned** | **`tcp_retries2=8`** | **~51 seconds for dead connections** |

- Enabled via `TCP_TUNING=1` environment variable
- Requires `--privileged` (Docker mounts `/proc/sys` read-only; `--cap-add=NET_ADMIN` alone is insufficient)
- Alternatively, set `tcp_retries2` directly on the host (no container privileges needed)
- With `--net=host`, this affects the host system
- Original value is saved and **restored on container shutdown** via SIGTERM/SIGINT trap
- Go cannot override `tcp_retries2` because there is no per-socket `setsockopt()` for it — it's kernel-only

### Secondary: Debian Bookworm (glibc)

Using Debian Bookworm (glibc) instead of Alpine (musl) provides broader TCP socket compatibility. Go applications can behave differently on musl vs glibc when managing TCP sockets.

### Logs page fix: `-dir /channels-dvr/data`

The DVR's web UI logs page (`/admin/log`) reads from `channels-dvr.log` in the data directory. Without the `-dir` flag, the binary doesn't write this file. The official FancyBits `run.sh` does:

```sh
cd /channels-dvr/data
exec ../latest/channels-dvr -dir /channels-dvr/data
```

Our entrypoint matches this structure.

### Unraid SMB file permissions: `umask 0000`

The DVR binary creates recording files with restrictive permissions, preventing deletion via Windows SMB shares on Unraid. The official FancyBits container has this same bug. The timstephens24 community container fixes it with `umask 0000`, which we adopted. This makes files `666` and directories `777`, allowing SMB access.

## Container Architecture

### Directory Layout

```
/channels-dvr/              ← volume mount (persistent)
  data/                     ← data directory (-dir points here)
    channels-dvr.log        ← main log file (read by /admin/log)
    Logs/                   ← recording/comskip logs
    [database, config]
  latest/
    channels-dvr            ← the binary
/shares/DVR/                ← recordings volume
```

### Base Image
- **Debian Bookworm slim** — Uses glibc for broader compatibility
- Minimal footprint while maintaining compatibility

### Init System
- **tini** — Minimal init that only handles zombie process reaping
- No complex process management that could interfere with networking

### User Management
- **gosu** — Simple setuid wrapper for dropping privileges
- Handles PUID/PGID for proper file ownership
- Default: PUID=99 (nobody), PGID=100 (users) — standard Unraid mapping

### TVE Support
- **Google Chrome** — For TV Everywhere authentication
- Wrapper script adds `--no-sandbox` for Docker compatibility

### Hardware Transcoding
- **Intel QuickSync** — via intel-media-va-driver-non-free
- **NVIDIA GPU** — via environment variables (NVIDIA_VISIBLE_DEVICES)

### Signal Handling and TCP Cleanup

The entrypoint uses **background+wait** instead of `exec` so that bash stays alive to handle signals:

1. DVR runs in background via `gosu channels ../latest/channels-dvr $DVR_ARGS &`
2. `trap cleanup SIGTERM SIGINT` catches shutdown signals
3. Cleanup function restores original `tcp_retries2` value, then forwards SIGTERM to DVR
4. `set +e` before the trap/wait section — `set -e` would kill bash when `wait` is interrupted by a signal (exit code 143)

**Why not `exec`:** `exec` replaces bash with the DVR process. Signal traps are lost because bash no longer exists. The sysctl cleanup would never run.

### Binary Path

The setup script (`getchannels.com/dvr/setup.sh`) creates `channels-dvr/latest/channels-dvr` relative to the current directory. The entrypoint runs the setup from `/` so the binary lands at `/channels-dvr/latest/channels-dvr` inside the volume mount. Running from `/channels-dvr` would create a nested `/channels-dvr/channels-dvr/latest/channels-dvr`.

## Verification

Check active connections:
```bash
docker exec channels-dvr ss -tno | grep 8089
```

Check TCP tuning:
```bash
docker exec channels-dvr sysctl net.ipv4.tcp_retries2
```

Check conntrack:
```bash
cat /proc/net/nf_conntrack | grep 8089
```

## Files

| File | Purpose |
|------|---------|
| `Dockerfile` | Debian-based container with data directory and build-time setup |
| `entrypoint.sh` | User setup, TCP tuning with cleanup, umask, DVR launch with -dir flag |
| `unraid-template.xml` | Unraid Community Applications template |
| `.github/workflows/docker-build.yml` | Monthly rebuild (1st at midnight ET) and manual triggers |
| `.github/workflows/auto-commit.yml` | Weekly ping Monday midnight UTC (uses [skip ci]) |
| `README.md` | User documentation |
| `CLAUDE.md` | This development log |

## Lessons Learned

1. **`tcp_retries2` is the fix** — The kernel parameter that controls dead connection timeout. Go cannot override it (no per-socket setsockopt). Default 15 = ~15 min. Value 8 = ~51 sec.
2. **LD_PRELOAD doesn't work with Go** — Go bypasses libc entirely for socket operations, using raw syscalls via assembly. LD_PRELOAD can only intercept libc wrappers, not kernel syscalls.
3. **Docker /proc/sys is read-only** — Docker mounts `/proc/sys` as read-only in ALL non-privileged containers. `--cap-add=NET_ADMIN` grants the capability but the read-only filesystem blocks the write. Only `--privileged` removes this restriction.
4. **`exec` prevents signal traps** — `exec` replaces bash, so traps never fire. Use background+wait to keep bash alive for cleanup.
5. **`set -e` breaks signal handling** — When `wait` is interrupted by SIGTERM, it returns exit code 143 (128+15). `set -e` would exit bash before the trap handler completes. Use `set +e` before the wait section.
6. **`-dir` flag required for logs page** — The DVR binary needs `-dir /channels-dvr/data` to know where to write `channels-dvr.log`. Without it, the web UI logs page (`/admin/log`) has nothing to read. Discovered by examining the official FancyBits `run.sh`.
7. **`umask 0000` for Unraid SMB** — The DVR creates files with restrictive permissions. Without `umask 0000`, Windows can't delete recordings via SMB. Official FancyBits container has this bug; timstephens24 container fixes it.
8. **NVIDIA Shield is picky** — More sensitive to TCP connection handling than other streaming clients.
9. **Run setup.sh from `/`** — The setup script creates `channels-dvr/latest/channels-dvr` relative to cwd. Running from `/channels-dvr` creates a nested path. Running from `/` puts the binary at `/channels-dvr/latest/channels-dvr`.
10. **Distinguish what Go can vs cannot override** — Go overrides keepalive settings (per-socket setsockopt) but cannot override `tcp_retries2` (kernel-only sysctl). Target the knobs Go can't touch.
11. **Avoid unfalsifiable fixes** — Remove speculative tuning that can't be independently validated (GODEBUG, GOGC, etc.).
