#!/bin/bash
set -e

# The compose file ships with /dev/gpiochip0 (Pi 3 / 4 / Zero 2 W). On Pi 5
# the 40-pin GPIO header lives on /dev/gpiochip4 — mapping a non-existent
# device through Docker fails the container start. Rewrite the compose
# device line on the first boot we see a Pi 5, then drop a marker so we
# never rewrite again (even if the user later edits the compose by hand).

COMPOSE=/compose/lva-peripheral/docker-compose.yml
MARKER=/compose/lva-peripheral/.gpiochip-tuned

[ -f "$COMPOSE" ] || exit 0
[ -f "$MARKER" ] && exit 0

MODEL="$(tr -d '\0' </proc/device-tree/model 2>/dev/null || true)"

case "$MODEL" in
  *"Raspberry Pi 5"*)
    echo "[lva-peripheral-gpiochip-fix] $MODEL — switching peripheral to /dev/gpiochip4"
    sed -i 's:/dev/gpiochip0:/dev/gpiochip4:g' "$COMPOSE"
    ;;
  *)
    echo "[lva-peripheral-gpiochip-fix] $MODEL — keeping /dev/gpiochip0"
    ;;
esac

touch "$MARKER"
