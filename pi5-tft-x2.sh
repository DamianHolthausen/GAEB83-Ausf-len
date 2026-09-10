#!/bin/bash
# Drugi, niezalezny serwer X wylacznie dla wyswietlacza MHS 3.5" SPI (/dev/fb1)
# na Raspberry Pi 5. Glowny pulpit na HDMI pozostaje nietkniety.
#
# Powod: serwer X obslugujacy karte graficzna przez KMS nie przyjmuje drugiego
# ekranu prowadzonego przez sterownik fbdev - sterownik jest ladowany i po chwili
# wyladowywany bez komunikatu bledu. Osobny serwer X omija ten mechanizm, bo nie
# dotyka w ogole urzadzen DRM.
#
# Uzycie (przez SSH):
#   curl -fsSL <adres-raw>/pi5-tft-x2.sh | bash              # test na zywo
#   curl -fsSL <adres-raw>/pi5-tft-x2.sh | bash -s -- --install "polecenie"
#   curl -fsSL <adres-raw>/pi5-tft-x2.sh | bash -s -- --stop
#   curl -fsSL <adres-raw>/pi5-tft-x2.sh | bash -s -- --remove

set -uo pipefail

CONF=/etc/X11/xorg-tft.conf
LOG=/tmp/xorg-tft.log
UNIT=/etc/systemd/system/tft-screen.service
RUNNER=/usr/local/sbin/tft-screen-start.sh
DISP=:1

say() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
err() { printf '\n\033[1;31mBLAD: %s\033[0m\n' "$*" >&2; }

stop_x() {
  sudo systemctl stop tft-screen.service 2>/dev/null
  sudo pkill -f "Xorg $DISP" 2>/dev/null
  sudo pkill -f "X $DISP" 2>/dev/null
  sleep 1
}

case "${1:-}" in
  --stop)
    say "Zatrzymuje ekran TFT"; stop_x; echo "Zatrzymane."; exit 0 ;;
  --remove)
    say "Usuwam konfiguracje ekranu TFT"
    sudo systemctl disable --now tft-screen.service 2>/dev/null
    stop_x
    sudo rm -f "$UNIT" "$RUNNER" "$CONF"
    sudo systemctl daemon-reload
    echo "Usuniete."; exit 0 ;;
esac

# ---------------------------------------------------------------- warunki
say "Kontrola warunkow"
[ -e /dev/fb1 ] || { err "Brak /dev/fb1"; exit 1; }
FB1_BPP=$(cat /sys/class/graphics/fb1/bits_per_pixel 2>/dev/null || echo 16)
FB1_RES=$(tr ',' 'x' < /sys/class/graphics/fb1/virtual_size 2>/dev/null || echo 480x320)
echo "fb1: $FB1_RES, ${FB1_BPP} bpp"

MISSING=""
command -v X          >/dev/null || MISSING="$MISSING xserver-xorg-core"
command -v xset       >/dev/null || MISSING="$MISSING x11-xserver-utils"
command -v xsetroot    >/dev/null || MISSING="$MISSING x11-xserver-utils"
dpkg -l xserver-xorg-video-fbdev 2>/dev/null | grep -q "^ii" || MISSING="$MISSING xserver-xorg-video-fbdev"
if [ -n "$MISSING" ]; then
  say "Instaluje brakujace pakiety:$MISSING"
  sudo apt-get update -qq
  sudo apt-get install -y -qq $MISSING
fi

# ---------------------------------------------------------------- konfiguracja
say "Zapisuje $CONF"
sudo tee "$CONF" >/dev/null <<EOF
# Serwer X tylko dla wyswietlacza MHS 3.5" SPI na /dev/fb1.
# AutoAddDevices=false: ten serwer nie przejmuje myszy ani klawiatury,
# zeby nie odbierac ich glownemu pulpitowi na HDMI.

Section "ServerFlags"
    Option "AutoAddGPU"     "false"
    Option "AutoAddDevices" "false"
    Option "DontVTSwitch"   "true"
    Option "BlankTime"      "0"
    Option "StandbyTime"    "0"
    Option "SuspendTime"    "0"
    Option "OffTime"        "0"
