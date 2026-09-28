#!/bin/sh
set -eu

LOG=/var/log/vpn-router-firstboot.log
exec >> "$LOG" 2>&1

echo "== VPN router first boot started: $(date -Is) =="

BOOT_DIR=/boot/firmware
if [ ! -d "$BOOT_DIR" ]; then
  BOOT_DIR=/boot
fi

ENV_FILE="$BOOT_DIR/vpn-router-firstboot.env"
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  . "$ENV_FILE"
fi

AP_SSID=${AP_SSID:-Amnezia-Pi}
AP_PASSWORD=${AP_PASSWORD:-amnezia-raspi}
AP_IPV4=${AP_IPV4:-10.42.0.1/24}
AP_CHANNEL=${AP_CHANNEL:-auto}
UPSTREAM_IFACE=${UPSTREAM_IFACE:-eth0}
WIFI_IFACE=${WIFI_IFACE:-wlan0}
ENABLE_AP_ON_BOOT=${ENABLE_AP_ON_BOOT:-1}
AMNEZIAWG_INSTALL_URL=${AMNEZIAWG_INSTALL_URL:-}
LOGIN_USER=${LOGIN_USER:-pi}
LOGIN_PASSWORD_HASH=${LOGIN_PASSWORD_HASH:-}
SSH_PUBLIC_KEY=${SSH_PUBLIC_KEY:-}
PI_HOSTNAME=${PI_HOSTNAME:-vpn-router}

PAYLOAD="$BOOT_DIR/amnezia-raspberry-payload.tar.gz"
WORK_DIR=/opt/amnezia-raspberry-provision
if [ ! -f "$PAYLOAD" ]; then
  echo "Payload not found: $PAYLOAD"
  exit 1
fi

cleanup_cmdline() {
  for cmdline in /boot/firmware/cmdline.txt /boot/cmdline.txt; do
    [ -f "$cmdline" ] || continue
    python3 - "$cmdline" <<'PY'
import sys
path = sys.argv[1]
remove_exact = {
    "systemd.run=/boot/firmware/vpn-router-firstboot.sh",
    "systemd.run=/boot/vpn-router-firstboot.sh",
    "systemd.run_success_action=reboot",
    "systemd.unit=kernel-command-line.target",
}
with open(path, "r", encoding="utf-8") as file:
    parts = file.read().strip().split()
parts = [part for part in parts if part not in remove_exact]
with open(path, "w", encoding="utf-8") as file:
    file.write(" ".join(parts) + "\n")
PY
  done
}

if [ "${VPN_ROUTER_FIRSTBOOT_STAGE:-stage}" != "configure" ]; then
  echo "Installing deferred first-boot service."
  cat > /etc/systemd/system/vpn-router-firstboot.service <<EOF
[Unit]
Description=Finish VPN router provisioning
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
Environment=VPN_ROUTER_FIRSTBOOT_STAGE=configure
ExecStart=$BOOT_DIR/vpn-router-firstboot.sh

[Install]
WantedBy=multi-user.target
EOF
  cleanup_cmdline
  systemctl daemon-reload
  systemctl enable vpn-router-firstboot.service
  echo "Deferred first-boot service installed. Rebooting into configure stage."
  exit 0
fi

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
tar -xzf "$PAYLOAD" -C "$WORK_DIR"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
  bc \
  build-essential \
  ca-certificates \
  curl \
  dkms \
  dnscrypt-proxy \
  dnsutils \
  iproute2 \
  iw \
  network-manager \
  nftables \
  python3 \
  sudo \
  wireguard-tools

if [ ! -d "/lib/modules/$(uname -r)/build" ]; then
  apt-get install -y "linux-headers-$(uname -r)" || apt-get install -y raspberrypi-kernel-headers
fi

if [ -n "$PI_HOSTNAME" ]; then
  hostnamectl set-hostname "$PI_HOSTNAME" || true
fi

if [ -n "$LOGIN_USER" ] && ! id "$LOGIN_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash -G sudo,adm,dialout,cdrom,audio,video,plugdev,users,input,render,netdev "$LOGIN_USER"
fi

