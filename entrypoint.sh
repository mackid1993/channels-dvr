#!/bin/bash
set -e

# =============================================================================
# Channels DVR Entrypoint Script
# Handles PUID/PGID user mapping, TCP hardening, eBPF, and first-run setup
# =============================================================================

PUID=${PUID:-99}
PGID=${PGID:-100}

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Channels DVR - Starting"
echo "  UID: $PUID | GID: $PGID"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Create group if it doesn't exist
if ! getent group channels > /dev/null 2>&1; then
    groupadd -o -g "$PGID" channels
else
    groupmod -o -g "$PGID" channels 2>/dev/null || true
fi

# Create user if it doesn't exist
if ! getent passwd channels > /dev/null 2>&1; then
    useradd -o -u "$PUID" -g "$PGID" -d /channels-dvr -s /bin/bash channels
else
    usermod -o -u "$PUID" -g "$PGID" channels 2>/dev/null || true
fi

# Set ownership of directories
echo "Setting permissions..."
mkdir -p /channels-dvr/data
chown -R channels:channels /channels-dvr
chown channels:channels /shares/DVR 2>/dev/null || true

# Download Channels DVR if not present (first run only)
if [ ! -f /channels-dvr/latest/channels-dvr ]; then
    echo "Channels DVR not found, downloading..."
    cd /
    gosu channels curl -f -s https://getchannels.com/dvr/setup.sh | DOWNLOAD_ONLY=1 gosu channels sh
    echo "Download complete!"
else
    echo "Channels DVR found, skipping download"
fi

# Verify binary exists
if [ ! -f /channels-dvr/latest/channels-dvr ]; then
    echo "FATAL: Channels DVR binary not found!"
    exit 1
fi

# Check for Intel GPU
if [ -e /dev/dri ]; then
    echo "Intel GPU detected at /dev/dri"
fi

# Check for NVIDIA GPU
if command -v nvidia-smi &> /dev/null; then
    echo "NVIDIA GPU detected"
fi

# =============================================================================
# TCP Hardening (opt-in via TCP_TUNING=1, requires --privileged)
# =============================================================================
SYSCTL_MODIFIED=false
ORIGINAL_TCP_RETRIES2=15
ORIGINAL_SLOW_START=""
ORIGINAL_NO_METRICS=""
ORIGINAL_MTU_PROBING=""
EBPF_LOADED=false
EBPF_CGROUP=""

if [ "${TCP_TUNING:-0}" = "1" ]; then
    echo "TCP tuning enabled"

    # --- Layer 1: tcp_retries2 sysctl (system-wide) ---
    # Reduces dead connection timeout from ~15min to ~6sec
    # Note: With --net=host this affects the host
    ORIGINAL_TCP_RETRIES2=$(sysctl -n net.ipv4.tcp_retries2 2>/dev/null || echo "15")
    if sysctl -w net.ipv4.tcp_retries2="${TCP_RETRIES2:-5}" > /dev/null 2>&1; then
        SYSCTL_MODIFIED=true
        echo "  tcp_retries2 set to ${TCP_RETRIES2:-5} (was $ORIGINAL_TCP_RETRIES2)"
    else
        echo "  WARNING: Could not set tcp_retries2. /proc/sys is read-only."
        echo "  Option 1: Run container with --privileged"
        echo "  Option 2: Set on host: sysctl -w net.ipv4.tcp_retries2=${TCP_RETRIES2:-5}"
    fi

    # --- Layer 2: eBPF TCP_USER_TIMEOUT (per-socket, container-scoped) ---
    # Sets TCP_USER_TIMEOUT on every TCP socket via BPF sock_ops.
    # This tells the kernel to abort connections with no ACK within N ms.
    # Scoped to the container's cgroup — does NOT affect host processes.
    if [ -f /opt/bpf/tcp_user_timeout.o ] && command -v bpftool > /dev/null 2>&1; then
        echo "  Loading eBPF TCP_USER_TIMEOUT..."

        # Mount bpffs if not already mounted
        if ! mountpoint -q /sys/fs/bpf 2>/dev/null; then
            mount -t bpf bpf /sys/fs/bpf 2>/dev/null || true
        fi

        # Load the BPF program and pin it
        if bpftool prog load /opt/bpf/tcp_user_timeout.o /sys/fs/bpf/tcp_user_timeout 2>/dev/null; then
            # Determine container's cgroup path for attachment
            CGROUP_PATH=""
            if [ -f /proc/1/cgroup ]; then
                CGROUP_V2_REL=$(awk -F: '/^0::/{print $3}' /proc/1/cgroup 2>/dev/null)
                if [ -n "$CGROUP_V2_REL" ] && [ -d "/sys/fs/cgroup${CGROUP_V2_REL}" ]; then
                    CGROUP_PATH="/sys/fs/cgroup${CGROUP_V2_REL}"
                fi
            fi
            # Fallback paths
            if [ -z "$CGROUP_PATH" ] || [ ! -d "$CGROUP_PATH" ]; then
                for path in /sys/fs/cgroup/unified /sys/fs/cgroup; do
                    if [ -d "$path" ]; then
                        CGROUP_PATH="$path"
                        break
                    fi
                done
            fi

            if [ -n "$CGROUP_PATH" ] && bpftool cgroup attach "$CGROUP_PATH" sock_ops pinned /sys/fs/bpf/tcp_user_timeout 2>/dev/null; then
                EBPF_LOADED=true
                EBPF_CGROUP="$CGROUP_PATH"

                # Update timeout map value from env var
                TIMEOUT_MS=${TCP_USER_TIMEOUT_MS:-60000}
                MAP_ID=$(bpftool prog show pinned /sys/fs/bpf/tcp_user_timeout 2>/dev/null | grep map_ids | awk '{print $2}' | tr -d ',')
                if [ -n "$MAP_ID" ]; then
                    # Convert to 4 little-endian hex bytes for bpftool
                    b0=$(printf '0x%02x' $((TIMEOUT_MS & 0xff)))
                    b1=$(printf '0x%02x' $(((TIMEOUT_MS >> 8) & 0xff)))
                    b2=$(printf '0x%02x' $(((TIMEOUT_MS >> 16) & 0xff)))
                    b3=$(printf '0x%02x' $(((TIMEOUT_MS >> 24) & 0xff)))
                    bpftool map update id "$MAP_ID" key 0x00 0x00 0x00 0x00 value $b0 $b1 $b2 $b3 2>/dev/null || true
                fi

                echo "  TCP_USER_TIMEOUT=${TIMEOUT_MS}ms attached to $CGROUP_PATH"
            else
                echo "  WARNING: Could not attach eBPF to cgroup"
                rm -f /sys/fs/bpf/tcp_user_timeout
            fi
        else
            echo "  WARNING: Could not load eBPF program (kernel may not support BPF sock_ops)"
        fi

        if [ "$EBPF_LOADED" = "false" ]; then
            echo "  eBPF unavailable — tcp_retries2 sysctl is still active"
        fi
    fi

    # --- Layer 3: Additional TCP sysctls for streaming ---
    # Save originals for cleanup, then apply
    ORIGINAL_SLOW_START=$(sysctl -n net.ipv4.tcp_slow_start_after_idle 2>/dev/null || echo "")
    ORIGINAL_NO_METRICS=$(sysctl -n net.ipv4.tcp_no_metrics_save 2>/dev/null || echo "")
    ORIGINAL_MTU_PROBING=$(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null || echo "")

    # Don't reset congestion window after idle periods (streaming has gaps)
    if sysctl -w net.ipv4.tcp_slow_start_after_idle=0 > /dev/null 2>&1; then
        echo "  tcp_slow_start_after_idle set to 0 (was $ORIGINAL_SLOW_START)"
    fi
    # Don't cache TCP metrics from previous connections (prevents bad RTT estimates)
    if sysctl -w net.ipv4.tcp_no_metrics_save=1 > /dev/null 2>&1; then
        echo "  tcp_no_metrics_save set to 1 (was $ORIGINAL_NO_METRICS)"
    fi
    # Enable MTU probing (helps with PMTUD black holes on some networks)
    if sysctl -w net.ipv4.tcp_mtu_probing=1 > /dev/null 2>&1; then
        echo "  tcp_mtu_probing set to 1 (was $ORIGINAL_MTU_PROBING)"
    fi
