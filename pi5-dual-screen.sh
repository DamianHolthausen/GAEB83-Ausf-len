#!/bin/bash
# Dwa ekrany naraz na Raspberry Pi 5: monitor HDMI (KMS/modesetting)
# oraz wyswietlacz MHS 3.5" SPI (/dev/fb1, sterownik fbdev).
#
# Uzycie na Pi (bez klawiatury):
#   skopiuj plik do katalogu domowego, prawym -> Properties -> Permissions
#   -> Make the file executable, potem dwuklik -> Execute in Terminal.
#
# Wycofanie:  bash pi5-dual-screen.sh --rollback
#
# Zabezpieczenie: instalowana jest jednorazowa usluga systemd, ktora po starcie
# sprawdza, czy serwer X wstal. Jesli nie, sama usuwa /etc/X11/xorg.conf
# i restartuje Pi. Dzieki temu bledna konfiguracja nie zablokuje systemu,
# nawet gdy nie masz podlaczonej klawiatury.

set -uo pipefail

XORG_CONF=/etc/X11/xorg.conf
XORG_BAK=/etc/X11/xorg.conf.przed-dual
OLD_FBDEV=/etc/X11/xorg.conf.d/99-fbdev-tft.conf
FAILSAFE_SH=/usr/local/sbin/x-failsafe.sh
FAILSAFE_UNIT=/etc/systemd/system/x-failsafe.service

say() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
err() { printf '\n\033[1;31mBLAD: %s\033[0m\n' "$*" >&2; }
finish() { echo; echo "To okno zamknie sie za 90 s."; sleep 90; exit "${1:-0}"; }

# --- katalog na diagnostyke: pendrive, jesli jest, inaczej katalog domowy ---
OUT_DIR="$HOME"
for d in /media/*/*; do
  if [ -d "$d" ] && [ -w "$d" ]; then OUT_DIR="$d"; break; fi
done
DIAG="$OUT_DIR/pi5-diagnostyka.txt"

rollback() {
  say "Wycofywanie konfiguracji dwuekranowej"
  sudo rm -f "$XORG_CONF"
  if [ -f "$XORG_BAK" ]; then sudo cp "$XORG_BAK" "$XORG_CONF"; fi
  sudo systemctl disable x-failsafe.service 2>/dev/null
  sudo rm -f "$FAILSAFE_UNIT" "$FAILSAFE_SH"
  sudo systemctl daemon-reload 2>/dev/null
  say "Gotowe. Pi zrestartuje sie za 15 s."
  sleep 15
  sudo reboot
}

[ "${1:-}" = "--rollback" ] && rollback

# ============================ DIAGNOSTYKA ============================
say "Zbieram diagnostyke -> $DIAG"
{
  echo "===== data: $(date) ====="
  echo "--- model / system"
  tr -d '\0' < /proc/device-tree/model; echo
  . /etc/os-release && echo "$PRETTY_NAME"
  cat /etc/debian_version
  uname -a
  echo "--- framebuffery"
  ls -l /dev/fb* 2>&1
  for f in /sys/class/graphics/fb*; do
    [ -e "$f" ] || continue
    echo "$f: name=$(cat $f/name 2>/dev/null) size=$(cat $f/virtual_size 2>/dev/null) bpp=$(cat $f/bits_per_pixel 2>/dev/null)"
  done
  echo "--- DRM"
  ls -l /dev/dri 2>&1
  for s in /sys/class/drm/card*/status; do
    [ -f "$s" ] && echo "$(dirname $s | xargs basename): $(cat $s)"
  done
  echo "--- sterowniki jadra"
  dmesg | grep -i -E "ili9486|ads7846|fbtft|fb1|vc4|drm" | tail -40
  echo "--- cmdline"
  cat /proc/cmdline
  echo "--- config.txt (istotne linie)"
  grep -v -E "^\s*#|^\s*$" /boot/firmware/config.txt
  echo "--- sesja graficzna"
  grep -E "^(user-session|autologin-session|greeter-session)" /etc/lightdm/lightdm.conf 2>/dev/null
  pgrep -a Xorg 2>/dev/null || echo "Xorg nie dziala"
  pgrep -a labwc 2>/dev/null; pgrep -a wayfire 2>/dev/null
  echo "--- pliki xorg.conf.d"
  ls -l /etc/X11/xorg.conf.d/ /usr/share/X11/xorg.conf.d/ 2>&1
  echo "--- log Xorg: urzadzenia i ekrany"
  grep -i -E "\(EE\)|\(WW\).*(fbdev|modeset)|fbdev|modeset|Screen|Output" /var/log/Xorg.0.log 2>/dev/null | tail -40
  echo "--- urzadzenia wejsciowe"
  cat /proc/bus/input/devices 2>/dev/null | grep -A2 -i -E "ADS7846|touch"
} > "$DIAG" 2>&1
echo "Zapisano. Ten plik mozesz wyslac do analizy."

