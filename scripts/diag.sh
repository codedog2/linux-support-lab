#!/usr/bin/env bash
# diag.sh — one-shot system health snapshot for Linux L1/L2 support work.
#
# Output is a single structured report to stdout. Sized so the whole thing
# fits inside a typical support-ticket attachment. Designed to answer the
# question every L1 ticket starts with: "what is the state of this box
# right now, before we go any deeper?"
#
# Usage:
#   ./diag.sh                  # human-readable to stdout
#   ./diag.sh > diag-$(hostname)-$(date +%FT%H%M).txt
#   sudo ./diag.sh             # adds: process owners on listening sockets,
#                              #       full journalctl, dmesg even on
#                              #       restricted kernels
#
# Sections gracefully skip when their tool is missing (e.g. no docker,
# no kubectl) — the script is safe to run on a stock Linux host.

set -u
LANG=C; LC_ALL=C

section() { printf '\n=== %s ===\n' "$1"; }
have()    { command -v "$1" >/dev/null 2>&1; }

section "host"
if have hostnamectl; then
    hostnamectl 2>/dev/null
else
    uname -a
    [ -r /etc/os-release ] && head -5 /etc/os-release
fi
echo "uptime:    $(uptime -p 2>/dev/null || uptime)"
echo "loadavg:   $(awk '{print $1" "$2" "$3}' /proc/loadavg)"
echo "logged-in: $(who | wc -l) users"

section "cpu"
echo "cores:     $(nproc --all)"
echo "model:     $(awk -F: '/model name/ {print $2; exit}' /proc/cpuinfo | sed 's/^ *//')"
echo
echo "top header:"
top -b -n 1 2>/dev/null | head -5

section "memory"
free -h
echo
awk '/^(MemTotal|MemFree|MemAvailable|Buffers|Cached|SwapTotal|SwapFree):/' /proc/meminfo

section "disk usage (real filesystems only)"
df -h --output=source,size,used,avail,pcent,target 2>/dev/null \
    | grep -vE '^(tmpfs|devtmpfs|overlay|/dev/loop)'
echo
echo "inode usage:"
df -i --output=source,iused,iavail,ipcent,target 2>/dev/null \
    | grep -vE '^(tmpfs|devtmpfs|overlay|/dev/loop)'

section "network interfaces"
if have ip; then
    ip -br -4 addr
    echo
    echo "default route: $(ip -4 route show default 2>/dev/null | head -1)"
else
    ifconfig 2>/dev/null || echo "(no ip / ifconfig)"
fi
echo
echo "DNS resolvers (/etc/resolv.conf):"
grep -E '^nameserver' /etc/resolv.conf 2>/dev/null || echo "(none)"

section "listening ports"
if have ss; then
    ss -tulnp 2>/dev/null | head -40
else
    netstat -tulnp 2>/dev/null | head -40 || echo "(no ss / netstat)"
fi

section "top 10 processes by CPU"
ps -eo pid,user,pcpu,pmem,rss,comm --sort=-pcpu 2>/dev/null | head -11

section "top 10 processes by RSS (memory)"
ps -eo pid,user,pcpu,pmem,rss,comm --sort=-rss 2>/dev/null | head -11

section "recent kernel events (dmesg, last 20 lines)"
if dmesg -T >/dev/null 2>&1; then
    dmesg -T 2>/dev/null | tail -20
else
    echo "(dmesg requires root on this kernel)"
fi

section "recent service failures (journalctl, priority=err, last hour)"
if have journalctl; then
    journalctl --since "1 hour ago" --priority=err --no-pager 2>/dev/null | tail -15 \
        || echo "(journalctl needs root, or no errors in window)"
else
    echo "(no journalctl)"
fi

section "docker"
if have docker; then
    if docker info >/dev/null 2>&1; then
        docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null
    else
        echo "(docker installed but daemon not reachable for this user)"
    fi
else
    echo "(docker not installed)"
fi

section "kubernetes"
if have kubectl; then
    if kubectl version --request-timeout=2s >/dev/null 2>&1; then
        kubectl get nodes 2>/dev/null
        echo
        echo "non-running pods (across all namespaces):"
        kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded 2>/dev/null \
            | head -20
    else
        echo "(kubectl installed but cluster not reachable)"
    fi
else
    echo "(kubectl not installed)"
fi

echo
echo "=== end of report ==="
