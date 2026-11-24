#!/bin/bash
# Nova: let the home helper look up planes over the house, and follow a flight live (Trip page / pick-ups),
# from your home internet, which the flight sites accept (they block Cloudflare, where the relay runs).
# Run on the DASHBOARD Mac (Terminal):
#   curl -fsSL https://nathanboles28-dev.github.io/dashboard_vertical/nova-helper-flights.sh | bash
set -e
HOMEDIR="$HOME/Library/Application Support/NovaHome"
F="$HOMEDIR/nova-home.js"
[ -f "$F" ] || { echo "Run this on the dashboard Mac (the Nova home helper isn't here)."; exit 1; }
echo "== Nova planes + flight tracking =="
cp "$F" "$F.bak-$(date +%s)"
TMP="$(mktemp)"
cat > "$TMP" <<'ROUTES'
    /* ---- NOVA PLANES BEGIN: planes near home, fetched from this Mac's own internet ---- */
    if (u.pathname === '/planes') {
      const num = (v, d) => { const n = parseFloat(v); return isFinite(n) ? n : d; };
      const lat = num(u.searchParams.get('lat'), 43.13), lon = num(u.searchParams.get('lon'), -80.75), rad = Math.min(150, num(u.searchParams.get('r'), 40)), nm = Math.ceil(rad / 1.852);
      const key = lat.toFixed(2) + ',' + lon.toFixed(2) + ',' + rad;
      global.NOVA_PL = global.NOVA_PL || {};
      const hit = global.NOVA_PL[key]; if (hit && Date.now() - hit.at < 15000) return send(200, hit);
      const get = async (url, ms) => { const r = await fetch(url, { signal: AbortSignal.timeout(ms || 7000), headers: { 'User-Agent': 'Nova home dashboard' } }); if (!r.ok) throw new Error('HTTP ' + r.status); return r.json(); };
      const toR = d => d * Math.PI / 180;
      const distKm = (a, b, c, d) => { const R = 6371, x = toR(c - a), y = toR(d - b), h = Math.sin(x / 2) ** 2 + Math.cos(toR(a)) * Math.cos(toR(c)) * Math.sin(y / 2) ** 2; return 2 * R * Math.asin(Math.sqrt(h)); };
      const bearing = (a, b, c, d) => { const y = Math.sin(toR(d - b)) * Math.cos(toR(c)), x = Math.cos(toR(a)) * Math.sin(toR(c)) - Math.sin(toR(a)) * Math.cos(toR(c)) * Math.cos(toR(d - b)); return (Math.atan2(y, x) * 180 / Math.PI + 360) % 360; };
      let raw = null, src = '', errs = [];
      for (const [name, url] of [['adsb.fi', `https://opendata.adsb.fi/api/v3/lat/${lat}/lon/${lon}/dist/${nm}`], ['adsb.lol', `https://api.adsb.lol/v2/lat/${lat}/lon/${lon}/dist/${nm}`], ['airplanes.live', `https://api.airplanes.live/v2/point/${lat}/${lon}/${nm}`], ['adsb.one', `https://api.adsb.one/v2/point/${lat}/${lon}/${nm}`]]) {
        try { const j = await get(url); if (j && Array.isArray(j.ac || j.aircraft)) { raw = j; src = name; break; } errs.push(name + ': no list'); } catch (e) { errs.push(name + ': ' + e.message); }
      }
      if (!raw) return send(502, { error: 'flight data unavailable (' + errs.join('; ') + ')' });
      const list = (raw.ac || raw.aircraft || []).filter(a => a.lat != null && a.lon != null && a.alt_baro !== 'ground')
        .map(a => ({ cs: String(a.flight || '').trim(), reg: a.r || '', type: a.t || '', desc: a.desc || '', alt: typeof a.alt_baro === 'number' ? a.alt_baro : (a.alt_geom || null),
          kt: a.gs != null ? Math.round(a.gs) : null, trk: a.track != null ? Math.round(a.track) : (a.true_heading != null ? Math.round(a.true_heading) : null),
          vs: a.baro_rate != null ? a.baro_rate : (a.geom_rate != null ? a.geom_rate : 0),
          dist: Math.round(distKm(lat, lon, a.lat, a.lon) * 10) / 10, brg: Math.round(bearing(lat, lon, a.lat, a.lon)) }))
        .filter(a => a.dist <= rad).sort((a, b) => a.dist - b.dist).slice(0, 14);
      /* airline and route for the closest airliners (remembered for 6 hours) */
      global.NOVA_RT = global.NOVA_RT || {};
      await Promise.all(list.slice(0, 8).map(async a => {
        if (!/^[A-Z]{3}\d/.test(a.cs)) return;
        let fr = global.NOVA_RT[a.cs];
        if (!fr || Date.now() - fr.at > 6 * 3600e3) { try { const j = await get('https://api.adsbdb.com/v0/callsign/' + encodeURIComponent(a.cs), 5000); fr = { at: Date.now(), r: j && j.response && j.response.flightroute || null }; global.NOVA_RT[a.cs] = fr; } catch (e) { return; } }
        if (!fr.r) return;
        const ap = x => x ? { code: x.iata_code || x.icao_code || '', city: x.municipality || x.name || '' } : null;
        a.airline = (fr.r.airline && fr.r.airline.name) || ''; a.from = ap(fr.r.origin); a.to = ap(fr.r.destination);
      }));
      const out = { at: Date.now(), count: list.length, planes: list, src: 'home/' + src };
      global.NOVA_PL[key] = out;
      return send(200, out);
    }
    /* follow one flight live: /track?cs=POE766 (same answer shape as the relay's /track) */
    if (u.pathname === '/track') {
      const cs = String(u.searchParams.get('cs') || '').toUpperCase().replace(/[^A-Z0-9]/g, '').slice(0, 8);
      if (!/^[A-Z]{3}\d{1,4}[A-Z]?$/.test(cs)) return send(400, { error: 'Bad callsign' });
      global.NOVA_TR = global.NOVA_TR || {}; const hit = global.NOVA_TR[cs]; if (hit && Date.now() - hit.at < 8000) return send(200, hit);
      const get = async (url, ms) => { const r = await fetch(url, { signal: AbortSignal.timeout(ms || 7000), headers: { 'User-Agent': 'Nova home dashboard' } }); if (!r.ok) throw new Error('HTTP ' + r.status); return r.json(); };
      const toR = d => d * Math.PI / 180, dk = (a, b, c, d) => { const x = toR(c - a), y = toR(d - b), h = Math.sin(x / 2) ** 2 + Math.cos(toR(a)) * Math.cos(toR(c)) * Math.sin(y / 2) ** 2; return 12742 * Math.asin(Math.sqrt(h)); };
      let raw = null, errs = [];
      for (const url of [`https://api.adsb.lol/v2/callsign/${cs}`, `https://opendata.adsb.fi/api/v2/callsign/${cs}`, `https://api.airplanes.live/v2/callsign/${cs}`, `https://api.adsb.one/v2/callsign/${cs}`]) {
        try { const j = await get(url); if (j && Array.isArray(j.ac || j.aircraft)) { raw = j; break; } } catch (e) { errs.push(e.message); } }
      if (!raw) return send(502, { error: 'flight data unavailable (' + errs.join('; ') + ')' });
      const a = (raw.ac || raw.aircraft || []).filter(x => x.lat != null && x.lon != null).sort((x, y) => (x.seen_pos || 0) - (y.seen_pos || 0))[0];
      if (!a) { const o = { found: false, at: Date.now() }; global.NOVA_TR[cs] = o; return send(200, o); }
      const ground = a.alt_baro === 'ground';
      const me = { lat: a.lat, lon: a.lon, ground, alt: ground ? 0 : (typeof a.alt_baro === 'number' ? a.alt_baro : (a.alt_geom || null)), kt: a.gs != null ? Math.round(a.gs) : null,
        trk: a.track != null ? Math.round(a.track) : (a.true_heading != null ? Math.round(a.true_heading) : null), vs: a.baro_rate != null ? a.baro_rate : (a.geom_rate != null ? a.geom_rate : 0),
        reg: a.r || '', type: a.t || '', desc: a.desc || '', age: Math.round(a.seen_pos || a.seen || 0) };
      let traffic = [];
      for (const url of [`https://api.adsb.lol/v2/lat/${a.lat.toFixed(3)}/lon/${a.lon.toFixed(3)}/dist/110`, `https://opendata.adsb.fi/api/v3/lat/${a.lat.toFixed(3)}/lon/${a.lon.toFixed(3)}/dist/110`, `https://api.airplanes.live/v2/point/${a.lat.toFixed(3)}/${a.lon.toFixed(3)}/110`]) {
        try { const near = await get(url); traffic = (near.ac || near.aircraft || []).filter(x => x.lat != null && x.lon != null && String(x.flight || '').trim() !== cs)
          .map(x => ({ cs: String(x.flight || '').trim(), lat: +x.lat.toFixed(4), lon: +x.lon.toFixed(4), trk: x.track != null ? Math.round(x.track) : null, alt: x.alt_baro === 'ground' ? 0 : (typeof x.alt_baro === 'number' ? x.alt_baro : null), kt: x.gs != null ? Math.round(x.gs) : null }))
          .sort((p, q) => dk(a.lat, a.lon, p.lat, p.lon) - dk(a.lat, a.lon, q.lat, q.lon)).slice(0, 160); break; } catch (e) {} }
      const o = { found: true, cs, me, traffic, at: Date.now() }; global.NOVA_TR[cs] = o; return send(200, o);
    }
    /* ---- NOVA PLANES END ---- */
