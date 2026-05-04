#!/bin/bash
set -e
echo "=== apt update ==="
apt-get update -qq
echo "=== prereqs ==="
apt-get install -y -qq ca-certificates curl gnupg lsb-release
echo "=== docker apt key ==="
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "=== docker apt repo ==="
. /etc/os-release
ARCH=$(dpkg --print-architecture)
echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list
apt-get update -qq
echo "=== installing docker (~150MB) ==="
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
echo "=== add terry to docker group ==="
usermod -aG docker terry
echo "=== enable + start docker ==="
systemctl enable --now docker
sleep 2
echo "=== verify ==="
docker --version
docker compose version
systemctl is-active docker
echo "=== done ==="
