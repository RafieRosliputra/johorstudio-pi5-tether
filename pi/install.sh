#!/usr/bin/env bash
# JohorStudio Tether - install on Raspberry Pi 5 (Raspberry Pi OS Lite, Bookworm or newer)
# Usage:  sudo bash install.sh
set -euo pipefail
cd "$(dirname "$0")"

if [[ $EUID -ne 0 ]]; then echo "Run with sudo"; exit 1; fi

echo "==> Installing packages"
apt-get update
apt-get install -y gphoto2 python3-zeroconf python3-pil python3-pip i2c-tools avahi-daemon

echo "==> Installing OLED library (luma.oled)"
pip3 install --break-system-packages --quiet luma.oled || echo "   (OLED lib failed - service still works without screen)"

echo "==> Enabling I2C for the OLED"
if command -v raspi-config >/dev/null; then raspi-config nonint do_i2c 0 || true; fi

echo "==> Stopping desktop auto-mount that grabs the camera (if present)"
for u in gvfs-gphoto2-volume-monitor.service; do
  systemctl --global mask "$u" 2>/dev/null || true
done
pkill -f gvfs-gphoto2-volume-monitor 2>/dev/null || true
pkill -f gvfsd-gphoto2 2>/dev/null || true

echo "==> Installing service"
install -d /opt/jstether /var/lib/jstether
install -m 755 jstether.py /opt/jstether/jstether.py
install -m 644 jstether.service /etc/systemd/system/jstether.service
systemctl daemon-reload
systemctl enable --now jstether.service

echo
echo "Done. Check status:   sudo systemctl status jstether"
echo "Live log:             sudo journalctl -u jstether -f"
echo "I2C OLED check:       sudo i2cdetect -y 1   (should show 3c)"
