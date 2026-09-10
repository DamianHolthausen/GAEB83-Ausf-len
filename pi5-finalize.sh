#!/bin/bash
# Utrwala dzialajacy uklad na Raspberry Pi 5:
#   - monitor HDMI jako pulpit, wlaczany automatycznie przy kazdym starcie
#   - wyswietlacz MHS 3.5" SPI jako lustrzane odbicie tego pulpitu
#
# Co naprawia:
# 1. /etc/X11/xorg.conf, napisany przy nieudanej probie dwoch ekranow, wskazywal
#    karte graficzna po konkretnej nazwie urzadzenia (kmsdev) i zawieral martwa
#    sekcje ekranu na /dev/fb1. Numeracja tych urzadzen nie jest stala miedzy
#    restartami, wiec wskazanie po nazwie musialo predzej czy pozniej zawiesc.
#    Nowy plik nie wskazuje zadnego urzadzenia i pozostawia wybor sterownikowi.
# 2. Wyjscie HDMI potrafilo zostac bez ustawionego trybu, przez co monitor nie
#    dostawal sygnalu. Skrypt uruchamiany przez menedzera logowania wlacza
#    kazde podlaczone wyjscie i wylacza wygaszanie.
#
# Zabezpieczenie: jednorazowa usluga systemd sprawdza po starcie, czy serwer X
# wstal. Jesli nie, przywraca poprzedni plik konfiguracyjny i restartuje Pi.
#
# Uzycie:  bash pi5-finalize.sh          (na koncu restartuje Pi)
#          bash pi5-finalize.sh --rollback

set -uo pipefail

XORG=/etc/X11/xorg.conf
XORG_BAK=/etc/X11/xorg.conf.przed-finalize
SETUP=/usr/local/sbin/x-outputs-auto.sh
LIGHTDM=/etc/lightdm/lightdm.conf
FAILSAFE_SH=/usr/local/sbin/x-failsafe.sh
FAILSAFE_UNIT=/etc/systemd/system/x-failsafe.service
MIRROR_URL=https://raw.githubusercontent.com/DamianHolthausen/GAEB83-Ausf-len/claude/raspberry-pi-5-network-j5j0tr/pi5-tft-mirror.sh

say() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
err() { printf '\n\033[1;31mBLAD: %s\033[0m\n' "$*" >&2; }

if [ "${1:-}" = "--rollback" ]; then
  say "Wycofuje zmiany"
  [ -f "$XORG_BAK" ] && sudo cp "$XORG_BAK" "$XORG" || sudo rm -f "$XORG"
  sudo sed -i '\|^display-setup-script=/usr/local/sbin/x-outputs-auto.sh|d' "$LIGHTDM"
  sudo systemctl disable --now x-failsafe.service 2>/dev/null
  sudo rm -f "$FAILSAFE_UNIT" "$FAILSAFE_SH" "$SETUP"
  sudo systemctl daemon-reload
  echo "Wycofane. Zrestartuj: sudo reboot"
  exit 0
fi

# --------------------------------------------------------- 1. xorg.conf
say "Przepisuje $XORG bez sztywnego wskazania karty graficznej"
[ -f "$XORG" ] && [ ! -f "$XORG_BAK" ] && sudo cp "$XORG" "$XORG_BAK" && echo "Kopia: $XORG_BAK"
sudo tee "$XORG" >/dev/null <<'EOF'
# Pulpit na wyjsciu HDMI przez sterownik modesetting.
# Zadne urzadzenie nie jest wskazane po nazwie - numeracja /dev/dri/cardN
# oraz /dev/fbN zmienia sie miedzy restartami.
# AutoAddGPU wylaczone, zeby serwer X nie wybral wyswietlacza SPI jako
# ekranu glownego, co zdarzalo sie przy automatycznej konfiguracji.

Section "ServerFlags"
    Option "AutoAddGPU" "false"
    Option "BlankTime"   "0"
    Option "StandbyTime" "0"
    Option "SuspendTime" "0"
    Option "OffTime"     "0"
EndSection

Section "Device"
    Identifier "HDMI-KMS"
    Driver     "modesetting"