if [ -n "$LOGIN_USER" ] && [ -n "$LOGIN_PASSWORD_HASH" ]; then
  usermod --password "$LOGIN_PASSWORD_HASH" "$LOGIN_USER"
fi

if [ -n "$LOGIN_USER" ] && [ -n "$SSH_PUBLIC_KEY" ]; then
  home_dir="$(getent passwd "$LOGIN_USER" | cut -d: -f6)"
  install -d -m 0700 -o "$LOGIN_USER" -g "$LOGIN_USER" "$home_dir/.ssh"
  printf "%s\n" "$SSH_PUBLIC_KEY" > "$home_dir/.ssh/authorized_keys"
  chown "$LOGIN_USER:$LOGIN_USER" "$home_dir/.ssh/authorized_keys"
  chmod 0600 "$home_dir/.ssh/authorized_keys"
fi

if ! command -v awg-quick >/dev/null 2>&1; then
  if apt-cache show amneziawg-tools >/dev/null 2>&1; then
    apt-get install -y amneziawg-tools || true
  fi
fi

if ! command -v awg-quick >/dev/null 2>&1 && [ -n "$AMNEZIAWG_INSTALL_URL" ]; then
  curl -fsSL "$AMNEZIAWG_INSTALL_URL" | sh
fi

install -d -m 0755 /usr/local/sbin
install -d -m 0755 /etc/systemd/system
install -d -m 0755 /etc/sudoers.d
install -d -m 0755 /etc/sysctl.d
install -d -m 0755 /etc/NetworkManager/dnsmasq-shared.d
install -d -m 0755 /etc/amnezia
install -d -m 0755 /etc/amnezia/cpufreq
install -d -m 0700 /etc/amnezia/amneziawg
install -d -m 0700 /etc/amnezia/amneziawg/profiles
install -d -m 0700 /etc/amnezia/vless

install -m 0755 "$WORK_DIR/src/vpn-admin-server" /usr/local/sbin/vpn-admin-server
install -m 0755 "$WORK_DIR/src/vpn-admin-helper" /usr/local/sbin/vpn-admin-helper
install -m 0755 "$WORK_DIR/src/vpn-admin-traffic-snapshot" /usr/local/sbin/vpn-admin-traffic-snapshot
install -m 0755 "$WORK_DIR/src/vpn-admin-status-snapshot" /usr/local/sbin/vpn-admin-status-snapshot
install -m 0755 "$WORK_DIR/src/vpn-admin-system-snapshot" /usr/local/sbin/vpn-admin-system-snapshot
install -m 0755 "$WORK_DIR/provision/bin/vpn-split-update" /usr/local/sbin/vpn-split-update
install -m 0755 "$WORK_DIR/provision/bin/vpn-router-configure-ap-security" /usr/local/sbin/vpn-router-configure-ap-security
install -m 0755 "$WORK_DIR/provision/bin/vpn-router-start-ap" /usr/local/sbin/vpn-router-start-ap
install -m 0755 "$WORK_DIR/provision/bin/vpn-router-stop-ap" /usr/local/sbin/vpn-router-stop-ap
install -m 0755 "$WORK_DIR/provision/bin/vpn-router-status" /usr/local/sbin/vpn-router-status
install -m 0755 "$WORK_DIR/provision/bin/vpn-router-wifi-channel" /usr/local/sbin/vpn-router-wifi-channel
install -m 0755 "$WORK_DIR/provision/bin/vpn-router-source-apply" /usr/local/sbin/vpn-router-source-apply
install -m 0755 "$WORK_DIR/provision/bin/vpn-router-vpn-watchdog" /usr/local/sbin/vpn-router-vpn-watchdog
install -m 0755 "$WORK_DIR/provision/bin/vpn-router-install-sing-box" /usr/local/sbin/vpn-router-install-sing-box
install -m 0755 "$WORK_DIR/provision/bin/vpn-router-vless-route-up" /usr/local/sbin/vpn-router-vless-route-up
install -m 0755 "$WORK_DIR/provision/bin/vpn-router-vless-route-down" /usr/local/sbin/vpn-router-vless-route-down
/usr/local/sbin/vpn-router-install-sing-box
install -m 0755 "$WORK_DIR/provision/bin/vpn-router-cpufreq" /usr/local/sbin/vpn-router-cpufreq
install -m 0755 "$WORK_DIR/provision/bin/vpn-router-configure-cpufreq" /usr/local/sbin/vpn-router-configure-cpufreq
install -m 0755 "$WORK_DIR/provision/bin/vpn-router-install-archer-driver" /usr/local/sbin/vpn-router-install-archer-driver
install -m 0644 "$WORK_DIR/provision/router/8821au.conf" /etc/modprobe.d/8821au.conf
/usr/local/sbin/vpn-router-install-archer-driver