ROUTES
NODE="$(command -v node || true)"; [ -z "$NODE" ] && for p in /usr/local/bin/node /opt/homebrew/bin/node; do [ -x "$p" ] && NODE="$p"; done
[ -n "$NODE" ] || { echo "Couldn't find node."; exit 1; }
"$NODE" -e '
const fs=require("fs"),f=process.argv[1],r=fs.readFileSync(process.argv[2],"utf8");let s=fs.readFileSync(f,"utf8");
/* take out an older copy of this block, then put it in just before the helper'"'"'s "/" route */
const b=s.indexOf("    /* ---- NOVA PLANES BEGIN"),e=s.indexOf("    /* ---- NOVA PLANES END ---- */");
if(b>=0&&e>b)s=s.slice(0,b)+s.slice(e+"    /* ---- NOVA PLANES END ---- */\n".length);
const a="    if (u.pathname === \x27/\x27) return send(200,";const j=s.indexOf(a);
if(j<0){console.error("helper looks different, stopping");process.exit(1)}
s=s.slice(0,j)+r+s.slice(j);fs.writeFileSync(f,s)' "$F" "$TMP"
rm -f "$TMP"
"$NODE" --check "$F" || { echo "Something went wrong; putting the old helper back."; cp "$(ls -t "$F".bak-* | head -1)" "$F"; exit 1; }
launchctl kickstart -k "gui/$(id -u)/com.nova.home" 2>/dev/null || true
sleep 3
echo "Testing…"
R=$(curl -s --max-time 30 "http://127.0.0.1:8582/planes?lat=43.13&lon=-80.75&r=30")
case "$R" in *'"planes"'*) N=$(printf '%s' "$R" | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);console.log(j.count+" planes ("+j.src+")"+(j.planes[0]?", closest: "+(j.planes[0].airline?j.planes[0].airline+" ":"")+(j.planes[0].cs||"private")+" "+j.planes[0].dist+" km":""))})'); echo "Done: $N";;
  *) echo "The helper answered: $(printf %s "$R" | cut -c1-300)";; esac
