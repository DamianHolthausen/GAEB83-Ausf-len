#!/bin/bash
# Zmienia rozdzielczosc monitora HDMI i utrwala ja, a nastepnie przeladowuje
# odbicie obrazu na wyswietlaczu SPI.
#
# Po co: wyswietlacz ma 480x320 punktow. Im wieksza rozdzielczosc monitora,
# tym mocniej obraz jest pomniejszany i tym mniej czytelny staje sie tekst.
# Przy 1920x1080 skala wynosi okolo 0,30. Przy 640x480 okolo 0,67, czyli
# tekst jest ponad dwukrotnie wiekszy.
#
# Uzycie:
#   bash pi5-hdmi-res.sh              # pokazuje dostepne tryby i biezacy
#   bash pi5-hdmi-res.sh 640x480      # ustawia i utrwala
#   bash pi5-hdmi-res.sh auto         # wraca do trybu preferowanego monitora

set -uo pipefail

SETUP=/usr/local/sbin/x-outputs-auto.sh
A=/var/run/lightdm/root/:0
[ -f "$A" ] || A=/run/lightdm/root/:0

say() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
err() { printf '\n\033[1;31mBLAD: %s\033[0m\n' "$*" >&2; }

X() { sudo env XAUTHORITY="$A" DISPLAY=:0 "$@"; }

OUT=$(X xrandr --current 2>/dev/null | awk '/ connected/{print $1; exit}')
[ -z "$OUT" ] && { err "Nie znalazlem podlaczonego wyjscia"; exit 1; }

MODE="${1:-}"
if [ -z "$MODE" ]; then
  say "Wyjscie: $OUT"
  echo "Biezacy tryb oznaczony gwiazdka, preferowany znakiem plus:"
  X xrandr --current 2>/dev/null | sed -n "/^$OUT connected/,/^[A-Za-z]/p" | grep -E "^ +[0-9]+x[0-9]+"
  echo
  echo "Skala odbicia przy typowych trybach (panel 480x320):"
  for m in 1920x1080 1280x720 1024x768 800x600 640x480; do
    w=${m%x*}; h=${m#*x}
    s=$(awk -v w="$w" -v h="$h" 'BEGIN{a=480/w; b=320/h; printf "%.2f", (a<b?a:b)}')
    printf "  %-10s skala %s\n" "$m" "$s"
  done
  echo
  echo "Ustawienie:  bash pi5-hdmi-res.sh 640x480"
  exit 0
fi

if [ "$MODE" = "auto" ]; then
  say "Wracam do trybu preferowanego monitora"
  X xrandr --output "$OUT" --auto || { err "xrandr odmowil"; exit 1; }
  NEWLINE="xrandr --auto 2>/dev/null"
else
  case "$MODE" in
    [0-9]*x[0-9]*) ;;
    *) err "Podaj tryb w postaci SZEROKOSCxWYSOKOSC, na przyklad 640x480"; exit 1 ;;
  esac
  if ! X xrandr --current 2>/dev/null | grep -qE "^ +$MODE "; then
    err "Monitor nie zglasza trybu $MODE. Dostepne:"
    X xrandr --current 2>/dev/null | grep -E "^ +[0-9]+x[0-9]+" | awk '{print "  "$1}'
    exit 1
  fi
  say "Ustawiam $OUT na $MODE"
  X xrandr --output "$OUT" --mode "$MODE" || { err "xrandr odmowil"; exit 1; }
  NEWLINE="xrandr --output $OUT --mode $MODE 2>/dev/null || xrandr --auto 2>/dev/null"
fi

# --- utrwalenie w skrypcie uruchamianym przez menedzera logowania
say "Utrwalam w $SETUP"
sudo tee "$SETUP" >/dev/null <<EOF
#!/bin/bash
# Uruchamiane przez menedzera logowania tuz po starcie serwera X.
$NEWLINE
xset s off 2>/dev/null
xset s noblank 2>/dev/null
xset -dpms 2>/dev/null
exit 0
EOF
sudo chmod 755 "$SETUP"
grep -v '^#' "$SETUP" | grep -v '^$'

# --- odbicie musi przeczytac nowy rozmiar ekranu
say "Przeladowuje odbicie obrazu"
sudo systemctl restart tft-mirror.service 2>/dev/null
sleep 6
systemctl --no-pager --lines=4 status tft-mirror.service 2>/dev/null | tail -6

say "Gotowe"
X xrandr --current 2>/dev/null | head -3
echo
echo "Powrot do poprzedniego:  bash pi5-hdmi-res.sh auto"