# ============================ KONTROLA ============================
say "Kontrola warunkow"
if [ ! -e /dev/fb1 ]; then
  err "Brak /dev/fb1 - sterownik wyswietlacza 3,5\" nie zaladowal sie."
  echo "Sprawdz w $DIAG sekcje 'sterowniki jadra'."
  finish 1
fi
echo "OK: /dev/fb1 istnieje"

FB1_BPP=$(cat /sys/class/graphics/fb1/bits_per_pixel 2>/dev/null || echo 16)
FB1_SIZE=$(cat /sys/class/graphics/fb1/virtual_size 2>/dev/null || echo "480,320")
echo "OK: fb1 = ${FB1_SIZE} px, ${FB1_BPP} bpp"

# karta KMS z podlaczonym HDMI
KMSDEV=""
for s in /sys/class/drm/card*-HDMI-A-*/status; do
  [ -f "$s" ] || continue
  if [ "$(cat "$s" 2>/dev/null)" = "connected" ]; then
    conn=$(basename "$(dirname "$s")")     # np. card1-HDMI-A-1
    KMSDEV="/dev/dri/${conn%%-*}"          # np. /dev/dri/card1
    echo "OK: HDMI podlaczony na $conn -> $KMSDEV"
    break
  fi
done
if [ -z "$KMSDEV" ]; then
  err "Nie wykryto podlaczonego monitora HDMI. Podlacz monitor i uruchom ponownie."
  finish 1
fi

if ! dpkg -l xserver-xorg-video-fbdev 2>/dev/null | grep -q "^ii"; then
  say "Instaluje brakujacy sterownik fbdev"
  sudo apt-get update -qq && sudo apt-get install -y -qq xserver-xorg-video-fbdev
fi

# ============================ KONFIGURACJA ============================
say "Zapisuje $XORG_CONF (HDMI = ekran 0, TFT = ekran 1)"
[ -f "$XORG_CONF" ] && [ ! -f "$XORG_BAK" ] && sudo cp "$XORG_CONF" "$XORG_BAK"
sudo rm -f "$OLD_FBDEV"

sudo tee "$XORG_CONF" >/dev/null <<EOF
# Wygenerowane przez pi5-dual-screen.sh
# Ekran 0: monitor HDMI (KMS). Ekran 1: MHS 3.5" SPI TFT na /dev/fb1.

Section "ServerFlags"
    Option "AutoAddGPU" "false"
    Option "DontZap"    "false"
EndSection

Section "Device"
    Identifier  "HDMI-KMS"
    Driver      "modesetting"
    Option      "kmsdev" "$KMSDEV"
    Option      "AccelMethod" "glamor"
EndSection

Section "Device"
    Identifier  "MHS35-TFT"
    Driver      "fbdev"
    Option      "fbdev" "/dev/fb1"
    Option      "ShadowFB" "true"
EndSection

Section "Monitor"
    Identifier  "Monitor-HDMI"
