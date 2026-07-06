#!/usr/bin/env bash
set -euo pipefail

HOST="${HOST:-pi@10.42.0.1}"
SSH_KEY="${SSH_KEY:-}"

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/deploy.sh [--host pi@10.42.0.1] [--key /path/to/key]

Options:
  --host      SSH target. Defaults to pi@10.42.0.1
  --key       SSH private key path.
  -h, --help  Show this help.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --host)
      HOST="$2"
      shift 2
      ;;
    --key)
      SSH_KEY="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new)
if [ -n "$SSH_KEY" ]; then
  SSH_OPTS=(-i "$SSH_KEY" "${SSH_OPTS[@]}")
fi

ssh_pi() {
  ssh "${SSH_OPTS[@]}" "$HOST" "$@"
}

scp_pi() {
  scp "${SSH_OPTS[@]}" "$1" "$HOST:$2"
}

echo "Deploying Amnezia Raspberry admin UI to $HOST"

scp_pi "$PROJECT_DIR/src/vpn-admin-server" "/tmp/vpn-admin-server"
scp_pi "$PROJECT_DIR/src/vpn-admin-traffic-snapshot" "/tmp/vpn-admin-traffic-snapshot"
scp_pi "$PROJECT_DIR/src/vpn-admin-status-snapshot" "/tmp/vpn-admin-status-snapshot"
scp_pi "$PROJECT_DIR/systemd/vpn-admin.service" "/tmp/vpn-admin.service"
scp_pi "$PROJECT_DIR/systemd/vpn-admin-traffic.service" "/tmp/vpn-admin-traffic.service"
scp_pi "$PROJECT_DIR/systemd/vpn-admin-traffic.timer" "/tmp/vpn-admin-traffic.timer"
scp_pi "$PROJECT_DIR/systemd/vpn-admin-status.service" "/tmp/vpn-admin-status.service"
scp_pi "$PROJECT_DIR/systemd/vpn-admin-status.timer" "/tmp/vpn-admin-status.timer"
scp_pi "$PROJECT_DIR/src/vpn-admin-helper" "/tmp/vpn-admin-helper"
scp_pi "$PROJECT_DIR/sudoers/vpn-admin-helper" "/tmp/vpn-admin-helper.sudoers"

ssh_pi 'sudo install -m 0755 /tmp/vpn-admin-server /usr/local/sbin/vpn-admin-server &&
sudo install -m 0755 /tmp/vpn-admin-traffic-snapshot /usr/local/sbin/vpn-admin-traffic-snapshot &&
sudo install -m 0755 /tmp/vpn-admin-status-snapshot /usr/local/sbin/vpn-admin-status-snapshot &&
sudo install -m 0755 /tmp/vpn-admin-helper /usr/local/sbin/vpn-admin-helper &&
sudo install -m 0644 /tmp/vpn-admin.service /etc/systemd/system/vpn-admin.service &&
sudo install -m 0644 /tmp/vpn-admin-traffic.service /etc/systemd/system/vpn-admin-traffic.service &&
sudo install -m 0644 /tmp/vpn-admin-traffic.timer /etc/systemd/system/vpn-admin-traffic.timer &&
sudo install -m 0644 /tmp/vpn-admin-status.service /etc/systemd/system/vpn-admin-status.service &&
sudo install -m 0644 /tmp/vpn-admin-status.timer /etc/systemd/system/vpn-admin-status.timer &&
sudo visudo -cf /tmp/vpn-admin-helper.sudoers &&
sudo install -m 0440 /tmp/vpn-admin-helper.sudoers /etc/sudoers.d/vpn-admin-helper &&
sudo systemctl daemon-reload &&
sudo systemctl enable --now vpn-admin-traffic.timer &&
sudo systemctl start vpn-admin-traffic.service &&
sudo systemctl enable --now vpn-admin-status.timer &&
sudo systemctl start vpn-admin-status.service &&
sudo systemctl enable --now vpn-admin &&
sudo systemctl restart vpn-admin'

ssh_pi 'systemctl --no-pager --plain is-active vpn-admin'
echo "Done. Open http://10.42.0.1/admin"
