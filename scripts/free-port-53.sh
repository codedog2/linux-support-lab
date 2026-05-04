#!/bin/bash
# Disable the systemd-resolved DNS stub listener so a local DNS server
# (Pi-hole / dnsmasq / unbound / k3s CoreDNS) can bind 0.0.0.0:53.
#
# Real-world relevance: this is the #1 most-asked Pi-hole / unbound /
# CoreDNS troubleshooting question on Ubuntu / Debian-derived hosts.
# Same fix appears in countless production support tickets.

set -e

echo "[1/4] Backing up /etc/systemd/resolved.conf"
cp -n /etc/systemd/resolved.conf /etc/systemd/resolved.conf.bak

echo "[2/4] Setting DNSStubListener=no"
if grep -qE '^\s*#?\s*DNSStubListener=' /etc/systemd/resolved.conf; then
    sed -i 's/^\s*#\?\s*DNSStubListener=.*/DNSStubListener=no/' /etc/systemd/resolved.conf
else
    echo "DNSStubListener=no" >> /etc/systemd/resolved.conf
fi

echo "[3/4] Replacing /etc/resolv.conf with a static upstream (1.1.1.1)"
# /etc/resolv.conf is normally a symlink to /run/systemd/resolve/stub-resolv.conf
# When we disable the stub, that file points at 127.0.0.53 which is now unreachable.
# Replace it with a real upstream until Pi-hole is up.
rm -f /etc/resolv.conf
cat > /etc/resolv.conf <<'EOF'
nameserver 1.1.1.1
nameserver 9.9.9.9
EOF

echo "[4/4] Restarting systemd-resolved"
systemctl restart systemd-resolved

echo ""
echo "=== Verification ==="
ss -tulnp | grep -E ':53\b' || echo "(port 53 is now free)"
echo ""
echo "=== /etc/resolv.conf ==="
cat /etc/resolv.conf
