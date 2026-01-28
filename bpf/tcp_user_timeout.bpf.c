// SPDX-License-Identifier: GPL-2.0
//
// eBPF sock_ops program: sets TCP_USER_TIMEOUT on every TCP connection.
//
// When attached to a cgroup, this fires on TCP connection establishment
// (both active and passive) and sets TCP_USER_TIMEOUT via bpf_setsockopt().
//
// TCP_USER_TIMEOUT tells the kernel: "if no data is acknowledged within
// N milliseconds, abort the connection." This is the per-socket equivalent
// of what tcp_retries2 does at the system level, but more precise.
//
// Go bypasses libc (raw syscalls), so LD_PRELOAD can't inject socket options.
// This eBPF program operates at the kernel level, catching every socket
// regardless of how the application creates it.
//
// The timeout value is configurable at runtime via the BPF map.

#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>

// These may not be in older headers, define explicitly
#ifndef IPPROTO_TCP
#define IPPROTO_TCP 6
#endif

#ifndef TCP_USER_TIMEOUT
#define TCP_USER_TIMEOUT 18
#endif

#define DEFAULT_TIMEOUT_MS 60000  // 60 seconds

// Runtime-configurable timeout value (milliseconds)
// Key 0 = timeout in ms. If 0 or missing, uses DEFAULT_TIMEOUT_MS.
struct {
	__uint(type, BPF_MAP_TYPE_ARRAY);
	__uint(max_entries, 1);
	__type(key, __u32);
	__type(value, __u32);
} timeout_map SEC(".maps");

SEC("sockops")
int set_tcp_user_timeout(struct bpf_sock_ops *skops)
{
	__u32 key = 0;
	__u32 *val;
	int timeout;

	// Only act when a TCP connection is fully established
	if (skops->op != BPF_SOCK_OPS_ACTIVE_ESTABLISHED_CB &&
	    skops->op != BPF_SOCK_OPS_PASSIVE_ESTABLISHED_CB)
		return 1;

	// Read timeout from map, fall back to default if not set
	val = bpf_map_lookup_elem(&timeout_map, &key);
	timeout = (val && *val > 0) ? (int)*val : DEFAULT_TIMEOUT_MS;

	bpf_setsockopt(skops, IPPROTO_TCP, TCP_USER_TIMEOUT,
			&timeout, sizeof(timeout));

	return 1;
}

char _license[] SEC("license") = "GPL";