sed -e "s/@WIFI_IFACE@/$WIFI_IFACE/g" -e "s/@UPSTREAM_IFACE@/$UPSTREAM_IFACE/g" "$WORK_DIR/systemd/vpn-admin.service" > /etc/systemd/system/vpn-admin.service
chmod 0644 /etc/systemd/system/vpn-admin.service
sed -e "s/@WIFI_IFACE@/$WIFI_IFACE/g" -e "s/@UPSTREAM_IFACE@/$UPSTREAM_IFACE/g" "$WORK_DIR/systemd/vpn-admin-traffic.service" > /etc/systemd/system/vpn-admin-traffic.service
chmod 0644 /etc/systemd/system/vpn-admin-traffic.service
install -m 0644 "$WORK_DIR/systemd/vpn-admin-traffic.timer" /etc/systemd/system/vpn-admin-traffic.timer
install -m 0644 "$WORK_DIR/systemd/vpn-admin-status.service" /etc/systemd/system/vpn-admin-status.service
install -m 0644 "$WORK_DIR/systemd/vpn-admin-status.timer" /etc/systemd/system/vpn-admin-status.timer
install -m 0644 "$WORK_DIR/systemd/vpn-admin-system.service" /etc/systemd/system/vpn-admin-system.service
install -m 0644 "$WORK_DIR/systemd/vpn-admin-system.timer" /etc/systemd/system/vpn-admin-system.timer
install -m 0644 "$WORK_DIR/provision/systemd/vpn-split-update.service" /etc/systemd/system/vpn-split-update.service
install -m 0644 "$WORK_DIR/provision/systemd/vpn-split-update.timer" /etc/systemd/system/vpn-split-update.timer
install -m 0644 "$WORK_DIR/systemd/vpn-router-source-apply.service" /etc/systemd/system/vpn-router-source-apply.service
install -m 0644 "$WORK_DIR/systemd/vpn-router-source-apply.timer" /etc/systemd/system/vpn-router-source-apply.timer
install -m 0644 "$WORK_DIR/systemd/vpn-router-wifi-channel.service" /etc/systemd/system/vpn-router-wifi-channel.service
install -m 0644 "$WORK_DIR/systemd/vpn-router-vpn-watchdog.service" /etc/systemd/system/vpn-router-vpn-watchdog.service
install -m 0644 "$WORK_DIR/systemd/vpn-router-vpn-watchdog.timer" /etc/systemd/system/vpn-router-vpn-watchdog.timer
install -m 0644 "$WORK_DIR/systemd/sing-box-vless.service" /etc/systemd/system/sing-box-vless.service
install -m 0644 "$WORK_DIR/systemd/vpn-router-fan-apply.service" /etc/systemd/system/vpn-router-fan-apply.service
install -m 0644 "$WORK_DIR/systemd/vpn-router-cpufreq.service" /etc/systemd/system/vpn-router-cpufreq.service

install -m 0644 "$WORK_DIR/provision/router/99-vpn-router.conf" /etc/sysctl.d/99-vpn-router.conf
install -m 0644 "$WORK_DIR/provision/router/dnsmasq-upstream.conf" /etc/NetworkManager/dnsmasq-shared.d/vpn-router-upstream.conf
install -m 0644 "$WORK_DIR/provision/router/vpn-split-domains.txt" /etc/vpn-split-domains.txt
install -m 0644 "$WORK_DIR/nftables/vpn-router.nft" /etc/amnezia/vpn-router.nft.template
touch /etc/amnezia/router-source.json /etc/amnezia/nftables.conf.tmp /etc/amnezia/cpufreq/max-khz
chmod 0644 /etc/amnezia/router-source.json /etc/amnezia/nftables.conf.tmp /etc/amnezia/cpufreq/max-khz
if [ ! -s /etc/amnezia/cpufreq/max-khz ]; then
  install -m 0644 "$WORK_DIR/provision/router/cpufreq-max-khz" /etc/amnezia/cpufreq/max-khz