EndSection

Section "Device"
    Identifier  "MHS35-TFT"
    Driver      "fbdev"
    Option      "fbdev"    "/dev/fb1"
    Option      "ShadowFB" "true"
EndSection

Section "Monitor"
    Identifier  "Monitor-TFT"
EndSection

Section "Screen"
    Identifier   "Screen-TFT"
    Device       "MHS35-TFT"
    Monitor      "Monitor-TFT"
    DefaultDepth $FB1_BPP
    SubSection "Display"
        Depth $FB1_BPP
        Modes "${FB1_RES}"
    EndSubSection
EndSection

Section "ServerLayout"
    Identifier  "Tylko TFT"
    Screen 0    "Screen-TFT"
EndSection
EOF

# ---------------------------------------------------------------- co pokazac
APP="${2:-}"
if [ "${1:-}" != "--install" ]; then APP=""; fi
if [ -z "$APP" ]; then
  if   command -v lxterminal >/dev/null; then APP="lxterminal --geometry=60x20"
  elif command -v xterm      >/dev/null; then APP="xterm"
  else APP=""
  fi
fi

# ---------------------------------------------------------------- runner
say "Zapisuje $RUNNER"
sudo tee "$RUNNER" >/dev/null <<EOF
#!/bin/bash
# Uruchamia serwer X na $DISP dla /dev/fb1, a w nim wskazany program.
export DISPLAY=$DISP
/usr/bin/X $DISP -config $CONF -logfile $LOG -nolisten tcp -sharevts -novtswitch vt7 &
XPID=\$!
for i in \$(seq 1 30); do
    if xset -display $DISP q >/dev/null 2>&1; then break; fi
    sleep 0.5
done
if ! xset -display $DISP q >/dev/null 2>&1; then
    echo "Serwer X na $DISP nie wstal - zobacz $LOG" >&2
    kill \$XPID 2>/dev/null
    exit 1
fi
xsetroot -display $DISP -solid "#103050"
xset -display $DISP s off -dpms 2>/dev/null
${APP:+DISPLAY=$DISP $APP &}
wait \$XPID
EOF
sudo chmod 755 "$RUNNER"

# ---------------------------------------------------------------- instalacja na stale
if [ "${1:-}" = "--install" ]; then
  say "Instaluje usluge systemd (start przy kazdym uruchomieniu Pi)"
  sudo tee "$UNIT" >/dev/null <<EOF
[Unit]
Description=Ekran MHS 3.5 SPI jako osobny serwer X
After=graphical.target
Wants=graphical.target

[Service]
Type=simple
ExecStart=$RUNNER
Restart=on-failure
RestartSec=5

[Install]
WantedBy=graphical.target
EOF
  sudo systemctl daemon-reload
  stop_x
  sudo systemctl enable --now tft-screen.service
  sleep 6
  systemctl --no-pager --lines=5 status tft-screen.service
  echo
  echo "Program na malym ekranie: ${APP:-brak, samo tlo}"
  exit 0
fi

# ---------------------------------------------------------------- test na zywo
say "Test: uruchamiam serwer X na $DISP (bez instalacji na stale)"
stop_x
sudo "$RUNNER" &
sleep 8

if pgrep -f "X $DISP" >/dev/null; then
  say "Serwer X na $DISP dziala"
  echo "Spojrz na maly ekran. Powinno byc ciemnoniebieskie tlo${APP:+ oraz okno programu}."
  echo
  echo "Jesli widzisz obraz, zainstaluj na stale:"
  echo "  curl -fsSL <adres>/pi5-tft-x2.sh | bash -s -- --install \"chromium-browser --kiosk http://homeassistant.local:8123\""
  echo "Zatrzymanie testu:  curl -fsSL <adres>/pi5-tft-x2.sh | bash -s -- --stop"
else
  err "Serwer X na $DISP nie wstal"
  echo "--- ostatnie linie $LOG ---"
  sudo grep -vE "Modeline|EDID" "$LOG" 2>/dev/null | tail -30
fi
