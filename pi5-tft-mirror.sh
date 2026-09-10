#!/bin/bash
# Lustrzane odbicie pulpitu HDMI na wyswietlaczu MHS 3.5" SPI na Raspberry Pi 5.
#
# Urzadzenie framebuffer jest wyszukiwane po nazwie sterownika (fb_ili9486),
# bo numer fbN zmienia sie miedzy restartami zaleznie od kolejnosci, w jakiej
# zglaszaja sie sterowniki. Raz bywa to fb0, raz fb1.
#
# Rozdzielczosc zrodla nie jest nigdzie wpisywana: ffmpeg odczytuje ja sam
# z serwera X, gdy pominie sie parametr -video_size.
#
# Dlaczego ffmpeg, a nie fbcp: fbcp opiera sie na interfejsie DispmanX, ktorego
# Raspberry Pi 5 juz nie ma. Serwer X renderuje przez DRM/KMS, wiec w emulowanym
# framebufferze nie ma obrazu pulpitu. Dlatego obraz trzeba przechwycic z ekranu
# X (x11grab) i zapisac go do urzadzenia wyswietlacza. Zapis idzie potokiem
# przez maly program pomocniczy uzywajacy write(), bo sterownik fbtft odswieza
# panel dopiero po zgloszeniu zmiany, czego zapis przez mmap nie wywoluje.
#
# Uzycie (przez SSH):
#   bash pi5-tft-mirror.sh                 # test na zywo, Ctrl+C konczy
#   bash pi5-tft-mirror.sh --install       # start automatyczny przy kazdym boot
#   bash pi5-tft-mirror.sh --stop
#   bash pi5-tft-mirror.sh --remove
# Opcje:
#   --fps N     liczba klatek na sekunde (domyslnie 12)
#   --fill      rozciagnij na caly ekran zamiast zachowac proporcje

set -uo pipefail

RUNNER=/usr/local/sbin/tft-mirror-start.sh
UNIT=/etc/systemd/system/tft-mirror.service
DEFAULTS=/etc/default/tft-mirror
FBWRITE=/usr/local/sbin/fbwrite.py

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
  sudo pkill -f "x11grab" 2>/dev/null
  # poprzednie podejscie: osobny serwer X na :1
  sudo systemctl disable --now tft-screen.service 2>/dev/null
  sudo pkill -f "X :1" 2>/dev/null
  sudo pkill -f "Xorg :1" 2>/dev/null
  sleep 1
}

case "$MODE" in
  stop)
    say "Zatrzymuje odbicie"; stop_all; echo "Zatrzymane."; exit 0 ;;
  remove)
    say "Usuwam odbicie i konfiguracje pomocnicza"
    sudo systemctl disable --now tft-mirror.service 2>/dev/null
    stop_all
    sudo rm -f "$UNIT" "$RUNNER" "$DEFAULTS" "$FBWRITE" \
               /etc/systemd/system/tft-screen.service \
               /usr/local/sbin/tft-screen-start.sh /etc/X11/xorg-tft.conf
    sudo systemctl daemon-reload
    echo "Usuniete."; exit 0 ;;
esac

# ------------------------------------------------------------- warunki
say "Kontrola warunkow"

FBSYS=""
for d in /sys/class/graphics/fb[0-9]*; do
  [ -d "$d" ] || continue
  case "$(cat "$d/name" 2>/dev/null)" in *ili9486*|*mhs*|*tft*) FBSYS="$d"; break ;; esac
done
if [ -z "$FBSYS" ]; then
  for d in /sys/class/graphics/fb[0-9]*; do
    [ -d "$d" ] || continue
    [ "$(cat "$d/virtual_size" 2>/dev/null)" = "480,320" ] && FBSYS="$d" && break
  done
fi
if [ -z "$FBSYS" ]; then
  err "Nie znalazlem wyswietlacza SPI wsrod urzadzen framebuffer"
  for d in /sys/class/graphics/fb[0-9]*; do
    [ -d "$d" ] && echo "  $(basename "$d"): $(cat "$d/name" 2>/dev/null) $(cat "$d/virtual_size" 2>/dev/null)"
  done
  exit 1
fi
echo "Wyswietlacz: /dev/$(basename "$FBSYS") ($(cat "$FBSYS/name")), $(tr ',' 'x' < "$FBSYS/virtual_size"), $(cat "$FBSYS/bits_per_pixel") bpp"

if ! command -v ffmpeg >/dev/null; then
  say "Instaluje ffmpeg"
  sudo apt-get update -qq && sudo apt-get install -y -qq ffmpeg
fi
command -v ffmpeg >/dev/null || { err "Brak ffmpeg"; exit 1; }
if ffmpeg -hide_banner -devices 2>/dev/null | grep -qE "fbdev"; then
  echo "ffmpeg: urzadzenie fbdev dostepne"
else
  err "Ta wersja ffmpeg nie ma urzadzenia fbdev - odbicie nie zadziala"
  ffmpeg -hide_banner -devices 2>/dev/null | head -20
  exit 1
fi

# ------------------------------------------------------------- ustawienia
say "Zapisuje $DEFAULTS"
printf 'FPS=%s\nFILL=%s\n' "$FPS" "$FILL" | sudo tee "$DEFAULTS" >/dev/null
cat "$DEFAULTS"