EndSection

Section "Screen"
    Identifier   "Screen-HDMI"
    Device       "HDMI-KMS"
    DefaultDepth 24
EndSection

Section "ServerLayout"
    Identifier "Pulpit na HDMI"
    Screen 0   "Screen-HDMI"
EndSection
EOF
echo "Zapisane."

# --------------------------------------------------------- 2. wlaczanie wyjsc
say "Zapisuje $SETUP"
sudo tee "$SETUP" >/dev/null <<'EOF'
#!/bin/bash
# Uruchamiane przez menedzera logowania tuz po starcie serwera X.
# Wlacza kazde podlaczone wyjscie w jego trybie preferowanym i wylacza
# wygaszanie, zeby monitor nie zostawal bez ustawionego trybu.
xrandr --auto 2>/dev/null
xset s off 2>/dev/null
xset s noblank 2>/dev/null
xset -dpms 2>/dev/null
exit 0
EOF
sudo chmod 755 "$SETUP"

say "Podpinam go w $LIGHTDM"
if [ -f "$LIGHTDM" ]; then
  sudo cp "$LIGHTDM" "${LIGHTDM}.przed-finalize" 2>/dev/null
  sudo sed -i "\|^display-setup-script=|d" "$LIGHTDM"
  if grep -q '^\[Seat:\*\]' "$LIGHTDM"; then
    sudo sed -i "/^\[Seat:\*\]/a display-setup-script=$SETUP" "$LIGHTDM"
  else
    printf '\n[Seat:*]\ndisplay-setup-script=%s\n' "$SETUP" | sudo tee -a "$LIGHTDM" >/dev/null
  fi
  grep -n "display-setup-script" "$LIGHTDM"
else
  err "Brak $LIGHTDM - pomijam"
fi

# --------------------------------------------------------- 3. zabezpieczenie
say "Instaluje zabezpieczenie na wypadek, gdyby serwer X nie wstal"
sudo tee "$FAILSAFE_SH" >/dev/null <<'EOF'
#!/bin/bash
sleep 75
systemctl disable x-failsafe.service
if pgrep -x Xorg >/dev/null; then
    logger -t x-failsafe "Xorg dziala, konfiguracja zachowana."
    exit 0
fi
logger -t x-failsafe "Xorg nie wstal - przywracam poprzednia konfiguracje."
if [ -f /etc/X11/xorg.conf.przed-finalize ]; then
    cp /etc/X11/xorg.conf.przed-finalize /etc/X11/xorg.conf
else
    rm -f /etc/X11/xorg.conf
fi
sync
reboot
EOF
sudo chmod 755 "$FAILSAFE_SH"
sudo tee "$FAILSAFE_UNIT" >/dev/null <<EOF
[Unit]
Description=Przywroc xorg.conf, jesli serwer X nie wstal
After=graphical.target

[Service]
Type=oneshot
ExecStart=$FAILSAFE_SH

[Install]
WantedBy=graphical.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable x-failsafe.service >/dev/null 2>&1 && echo "Aktywne."

# --------------------------------------------------------- 4. odbicie na stale
say "Instaluje odbicie obrazu jako usluge"
if curl -fsSL "$MIRROR_URL" -o /tmp/mirror.sh; then
  bash /tmp/mirror.sh --install
else
  err "Nie udalo sie pobrac skryptu odbicia - zainstaluj je osobno"
fi

# --------------------------------------------------------- 5. restart
say "Gotowe"
cat <<EOF
Po restarcie sprawdz oba ekrany:
  - monitor HDMI: pulpit w trybie preferowanym
  - wyswietlacz 3,5": to samo, pomniejszone

Jesli serwer X nie wstanie, Pi samo cofnie zmiane po okolo 90 s i zrestartuje sie.
Reczne cofniecie:  bash pi5-finalize.sh --rollback
Zatrzymanie odbicia:  bash /tmp/mirror.sh --stop
EOF
for i in 20 15 10 5 3 2 1; do
  printf '\rRestart za %2d s (Ctrl+C przerywa)...' "$i"; sleep 1
done
echo
sudo reboot