fi

# Build DVR arguments (matching official FancyBits run.sh)
DVR_ARGS="-dir /channels-dvr/data"
if [ -n "$CHANNELS_HOST" ]; then
    DVR_ARGS="$DVR_ARGS -host $CHANNELS_HOST"
fi
if [ -n "$CHANNELS_PORT" ]; then
    DVR_ARGS="$DVR_ARGS -port $CHANNELS_PORT"
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Starting Channels DVR Server"
echo "  Web UI: http://localhost:8089"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Disable set -e for signal handling (wait returns non-zero on signal)
set +e

# Clean up on shutdown: eBPF detach, sysctl restore, forward signal to DVR
cleanup() {
    # Detach and remove eBPF program
    if [ "$EBPF_LOADED" = "true" ]; then
        echo "Detaching eBPF TCP_USER_TIMEOUT..."
        bpftool cgroup detach "$EBPF_CGROUP" sock_ops pinned /sys/fs/bpf/tcp_user_timeout 2>/dev/null || true
        rm -f /sys/fs/bpf/tcp_user_timeout
    fi
    # Restore all modified sysctls
    if [ "$SYSCTL_MODIFIED" = "true" ]; then
        echo "Restoring sysctls..."
        sysctl -w net.ipv4.tcp_retries2="$ORIGINAL_TCP_RETRIES2" 2>/dev/null || true
        [ -n "$ORIGINAL_SLOW_START" ] && sysctl -w net.ipv4.tcp_slow_start_after_idle="$ORIGINAL_SLOW_START" 2>/dev/null || true
        [ -n "$ORIGINAL_NO_METRICS" ] && sysctl -w net.ipv4.tcp_no_metrics_save="$ORIGINAL_NO_METRICS" 2>/dev/null || true
        [ -n "$ORIGINAL_MTU_PROBING" ] && sysctl -w net.ipv4.tcp_mtu_probing="$ORIGINAL_MTU_PROBING" 2>/dev/null || true
    fi
    kill -TERM "$DVR_PID" 2>/dev/null
}
trap cleanup SIGTERM SIGINT

# Set permissive umask for Unraid SMB compatibility (files 666, dirs 777)
umask 0000

# Run DVR from data directory (matching official FancyBits layout)
cd /channels-dvr/data
gosu channels ../latest/channels-dvr $DVR_ARGS &
DVR_PID=$!
wait "$DVR_PID"
exit $?
