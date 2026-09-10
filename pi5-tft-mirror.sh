#!/bin/bash
# Lustrzane odbicie pulpitu HDMI na wyswietlaczu MHS 3.5" SPI (/dev/fb1)
# na Raspberry Pi 5.
#
# Dlaczego tak: dawne narzedzie fbcp opiera sie na interfejsie DispmanX,
# ktorego Raspberry Pi 5 juz nie ma. Serwer X renderuje przez DRM/KMS, wiec
# w /dev/fb0 nie ma obrazu pulpitu. Rozwiazanie: ffmpeg przechwytuje zawartosc
# ekranu :0 (x11grab), skaluje ja do rozdzielczosci wyswietlacza i zapisuje
# bezposrednio do /dev/fb1 (urzadzenie wyjsciowe fbdev).
#
# Uzycie (przez SSH):
#   bash pi5-tft-mirror.sh                 # test na zywo, Ctrl+C konczy
#   bash pi5-tft-mirror.sh --install       # start automatyczny przy kazdym boot
#   bash pi5-tft-mirror.sh --stop
#   bash pi5-tft-mirror.sh --remove
# Opcje dodatkowe:
#   --fps N     liczba klatek na sekunde (domyslnie 12)
#   --fill      rozciagnij na caly ekran zamiast zachowac proporcje

set -uo pipefail

RUNNER=/usr/local/sbin/tft-mirror-start.sh
UNIT=/etc/systemd/system/tft-mirror.service

say() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
err() { printf '\n\033[1;31mBLAD: %s\033[0m\n' "$*" >&2; }

FPS=12
FILL=0
MODE="test"
while [ $# -gt 0 ]; do
  case "$1" in
    --install) MODE="install" ;;
    --stop)    MODE="stop" ;;
    --remove)  MODE="remove" ;;
    --fps)     shift; FPS="${1:-12}" ;;
    --fill)    FILL=1 ;;
    *) err "Nieznany argument: $1"; exit 1 ;;
  esac
  shift
done

stop_all() {
  sudo systemctl stop tft-mirror.service 2>/dev/null
  sudo pkill -f "f fbdev /dev/fb1" 2>/dev/null
  sudo pkill -f "x11grab" 2>/dev/null
  # zatrzymaj tez poprzednie rozwiazanie z osobnym serwerem X
  sudo systemctl disable --now tft-screen.service 2>/dev/null
  sudo pkill -f "X :1" 2>/dev/null
  sudo pkill -f "Xorg :1" 2>/dev/null
  sleep 1
}

case "$MODE" in
  stop)
    say "Zatrzymuje odbicie na ekranie TFT"; stop_all; echo "Zatrzymane."; exit 0 ;;
  remove)
    say "Usuwam odbicie i konfiguracje pomocnicza"
    sudo systemctl disable --now tft-mirror.service 2>/dev/null
    stop_all
    sudo rm -f "$UNIT" "$RUNNER" /etc/systemd/system/tft-screen.service \
               /usr/local/sbin/tft-screen-start.sh /etc/X11/xorg-tft.conf
    sudo systemctl daemon-reload
    echo "Usuniete."; exit 0 ;;
esac

# ------------------------------------------------------------- warunki
say "Kontrola warunkow"
[ -e /dev/fb1 ] || { err "Brak /dev/fb1"; exit 1; }
FB_BPP=$(cat /sys/class/graphics/fb1/bits_per_pixel)
FB_W=$(cut -d, -f1 /sys/class/graphics/fb1/virtual_size)
FB_H=$(cut -d, -f2 /sys/class/graphics/fb1/virtual_size)
echo "Wyswietlacz: ${FB_W}x${FB_H}, ${FB_BPP} bpp"

case "$FB_BPP" in
  16) PIXFMT="rgb565le" ;;
  32) PIXFMT="bgra" ;;
  24) PIXFMT="bgr24" ;;
  *)  err "Nieobslugiwana glebia ${FB_BPP} bpp"; exit 1 ;;
esac
echo "Format pikseli: $PIXFMT"

if ! command -v ffmpeg >/dev/null; then
  say "Instaluje ffmpeg"
  sudo apt-get update -qq && sudo apt-get install -y -qq ffmpeg
fi
command -v ffmpeg >/dev/null || { err "Brak ffmpeg"; exit 1; }

ffmpeg -hide_banner -devices 2>/dev/null | grep -q " fbdev" \
  || err "Uwaga: ta wersja ffmpeg moze nie miec urzadzenia wyjsciowego fbdev"

# ------------------------------------------------------------- runner
say "Zapisuje $RUNNER"
sudo tee "$RUNNER" >/dev/null <<EOF
#!/bin/bash
# Odbija pulpit z ekranu :0 na /dev/fb1.
FPS=${FPS}
FILL=${FILL}

# plik autoryzacji serwera X uruchomionego przez menedzera logowania
for a in /var/run/lightdm/root/:0 /run/lightdm/root/:0 /home/*/.Xauthority; do
    [ -f "\$a" ] && export XAUTHORITY="\$a" && break
done
export DISPLAY=:0

# poczekaj, az pulpit wstanie
for i in \$(seq 1 60); do
    xrandr --current >/dev/null 2>&1 && break
    sleep 2
done

SRC=\$(xrandr --current 2>/dev/null | awk '/\\*/{print \$1; exit}')
[ -z "\$SRC" ] && SRC=\$(xdpyinfo 2>/dev/null | awk '/dimensions:/{print \$2; exit}')
[ -z "\$SRC" ] && SRC=1920x1080

FB_W=\$(cut -d, -f1 /sys/class/graphics/fb1/virtual_size)
FB_H=\$(cut -d, -f2 /sys/class/graphics/fb1/virtual_size)

if [ "\$FILL" = "1" ]; then
    VF="scale=\${FB_W}:\${FB_H}"
else
    VF="scale=\${FB_W}:\${FB_H}:force_original_aspect_ratio=decrease,pad=\${FB_W}:\${FB_H}:(ow-iw)/2:(oh-ih)/2:black"
fi

echo "Zrodlo: \$SRC -> \${FB_W}x\${FB_H}, \${FPS} kl/s, format ${PIXFMT}"
exec ffmpeg -hide_banner -loglevel warning \\
    -f x11grab -draw_mouse 1 -framerate "\$FPS" -video_size "\$SRC" -i :0 \\
    -vf "\$VF" -pix_fmt ${PIXFMT} -f fbdev /dev/fb1
EOF
sudo chmod 755 "$RUNNER"

# ------------------------------------------------------------- instalacja
if [ "$MODE" = "install" ]; then
  say "Instaluje usluge systemd"
  sudo tee "$UNIT" >/dev/null <<EOF
[Unit]
Description=Odbicie pulpitu HDMI na wyswietlaczu SPI 3.5
After=graphical.target
Wants=graphical.target

[Service]
Type=simple
ExecStart=$RUNNER
Restart=always
RestartSec=5
Nice=5

[Install]
WantedBy=graphical.target
EOF
  sudo systemctl daemon-reload
  stop_all
  sudo systemctl enable --now tft-mirror.service
  sleep 8
  systemctl --no-pager --lines=10 status tft-mirror.service
  echo
  echo "Spojrz na maly ekran: powinien pokazywac to samo co monitor HDMI."
  echo "Zatrzymanie:  bash pi5-tft-mirror.sh --stop"
  exit 0
fi

# ------------------------------------------------------------- test
say "Test na zywo. Ctrl+C konczy."
stop_all
sudo "$RUNNER"
