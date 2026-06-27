#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

if ! command -v node >/dev/null 2>&1 || ! node --version | grep -q '^v22\.'; then
  apt-get update
  apt-get install -y ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
  chmod a+r /etc/apt/keyrings/nodesource.gpg
  echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" >/etc/apt/sources.list.d/nodesource.list
  apt-get update
  apt-get install -y nodejs
fi

if ! id -u rnfleet >/dev/null 2>&1; then
  useradd --system --create-home --home-dir /var/lib/rnfleet --shell /usr/sbin/nologin rnfleet
fi

mkdir -p /opt/rnfleet /etc/rnfleet /var/lib/rnfleet
rm -rf /opt/rnfleet/*
cp -R /tmp/rnfleet-src/. /opt/rnfleet/

cd /opt/rnfleet
npm install --omit=dev --workspaces --include-workspace-root=false

if [ ! -f /etc/rnfleet/device-runtime.env ]; then
  cp /tmp/rnfleet-packaging/device-runtime.env.example /etc/rnfleet/device-runtime.env
fi

install -m 0644 /tmp/rnfleet-packaging/rnfleet-device-runtime.service /etc/systemd/system/rnfleet-device-runtime.service

chown -R rnfleet:rnfleet /opt/rnfleet /var/lib/rnfleet /etc/rnfleet
systemctl daemon-reload 2>/dev/null || true
systemctl enable rnfleet-device-runtime.service 2>/dev/null || true