EndSection

Section "Monitor"
    Identifier  "Monitor-TFT"
EndSection

Section "Screen"
    Identifier   "Screen-HDMI"
    Device       "HDMI-KMS"
    Monitor      "Monitor-HDMI"
    DefaultDepth 24
EndSection

Section "Screen"
    Identifier   "Screen-TFT"
    Device       "MHS35-TFT"
    Monitor      "Monitor-TFT"
    DefaultDepth $FB1_BPP
EndSection

Section "ServerLayout"
    Identifier  "Dwa ekrany"
    Screen 0    "Screen-HDMI" 0 0
    Screen 1    "Screen-TFT" RightOf "Screen-HDMI"
    Option      "Xinerama" "off"
EndSection
EOF
echo "Zapisano."

# ============================ ZABEZPIECZENIE ============================
say "Instaluje zabezpieczenie (automatyczne cofniecie, jesli X nie wstanie)"
sudo tee "$FAILSAFE_SH" >/dev/null <<'EOF'
#!/bin/bash
# Jednorazowa siatka bezpieczenstwa po zmianie xorg.conf.
sleep 75
systemctl disable x-failsafe.service
if pgrep -x Xorg >/dev/null; then
    logger -t x-failsafe "Xorg dziala, konfiguracja zachowana."
    exit 0
fi
logger -t x-failsafe "Xorg nie wstal - usuwam /etc/X11/xorg.conf i restartuje."
rm -f /etc/X11/xorg.conf
[ -f /etc/X11/xorg.conf.przed-dual ] && cp /etc/X11/xorg.conf.przed-dual /etc/X11/xorg.conf
sync
reboot
EOF
sudo chmod 755 "$FAILSAFE_SH"

sudo tee "$FAILSAFE_UNIT" >/dev/null <<EOF
[Unit]
Description=Cofniecie xorg.conf, jesli serwer X nie wstal
After=graphical.target

[Service]
Type=oneshot
ExecStart=$FAILSAFE_SH

[Install]
WantedBy=graphical.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable x-failsafe.service >/dev/null 2>&1 && echo "Zabezpieczenie aktywne."

# ============================ SSH / HASLO ============================
say "SSH i haslo"
sudo raspi-config nonint do_ssh 0 2>/dev/null
for f in "$OUT_DIR/haslo.txt" /media/*/*/haslo.txt; do
  [ -f "$f" ] || continue
  NEW_PW=$(head -n1 "$f" | sed 's/^\xEF\xBB\xBF//' | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  if [ ${#NEW_PW} -ge 6 ]; then
    printf '%s:%s\n' "$(whoami)" "$NEW_PW" | sudo chpasswd && echo "Haslo uzytkownika $(whoami) ustawione." && rm -f "$f"
  else
    err "haslo.txt ma mniej niz 6 znakow, pomijam."
  fi
  break
done
IP=$(hostname -I 2>/dev/null | awk '{print $1}')
echo "Logowanie z laptopa:  ssh $(whoami)@$IP"

# ============================ KONIEC ============================
say "Gotowe"
cat <<EOF
Po restarcie:
  - monitor HDMI  = ekran glowny z pulpitem i panelem
  - ekran 3,5"    = drugi ekran X (:0.1), poczatkowo szare tlo bez panelu
  - kursor myszy przechodzi na maly ekran, wychodzac prawa krawedzia HDMI

Aby uruchomic program na malym ekranie:
  DISPLAY=:0.1 chromium-browser --kiosk http://homeassistant.local:8123 &

Jesli cos pojdzie nie tak, Pi samo cofnie zmiane po okolo 90 s i zrestartuje sie.
Reczne cofniecie:  bash pi5-dual-screen.sh --rollback
Diagnostyka:       $DIAG
EOF
for i in 20 15 10 5 3 2 1; do
  printf '\rRestart za %2d s (Ctrl+C przerywa)...' "$i"; sleep 1
done
echo
sudo reboot
