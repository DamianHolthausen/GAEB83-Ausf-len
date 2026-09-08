#!/bin/bash
# Ustawia nowe haslo biezacego uzytkownika na Raspberry Pi bez klawiatury.
#
# Przygotowanie na laptopie:
#   1. Na pendrivie utworz plik  haslo.txt  z nowym haslem w pierwszej linii
#      (tylko litery, cyfry i znaki - _ . ; bez polskich liter).
#   2. Opcjonalnie: skopiuj na pendrive swoj klucz publiczny SSH (plik *.pub),
#      wtedy logowanie SSH z laptopa bedzie dzialac bez hasla.
# Na Pi (myszka): skopiuj ten plik do katalogu domowego, Properties -> Permissions
#   -> Make the file executable, dwuklik -> Execute in Terminal.
#
# Skrypt szuka haslo.txt w katalogu skryptu i na kazdym zamontowanym nosniku
# (/media/*/*). Po ustawieniu hasla usuwa plik haslo.txt z nosnika.

set -uo pipefail

say() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
err() { printf '\n\033[1;31mBLAD: %s\033[0m\n' "$*" >&2; }
finish() { echo; echo "To okno zamknie sie za 60 s."; sleep 60; exit "${1:-0}"; }

USER_NAME=$(whoami)
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

say "Szukam pliku haslo.txt"
PW_FILE=""
for f in "$SCRIPT_DIR/haslo.txt" /media/*/*/haslo.txt /media/*/haslo.txt; do
  if [ -f "$f" ]; then PW_FILE="$f"; break; fi
done
if [ -z "$PW_FILE" ]; then
  err "Nie znaleziono haslo.txt (szukano w $SCRIPT_DIR i /media/*/*)."
  finish 1
fi
echo "Znaleziono: $PW_FILE"

# pierwsza linia, bez BOM, bez CR, bez spacji na koncach
NEW_PW=$(head -n 1 "$PW_FILE" | sed 's/^\xEF\xBB\xBF//' | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
if [ -z "$NEW_PW" ]; then
  err "Plik haslo.txt jest pusty."
  finish 1
fi
if [ ${#NEW_PW} -lt 6 ]; then
  err "Haslo ma mniej niz 6 znakow. Wpisz dluzsze."
  finish 1
fi

say "Ustawiam haslo uzytkownika $USER_NAME"
if printf '%s:%s\n' "$USER_NAME" "$NEW_PW" | sudo chpasswd; then
  echo "Haslo ustawione."
else
  err "chpasswd nie powiodl sie (brak sudo bez hasla?)."
  finish 1
fi

say "Usuwam haslo.txt z nosnika"
rm -f "$PW_FILE" && echo "Usunieto $PW_FILE" || echo "Nie udalo sie usunac $PW_FILE, usun recznie."

say "Klucz publiczny SSH (opcjonalnie)"
KEY_ADDED=0
for k in "$SCRIPT_DIR"/*.pub /media/*/*/*.pub /media/*/*.pub; do
  [ -f "$k" ] || continue
  if grep -q -E '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256) ' "$k"; then
    mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
    tr -d '\r' < "$k" >> "$HOME/.ssh/authorized_keys"
    chmod 600 "$HOME/.ssh/authorized_keys"
    echo "Dodano klucz z $k"
    KEY_ADDED=1
  fi
done
[ $KEY_ADDED -eq 0 ] && echo "Nie znaleziono pliku *.pub, pomijam."

say "SSH"
sudo raspi-config nonint do_ssh 0 && echo "SSH wlaczone."
IP=$(hostname -I 2>/dev/null | awk '{print $1}')
echo
echo "Logowanie z laptopa (PowerShell):   ssh $USER_NAME@$IP"
finish 0
