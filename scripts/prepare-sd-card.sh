#!/usr/bin/env bash
set -euo pipefail

BOOT_DIR=""
AP_SSID="Amnezia-Pi"
AP_PASSWORD="amnezia-raspi"
AP_CHANNEL="6"
AP_IPV4="10.42.0.1/24"
UPSTREAM_IFACE="eth0"
WIFI_IFACE="wlan0"
ENABLE_AP_ON_BOOT="1"
LOGIN_USER="pi"
LOGIN_PASSWORD_HASH=""
SSH_KEY=""
PI_HOSTNAME="vpn-router"
AMNEZIAWG_INSTALL_URL=""
SYSTEMD_RUN_PATH="/boot/firmware/vpn-router-firstboot.sh"

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/prepare-sd-card.sh --boot /Volumes/bootfs [options]

This prepares an already-flashed Raspberry Pi OS boot partition. It does not
format disks and it does not choose a disk device automatically.

Options:
  --boot PATH                  Mounted Raspberry Pi OS boot partition.
  --ap-ssid NAME               Wi-Fi AP SSID. Default: Amnezia-Pi
  --ap-password PASSWORD       Wi-Fi AP WPA2 password. Default: amnezia-raspi
  --ap-channel CHANNEL         Wi-Fi AP channel. Default: 6
  --ap-ipv4 CIDR               AP IPv4 address. Default: 10.42.0.1/24
  --wifi-iface IFACE           Wi-Fi interface for AP. Default: wlan0
  --upstream-iface IFACE       Default internet source interface. Default: eth0
  --no-ap-autostart            Install AP profile but do not autostart it.
  --login-user USER            User to create/configure. Default: pi
  --password-hash HASH         Linux crypt password hash for login user.
  --ssh-key PATH               Public SSH key file, or private key with .pub.
  --hostname NAME              Raspberry Pi hostname. Default: vpn-router
  --amneziawg-install-url URL  Optional installer URL if awg-quick is absent.
  --systemd-run-path PATH      First-boot script path as seen by Raspberry Pi.
                               Default: /boot/firmware/vpn-router-firstboot.sh
  -h, --help                   Show this help.

Example:
  ./scripts/prepare-sd-card.sh \
    --boot /Volumes/bootfs \
    --ssh-key ~/.ssh/id_ed25519.pub \
    --ap-ssid Amnezia-Pi \
    --ap-password 'change-me-please'
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --boot)
      BOOT_DIR="$2"
      shift 2
      ;;
    --ap-ssid)
      AP_SSID="$2"
      shift 2
      ;;
    --ap-password)
      AP_PASSWORD="$2"
      shift 2
      ;;
    --ap-channel)
      AP_CHANNEL="$2"
      shift 2
      ;;
    --ap-ipv4)
      AP_IPV4="$2"
      shift 2
      ;;
    --wifi-iface)
      WIFI_IFACE="$2"
      shift 2
      ;;
    --upstream-iface)
      UPSTREAM_IFACE="$2"
      shift 2
      ;;
    --no-ap-autostart)
      ENABLE_AP_ON_BOOT="0"
      shift
      ;;
    --login-user)
      LOGIN_USER="$2"
      shift 2
      ;;
    --password-hash)
      LOGIN_PASSWORD_HASH="$2"
      shift 2
      ;;
    --ssh-key)
      SSH_KEY="$2"
      shift 2
      ;;
    --hostname)
      PI_HOSTNAME="$2"
      shift 2
      ;;
    --amneziawg-install-url)
      AMNEZIAWG_INSTALL_URL="$2"
      shift 2
      ;;
    --systemd-run-path)
      SYSTEMD_RUN_PATH="$2"
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

if [ -z "$BOOT_DIR" ]; then
  echo "Missing required --boot PATH" >&2
  usage >&2
  exit 2
fi

if [ ! -d "$BOOT_DIR" ]; then
  echo "Boot path is not a directory: $BOOT_DIR" >&2
  exit 1
fi

CMDLINE="$BOOT_DIR/cmdline.txt"
if [ ! -f "$CMDLINE" ]; then
  echo "cmdline.txt not found in $BOOT_DIR. Is this the Raspberry Pi boot partition?" >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

ssh_public_key=""
if [ -n "$SSH_KEY" ]; then
  key_path="$SSH_KEY"
  if [ ! -f "$key_path" ] && [ -f "$key_path.pub" ]; then
    key_path="$key_path.pub"
  fi
  if [ ! -f "$key_path" ]; then
    echo "SSH public key not found: $SSH_KEY" >&2
    exit 1
  fi
  ssh_public_key="$(tr -d '\r\n' < "$key_path")"
fi

shell_quote() {
  printf "'"
  printf "%s" "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

write_env() {
  key="$1"
  value="$2"
  printf "%s=" "$key"
  shell_quote "$value"
  printf "\n"
}

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

payload_dir="$tmp_dir/amnezia-raspberry"
mkdir -p "$payload_dir"

for path in src systemd sudoers nftables provision; do
  cp -R "$PROJECT_DIR/$path" "$payload_dir/$path"
done

tar -C "$payload_dir" -czf "$BOOT_DIR/amnezia-raspberry-payload.tar.gz" .
install -m 0755 "$PROJECT_DIR/provision/firstboot.sh" "$BOOT_DIR/vpn-router-firstboot.sh"
touch "$BOOT_DIR/ssh"

{
  write_env AP_SSID "$AP_SSID"
  write_env AP_PASSWORD "$AP_PASSWORD"
  write_env AP_CHANNEL "$AP_CHANNEL"
  write_env AP_IPV4 "$AP_IPV4"
  write_env UPSTREAM_IFACE "$UPSTREAM_IFACE"
  write_env WIFI_IFACE "$WIFI_IFACE"
  write_env ENABLE_AP_ON_BOOT "$ENABLE_AP_ON_BOOT"
  write_env LOGIN_USER "$LOGIN_USER"
  write_env LOGIN_PASSWORD_HASH "$LOGIN_PASSWORD_HASH"
  write_env SSH_PUBLIC_KEY "$ssh_public_key"
  write_env PI_HOSTNAME "$PI_HOSTNAME"
  write_env AMNEZIAWG_INSTALL_URL "$AMNEZIAWG_INSTALL_URL"
} > "$BOOT_DIR/vpn-router-firstboot.env"
chmod 0600 "$BOOT_DIR/vpn-router-firstboot.env"

if [ ! -f "$CMDLINE.vpn-router.bak" ]; then
  cp "$CMDLINE" "$CMDLINE.vpn-router.bak"
fi

cmdline="$(tr -d '\n' < "$CMDLINE")"
case " $cmdline " in
  *" systemd.run="*)
    if ! printf "%s" "$cmdline" | grep -q 'vpn-router-firstboot.sh'; then
      echo "cmdline.txt already contains systemd.run=. Refusing to overwrite it." >&2
      exit 1
    fi
    ;;
esac

firstboot_args="systemd.run=$SYSTEMD_RUN_PATH systemd.run_success_action=reboot systemd.unit=kernel-command-line.target"
if ! printf "%s" "$cmdline" | grep -q 'vpn-router-firstboot.sh'; then
  printf "%s %s\n" "$cmdline" "$firstboot_args" > "$CMDLINE"
fi

echo "Prepared Raspberry Pi boot partition: $BOOT_DIR"
echo "First boot will install and configure Amnezia Raspberry."
echo "After first boot/reboot, open: http://10.42.0.1/admin"
