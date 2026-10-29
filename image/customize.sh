#!/bin/bash
# Runs INSIDE the Raspberry Pi OS Lite image (chroot via GitHub Actions arm-runner).
# The image's boot partition is mounted at /boot here.
set -euxo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)"
BOOT=/boot
[ -f /boot/firmware/config.txt ] && BOOT=/boot/firmware
test -f "$BOOT/config.txt"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    gphoto2 libgphoto2-6t64 python3-zeroconf python3-pil python3-pip \
    i2c-tools avahi-daemon rfkill \
  || apt-get install -y --no-install-recommends \
    gphoto2 python3-zeroconf python3-pil python3-pip i2c-tools avahi-daemon rfkill
pip3 install --break-system-packages --no-cache-dir luma.oled
python3 -c "import zeroconf, PIL, luma.oled; print('python deps ok')"
gphoto2 --version | head -3

# --- tether service ---------------------------------------------------------
install -d /opt/jstether
install -m 755 "$SRC/pi/jstether.py" /opt/jstether/jstether.py
install -m 644 "$SRC/pi/jstether.service" /etc/systemd/system/jstether.service
: > /etc/jstether.env
systemctl enable jstether.service

# --- settings-from-SD service -------------------------------------------------
install -m 755 "$SRC/image/jstether-config" /usr/local/sbin/jstether-config
install -m 644 "$SRC/image/jstether-config.service" /etc/systemd/system/jstether-config.service
systemctl enable jstether-config.service
install -m 644 "$SRC/image/jstether.txt" "$BOOT/jstether.txt"

# --- I2C for the OLED ---------------------------------------------------------
grep -q '^dtparam=i2c_arm=on' "$BOOT/config.txt" || echo 'dtparam=i2c_arm=on' >> "$BOOT/config.txt"
grep -q '^i2c-dev' /etc/modules || echo 'i2c-dev' >> /etc/modules

# --- SSH on, no first-boot user wizard (jstether-config creates the user) -------
systemctl enable ssh || true
rm -f /etc/ssh/sshd_config.d/rename_user.conf
systemctl mask userconfig.service 2>/dev/null || true
# Newer images use cloud-init for Imager settings; we use jstether.txt instead
if [ -d /etc/cloud ]; then touch /etc/cloud/cloud-init.disabled; fi
[ -f "$BOOT/user-data" ] && mv "$BOOT/user-data" "$BOOT/user-data.unused" || true

# --- defaults ---------------------------------------------------------------
echo jstether > /etc/hostname
sed -i 's/^127\.0\.1\.1.*/127.0.1.1\tjstether/' /etc/hosts
echo "JohorStudio Tether image built $(date -u +%Y-%m-%d)" > /etc/jstether-release

# Desktop auto-mounters grab the camera; Lite has none, but make sure
systemctl --global mask gvfs-gphoto2-volume-monitor.service 2>/dev/null || true

apt-get clean
rm -rf /var/lib/apt/lists/*
echo "customize done"
