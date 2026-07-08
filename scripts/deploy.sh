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

echo "Deploying Amnezia Raspberry admin UI and router rules to $HOST"

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
scp_pi "$PROJECT_DIR/nftables/vpn-router.nft" "/tmp/vpn-router.nft.template"
scp_pi "$PROJECT_DIR/provision/bin/vpn-split-update" "/tmp/vpn-split-update"
scp_pi "$PROJECT_DIR/provision/bin/vpn-router-source-apply" "/tmp/vpn-router-source-apply"
scp_pi "$PROJECT_DIR/systemd/vpn-router-source-apply.service" "/tmp/vpn-router-source-apply.service"

ssh_pi 'sudo install -m 0755 /tmp/vpn-admin-server /usr/local/sbin/vpn-admin-server &&
sudo install -m 0755 /tmp/vpn-admin-traffic-snapshot /usr/local/sbin/vpn-admin-traffic-snapshot &&
sudo install -m 0755 /tmp/vpn-admin-status-snapshot /usr/local/sbin/vpn-admin-status-snapshot &&
sudo install -m 0755 /tmp/vpn-admin-helper /usr/local/sbin/vpn-admin-helper &&
sudo install -m 0755 /tmp/vpn-split-update /usr/local/sbin/vpn-split-update &&
sudo install -m 0755 /tmp/vpn-router-source-apply /usr/local/sbin/vpn-router-source-apply &&
sudo install -m 0644 /tmp/vpn-admin-traffic.timer /etc/systemd/system/vpn-admin-traffic.timer &&
sudo install -m 0644 /tmp/vpn-admin-status.service /etc/systemd/system/vpn-admin-status.service &&
sudo install -m 0644 /tmp/vpn-admin-status.timer /etc/systemd/system/vpn-admin-status.timer &&
sudo install -m 0644 /tmp/vpn-router-source-apply.service /etc/systemd/system/vpn-router-source-apply.service &&
WIFI_IFACE="$(nmcli -t -f DEVICE,CONNECTION device | awk -F: '\''$2=="RaspberryWiFi-AP"{print $1; exit}'\'')" &&
if [ -z "$WIFI_IFACE" ]; then WIFI_IFACE=wlan0; fi &&
UPSTREAM_IFACE="$(python3 -c '\''import json, os; p="/etc/amnezia/router-source.json"; print(json.load(open(p)).get("interface","") if os.path.exists(p) else "")'\'' 2>/dev/null || true)" &&
if [ -z "$UPSTREAM_IFACE" ]; then UPSTREAM_IFACE="$(ip route show default 0.0.0.0/0 | awk '\''{print $5; exit}'\'')" ; fi &&
if [ -z "$UPSTREAM_IFACE" ]; then UPSTREAM_IFACE=eth0; fi &&
sed -e "s/@WIFI_IFACE@/$WIFI_IFACE/g" -e "s/@UPSTREAM_IFACE@/$UPSTREAM_IFACE/g" /tmp/vpn-router.nft.template > /tmp/vpn-router.nft &&
sed -e "s/@WIFI_IFACE@/$WIFI_IFACE/g" -e "s/@UPSTREAM_IFACE@/$UPSTREAM_IFACE/g" /tmp/vpn-admin.service > /tmp/vpn-admin.service.rendered &&
sed -e "s/@WIFI_IFACE@/$WIFI_IFACE/g" -e "s/@UPSTREAM_IFACE@/$UPSTREAM_IFACE/g" /tmp/vpn-admin-traffic.service > /tmp/vpn-admin-traffic.service.rendered &&
sudo install -m 0644 /tmp/vpn-router.nft.template /etc/amnezia/vpn-router.nft.template &&
sudo touch /etc/amnezia/router-source.json /etc/amnezia/nftables.conf.tmp &&
sudo chmod 0644 /etc/amnezia/router-source.json /etc/amnezia/nftables.conf.tmp &&
sudo visudo -cf /tmp/vpn-admin-helper.sudoers &&
sudo install -m 0440 /tmp/vpn-admin-helper.sudoers /etc/sudoers.d/vpn-admin-helper &&
sudo nft -c -f /tmp/vpn-router.nft &&
sudo install -m 0644 /tmp/vpn-admin.service.rendered /etc/systemd/system/vpn-admin.service &&
sudo install -m 0644 /tmp/vpn-admin-traffic.service.rendered /etc/systemd/system/vpn-admin-traffic.service &&
sudo install -m 0644 /tmp/vpn-router.nft /etc/nftables.conf &&
sudo rm -f /etc/NetworkManager/dnsmasq-shared.d/chatgpt-nftset.conf /etc/NetworkManager/dnsmasq-shared.d/vpn-router-nftset.conf &&
sudo sh -c "nft delete table inet vpn_router 2>/dev/null || true; nft delete table ip vpn_router_nat 2>/dev/null || true; nft -f /etc/nftables.conf" &&
sudo systemctl daemon-reload &&
sudo systemctl enable nftables &&
sudo systemctl enable vpn-router-source-apply.service &&
sudo systemctl disable --now vpn-router-source-apply.timer >/dev/null 2>&1 || true &&
sudo rm -f /etc/systemd/system/vpn-router-source-apply.timer &&
sudo systemctl start vpn-router-source-apply.service &&
sudo systemctl start vpn-split-update.service &&
sudo systemctl enable --now vpn-admin-traffic.timer &&
sudo systemctl start vpn-admin-traffic.service &&
sudo systemctl enable --now vpn-admin-status.timer &&
sudo systemctl start vpn-admin-status.service &&
sudo systemctl enable --now vpn-admin &&
sudo systemctl restart vpn-admin'

ssh_pi 'systemctl --no-pager --plain is-active vpn-admin'
echo "Done. Open http://10.42.0.1/admin"