fi
/usr/local/sbin/vpn-router-configure-cpufreq
sed -e "s/@WIFI_IFACE@/$WIFI_IFACE/g" -e "s/@UPSTREAM_IFACE@/$UPSTREAM_IFACE/g" "$WORK_DIR/nftables/vpn-router.nft" > /etc/nftables.conf
chmod 0644 /etc/nftables.conf
install -m 0440 "$WORK_DIR/sudoers/vpn-admin-helper" /etc/sudoers.d/vpn-admin-helper
visudo -cf /etc/sudoers.d/vpn-admin-helper

rm -f \
  /etc/NetworkManager/dnsmasq-shared.d/chatgpt-nftset.conf \
  /etc/NetworkManager/dnsmasq-shared.d/vpn-router-nftset.conf

sysctl --system || true

systemctl enable NetworkManager
systemctl enable ssh || true
systemctl enable nftables
systemctl enable --now dnscrypt-proxy.socket || true
systemctl enable --now dnscrypt-proxy.service || true

ap_autoconnect=no
if [ "$ENABLE_AP_ON_BOOT" = "1" ] || [ "$ENABLE_AP_ON_BOOT" = "yes" ] || [ "$ENABLE_AP_ON_BOOT" = "true" ]; then
  ap_autoconnect=yes
fi

nmcli connection delete "$AP_SSID" >/dev/null 2>&1 || true
nmcli connection add type wifi ifname "$WIFI_IFACE" con-name "$AP_SSID" autoconnect "$ap_autoconnect" ssid "$AP_SSID"
nmcli connection modify "$AP_SSID" \
  802-11-wireless.mode ap \
  802-11-wireless.band a \
  802-11-wireless.channel 36 \
  802-11-wireless.channel-width 0 \
  802-11-wireless.powersave 2 \
  ipv4.method shared \
  ipv4.addresses "$AP_IPV4" \
  ipv6.method disabled \
  connection.autoconnect "$ap_autoconnect"

if [ -n "$AP_PASSWORD" ]; then
  nmcli connection modify "$AP_SSID" \
    wifi-sec.key-mgmt wpa-psk \
    wifi-sec.psk "$AP_PASSWORD"
fi

/usr/local/sbin/vpn-router-configure-ap-security "$AP_SSID"
AP_CHANNEL="$AP_CHANNEL" /usr/local/sbin/vpn-router-wifi-channel "$AP_SSID" || true

systemctl daemon-reload
systemctl enable vpn-admin
systemctl enable vpn-admin-traffic.timer
systemctl enable vpn-admin-status.timer
systemctl enable vpn-admin-system.timer
systemctl enable vpn-split-update.timer
systemctl enable vpn-router-wifi-channel.service
systemctl enable vpn-router-source-apply.service
systemctl enable vpn-router-source-apply.timer
systemctl enable vpn-router-vpn-watchdog.timer
systemctl enable vpn-router-fan-apply.service
systemctl start vpn-router-fan-apply.service
systemctl enable vpn-router-cpufreq.service

if command -v awg-quick >/dev/null 2>&1 && [ -f /etc/amnezia/amneziawg/awg0.conf ]; then
  systemctl enable awg-quick@awg0.service || true
fi

cleanup_cmdline

rm -f "$BOOT_DIR/vpn-router-firstboot.sh" "$ENV_FILE" "$PAYLOAD"
systemctl disable vpn-router-firstboot.service || true
rm -f /etc/systemd/system/vpn-router-firstboot.service
systemctl daemon-reload

echo "== VPN router first boot finished: $(date -Is) =="
systemctl reboot