# ------------------------------------------------------------- helper zapisu
# Modul wyjsciowy fbdev w ffmpeg odwzorowuje pamiec urzadzenia (mmap) i pisze
# wprost do niej. Sterownik fbtft wysyla ramke na panel dopiero po zgloszeniu
# zmiany, co niezawodnie wywoluje dopiero zwykly zapis write(). Dlatego obraz
# idzie potokiem do tego programu, ktory po kazdej ramce ustawia pozycje na
# poczatek i zapisuje calosc jednym write().
say "Zapisuje $FBWRITE"
sudo tee "$FBWRITE" >/dev/null <<'PY_EOF'
#!/usr/bin/env python3
import os, sys

dev, w, h, bpp_bytes, stride = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
row_in = w * bpp_bytes
frame_out = stride * h

fd = os.open(dev, os.O_RDWR)
buf = bytearray(frame_out)
view = memoryview(buf)
stdin = sys.stdin.buffer

try:
    while True:
        for y in range(h):
            got = 0
            target = view[y * stride : y * stride + row_in]
            while got < row_in:
                n = stdin.readinto(target[got:])
                if not n:
                    raise EOFError
                got += n
        os.lseek(fd, 0, os.SEEK_SET)
        os.write(fd, buf)
except (EOFError, BrokenPipeError, KeyboardInterrupt):
    pass
finally:
    os.close(fd)
PY_EOF
sudo chmod 755 "$FBWRITE"

# ------------------------------------------------------------- runner
# Heredoc w cudzyslowach: tresc trafia do pliku doslownie, bez interpretacji.
say "Zapisuje $RUNNER"
sudo tee "$RUNNER" >/dev/null <<'RUNNER_EOF'
#!/bin/bash
# Odbija zawartosc pulpitu :0 na wyswietlacz SPI.
set -u

FPS=12
FILL=0
[ -r /etc/default/tft-mirror ] && . /etc/default/tft-mirror

# --- wyswietlacz: po nazwie sterownika, bo numer fbN nie jest staly
FBSYS=""
for d in /sys/class/graphics/fb[0-9]*; do
    [ -d "$d" ] || continue
    case "$(cat "$d/name" 2>/dev/null)" in *ili9486*|*mhs*|*tft*) FBSYS="$d"; break ;; esac
done
if [ -z "$FBSYS" ]; then
    for d in /sys/class/graphics/fb[0-9]*; do
        [ -d "$d" ] || continue
        [ "$(cat "$d/virtual_size" 2>/dev/null)" = "480,320" ] && FBSYS="$d" && break
    done
fi
[ -z "$FBSYS" ] && { echo "Nie znaleziono wyswietlacza SPI" >&2; exit 1; }

FBDEV="/dev/$(basename "$FBSYS")"
FB_W=$(cut -d, -f1 "$FBSYS/virtual_size")
FB_H=$(cut -d, -f2 "$FBSYS/virtual_size")
case "$(cat "$FBSYS/bits_per_pixel")" in
    16) PIXFMT=rgb565le; BYTES=2 ;;
    32) PIXFMT=bgra;     BYTES=4 ;;
    24) PIXFMT=bgr24;    BYTES=3 ;;
    *)  echo "Nieobslugiwana glebia" >&2; exit 1 ;;
esac

# --- dostep do serwera X uruchomionego przez menedzera logowania
for a in /run/lightdm/root/:0 /var/run/lightdm/root/:0 /home/*/.Xauthority; do
    [ -f "$a" ] && export XAUTHORITY="$a" && break
done
export DISPLAY=:0

# --- poczekaj na gniazdo serwera X
for i in $(seq 1 60); do
    [ -S /tmp/.X11-unix/X0 ] && break
    sleep 2
done
[ -S /tmp/.X11-unix/X0 ] || { echo "Serwer X :0 nie wstal" >&2; exit 1; }
sleep 3

# --- skalowanie: bez -video_size ffmpeg sam odczyta rozmiar ekranu
if [ "$FILL" = "1" ]; then
    VF="scale=${FB_W}:${FB_H}"
else
    VF="scale=${FB_W}:${FB_H}:force_original_aspect_ratio=decrease,pad=${FB_W}:${FB_H}:(ow-iw)/2:(oh-ih)/2:black"
fi

STRIDE=$(cat "$FBSYS/stride" 2>/dev/null)
[ -z "$STRIDE" ] && STRIDE=$(( FB_W * BYTES ))

echo "Cel: $FBDEV ${FB_W}x${FB_H}, ${FPS} kl/s, format $PIXFMT, stride $STRIDE"
set -o pipefail
ffmpeg -hide_banner -loglevel error -nostdin \
    -f x11grab -draw_mouse 1 -framerate "$FPS" -i :0 \
    -vf "$VF" -pix_fmt "$PIXFMT" -f rawvideo pipe:1 \
  | /usr/local/sbin/fbwrite.py "$FBDEV" "$FB_W" "$FB_H" "$BYTES" "$STRIDE"
RUNNER_EOF
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
  sleep 10
  systemctl --no-pager --lines=10 status tft-mirror.service
  echo
  echo "Maly ekran powinien pokazywac to samo co monitor HDMI."
  echo "Zatrzymanie:  bash pi5-tft-mirror.sh --stop"
  exit 0
fi

# ------------------------------------------------------------- test
say "Test na zywo. Ctrl+C konczy."
stop_all
sudo "$RUNNER"
