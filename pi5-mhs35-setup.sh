#!/bin/bash
# Konfiguracja wyswietlacza MHS 3.5" SPI TFT (ILI9486 + XPT2046) na Raspberry Pi 5
# z Raspberry Pi OS Bookworm (64-bit, pulpit).
#
# Uzycie na Pi 5:
#   curl -fsSL https://raw.githubusercontent.com/DamianHolthausen/GAEB83-Ausf-len/claude/raspberry-pi-5-network-j5j0tr/pi5-mhs35-setup.sh | bash
# Wycofanie zmian:
#   curl -fsSL https://raw.githubusercontent.com/DamianHolthausen/GAEB83-Ausf-len/claude/raspberry-pi-5-network-j5j0tr/pi5-mhs35-setup.sh | bash -s -- --rollback
#
# Dlaczego nie MHS35-show producenta: dla Debiana 12 skrypt producenta opiera sie na fbcp
# (DispmanX), ktore nie istnieje na Pi 5, i podmienia caly config.txt na szablon bez
# vc4-kms-v3d, co na Pi 5 wylacza HDMI. Ten skrypt uzywa tylko overlaya producenta
# oraz sterownika Xorg fbdev na /dev/fb1.

set -euo pipefail

CONFIG=/boot/firmware/config.txt
OVERLAYS=/boot/firmware/overlays
BACKUP="$HOME/config.txt.bak"
XORG_DIR=/etc/X11/xorg.conf.d
XORG_FBDEV="$XORG_DIR/99-fbdev-tft.conf"
XORG_CALIB="$XORG_DIR/99-calibration.conf"
EVDEV_45=/usr/share/X11/xorg.conf.d/45-evdev.conf
MARKER="# MHS 3.5\" SPI TFT (ILI9486 + XPT2046)"

say() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mBLAD: %s\033[0m\n' "$*" >&2; exit 1; }

rollback() {
  say "Wycofywanie zmian"
  if [ -f "$BACKUP" ]; then
    sudo cp "$BACKUP" "$CONFIG"
    echo "Przywrocono $CONFIG z $BACKUP"
  else
    echo "Brak kopii $BACKUP, usuwam tylko dopisane linie"
    sudo sed -i "/^$MARKER\$/,/^dtoverlay=mhs35/d" "$CONFIG"
  fi
  sudo rm -f "$XORG_FBDEV" "$XORG_CALIB" "$EVDEV_45"
  if [ -f /usr/bin/labwc ]; then
    sudo raspi-config nonint do_wayland W3
  else
    sudo raspi-config nonint do_wayland W2
  fi
  say "Gotowe. Uruchom ponownie: sudo reboot"
  exit 0
}

[ "${1:-}" = "--rollback" ] && rollback

say "Kontrola systemu"
MODEL=$(tr -d '\0' < /proc/device-tree/model || true)
echo "Model:   $MODEL"
echo "System:  $(. /etc/os-release && echo "$PRETTY_NAME")"
echo "Debian:  $(cat /etc/debian_version)"
echo "Kernel:  $(uname -r)"
echo "Framebuffery przed instalacja: $(ls /dev/fb* 2>/dev/null || echo brak)"

[[ "$MODEL" == *"Raspberry Pi 5"* ]] || die "To nie jest Raspberry Pi 5 (wykryto: $MODEL)"
[ -f "$CONFIG" ] || die "Brak $CONFIG. To nie jest Raspberry Pi OS Bookworm/Trixie."
[ -d "$OVERLAYS" ] || die "Brak katalogu $OVERLAYS"
command -v raspi-config >/dev/null || die "Brak raspi-config"

say "Kopia zapasowa config.txt -> $BACKUP"
[ -f "$BACKUP" ] || cp "$CONFIG" "$BACKUP"

say "Pobieranie overlaya producenta (goodtft/LCD-show)"
sudo apt-get update -qq
sudo apt-get install -y -qq git xserver-xorg-video-fbdev xserver-xorg-input-evdev
rm -rf "$HOME/LCD-show"
git clone -q --depth 1 https://github.com/goodtft/LCD-show.git "$HOME/LCD-show"
[ -f "$HOME/LCD-show/usr/mhs35-overlay.dtb" ] || die "Brak pliku mhs35-overlay.dtb w repozytorium producenta"
sudo cp "$HOME/LCD-show/usr/mhs35-overlay.dtb" "$OVERLAYS/mhs35.dtbo"
echo "Skopiowano $OVERLAYS/mhs35.dtbo"

say "Wpis w $CONFIG"
if grep -q "^dtoverlay=mhs35" "$CONFIG"; then
  echo "Wpis dtoverlay=mhs35 juz istnieje, pomijam"
else
  sudo tee -a "$CONFIG" >/dev/null <<EOF

$MARKER
dtparam=spi=on
dtoverlay=mhs35,rotate=90,speed=32000000
EOF
  echo "Dopisano dtparam=spi=on oraz dtoverlay=mhs35,rotate=90,speed=32000000"
fi
grep -q "^dtoverlay=vc4-kms-v3d" "$CONFIG" || echo "UWAGA: brak dtoverlay=vc4-kms-v3d w config.txt (HDMI moze nie dzialac)"

say "Przelaczenie pulpitu na X11 i autologowanie do pulpitu"
sudo raspi-config nonint do_wayland W1
sudo raspi-config nonint do_boot_behaviour B4

say "Konfiguracja Xorg: pulpit na /dev/fb1, dotyk przez evdev z kalibracja producenta"
sudo mkdir -p "$XORG_DIR"
sudo tee "$XORG_FBDEV" >/dev/null <<'EOF'
Section "Device"
    Identifier "MHS35 TFT"
    Driver     "fbdev"
    Option     "fbdev" "/dev/fb1"
EndSection
EOF
[ -f /usr/share/X11/xorg.conf.d/10-evdev.conf ] && sudo cp /usr/share/X11/xorg.conf.d/10-evdev.conf "$EVDEV_45"
sudo cp "$HOME/LCD-show/usr/99-calibration.conf-mhs35-90" "$XORG_CALIB"

say "Gotowe. Po restarcie pulpit pojawi sie na ekranie 3,5\", HDMI pokaze tylko konsole."
echo "Sprawdzenie po restarcie:  ls /dev/fb*   oraz   dmesg | grep -i -E 'ili9486|ads7846'"
echo "Wycofanie:  bash pi5-mhs35-setup.sh --rollback"
echo
read -r -p "Uruchomic ponownie teraz? [t/N] " ans </dev/tty || ans=n
case "$ans" in t|T|y|Y) sudo reboot ;; *) echo "Uruchom ponownie recznie: sudo reboot" ;; esac
