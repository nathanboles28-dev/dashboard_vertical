#!/bin/bash
# Nova: let the home helper report how much power this Mac draws (for the "What Nova costs" page).
# Run on the DASHBOARD Mac (Terminal):
#   curl -fsSL https://nathanboles28-dev.github.io/dashboard_vertical/nova-helper-power.sh | bash
set -e
HOMEDIR="$HOME/Library/Application Support/NovaHome"
F="$HOMEDIR/nova-home.js"
[ -f "$F" ] || { echo "Run this on the dashboard Mac (the Nova home helper isn't here)."; exit 1; }
echo "== Nova power meter =="
cp "$F" "$F.bak-$(date +%s)"
TMP="$(mktemp)"
cat > "$TMP" <<'ROUTES'
    /* ---- NOVA POWER BEGIN: what this Mac draws from its charger right now (Apple Silicon reports it) ---- */
    if (u.pathname === '/power') {
      return new Promise(res => require('child_process').execFile('/usr/sbin/ioreg', ['-rw0', '-c', 'AppleSmartBattery'], { timeout: 4000 }, (err, out) => {
        const m = String(out || '').match(/"SystemPowerIn"=(\d+)/), ac = /"ExternalConnected" = Yes/.test(String(out || ''));
        res(send(200, m ? { w: Math.round(+m[1] / 100) / 10, ac, at: Date.now() } : { error: 'no power reading', ac }));
      }));
    }
    /* ---- NOVA POWER END ---- */
ROUTES
NODE=""; for p in "$(command -v node 2>/dev/null)" /usr/local/bin/node /opt/homebrew/bin/node; do [ -x "$p" ] && NODE="$p"; done
[ -n "$NODE" ] || { echo "Couldn't find node."; exit 1; }
"$NODE" -e '
const fs=require("fs"),f=process.argv[1],r=fs.readFileSync(process.argv[2],"utf8");let s=fs.readFileSync(f,"utf8");
const b=s.indexOf("    /* ---- NOVA POWER BEGIN"),e=s.indexOf("    /* ---- NOVA POWER END ---- */");
if(b>=0&&e>b)s=s.slice(0,b)+s.slice(e+"    /* ---- NOVA POWER END ---- */\n".length);
const a="    if (u.pathname === \x27/\x27) return send(200,";const j=s.indexOf(a);
if(j<0){console.error("helper looks different, stopping");process.exit(1)}
s=s.slice(0,j)+r+s.slice(j);fs.writeFileSync(f,s)' "$F" "$TMP"
rm -f "$TMP"
"$NODE" --check "$F" || { echo "Something went wrong; putting the old helper back."; cp "$(ls -t "$F".bak-* | head -1)" "$F"; exit 1; }
launchctl kickstart -k "gui/$(id -u)/com.nova.home" 2>/dev/null || true
sleep 3
R=$(curl -s --max-time 10 "http://127.0.0.1:8582/power")
case "$R" in *'"w"'*) echo "Done: this Mac is drawing $(printf '%s' "$R" | grep -o '"w":[0-9.]*' | cut -d: -f2) W right now.";;
  *) echo "The helper answered: $(printf %s "$R" | cut -c1-200)";; esac
