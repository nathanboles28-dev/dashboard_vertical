#!/bin/bash
# Nova FM: update the music script on the Nova FM Mac (keeps your settings). Run on the NOVA FM Mac (Terminal):
#   curl -fsSL https://nathanboles28-dev.github.io/dashboard_vertical/nova-fm-update.sh | bash
set -e
DEST="$HOME/Library/Application Support/Nova"
[ -f "$DEST/nova-music.sh" ] || { echo "Run this on the Nova FM Mac (Nova FM isn't set up on this one)."; exit 1; }
echo "== Nova FM update =="
TMP="$(mktemp)"
curl -fsSL "https://nathanboles28-dev.github.io/dashboard_vertical/mac/nova-music.sh?t=$(date +%s)" -o "$TMP"
bash -n "$TMP" || { echo "The download looks broken; nothing changed."; rm -f "$TMP"; exit 1; }
cp "$DEST/nova-music.sh" "$DEST/nova-music.sh.bak-$(date +%s)"
cp "$TMP" "$DEST/nova-music.sh"; chmod +x "$DEST/nova-music.sh"; rm -f "$TMP"
PW=$(ioreg -rw0 -c AppleSmartBattery 2>/dev/null | grep -o '"SystemPowerIn"=[0-9]*' | head -1 | grep -o '[0-9]*$')
if [ -n "$PW" ]; then echo "Done. This Mac is drawing about $((PW/1000)) W right now; the dashboard will see it within a minute."
else echo "Done. (This Mac didn't report its power draw, so the dashboard will use an estimate for it.)"; fi
