# Claude Development Log

This document explains the container setup.

## Container Architecture

### Base Image
- **Debian Bookworm slim** — Stable glibc-based image

### Init System
- **tini** — Minimal init that handles zombie process reaping

### User Management
- **gosu** — Simple setuid wrapper for dropping privileges
- Handles PUID/PGID for proper file ownership

### TVE Support
- **Google Chrome** — For TV Everywhere authentication
- Wrapper script adds `--no-sandbox` for Docker compatibility

### Hardware Transcoding
- **Intel QuickSync** — via intel-media-va-driver-non-free
- **NVIDIA GPU** — via environment variables (NVIDIA_VISIBLE_DEVICES)

## Files

| File | Purpose |
|------|---------|
| `Dockerfile` | Debian-based container build |
| `entrypoint.sh` | User setup and application launch |
| `unraid-template.xml` | Unraid Community Applications template |
| `.github/workflows/docker-build.yml` | Monthly rebuilds and manual triggers |
| `README.md` | User documentation |
| `CLAUDE.md` | This development log |
