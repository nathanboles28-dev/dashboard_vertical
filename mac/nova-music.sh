#!/bin/bash
# Nova "Now playing" sender (v8: Nova FM). The little "Nova Music" app reads Apple Music every few seconds and hands the
# details to this script, which only sends a message when something changes: a new song, pause/play, or a skip.
# Nothing else from your library ever leaves this Mac.
exec 3>&1
DIR="$(cd "$(dirname "$0")" && pwd)"; . "$DIR/nova-music.env"; SF="$DIR/.np-state"
# the Nova Music app reports back after pressing play: --result "ok Song by Artist" "what you asked" "song" "app log"
if [ "$1" = "--result" ]; then BUS="${NOVA_BUS:-https://nova-bus.nathanboles28.workers.dev}"
  { [ -n "$5" ] && echo "app: $5"; echo "result: $2"; } >> "$DIR/music-debug.log"
  # Apple Music wouldn't start it: queue it for YouTube in Brave (the next check, a few seconds from now, plays it and reports back)
  case "$2" in notplayed*|needaccess*|opened*) if [ "$4" = song ] && { [ -d "/Applications/Brave Browser.app" ] || [ -d "$HOME/Applications/Brave Browser.app" ]; }; then
    echo "result: handing to YouTube" >> "$DIR/music-debug.log"; curl -sf -m 5 -d "yt|$3" "$BUS/bus/${NOVA_TOPIC}-mcmd" >/dev/null 2>&1; exit 0; fi;; esac
  curl -sf -m 5 -d "musicresult ${2}|${3}|${4}" "$BUS/bus/${NOVA_TOPIC}" >/dev/null 2>&1; exit 0; fi
last_key=""; last_pos=0; last_t=0; sent_day=""; sent=0; last_cmd_t=""; last_poll=0; last_hb=0; last_kfix=0; [ -f "$SF" ] && . "$SF"
DEV="${NOVA_DEVICE:-Macbook}"; CAP="${DAILY_CAP:-2000}"; [ "$CAP" -lt 2000 ] 2>/dev/null && CAP=2000
esc(){ printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\000-\037'; }
num(){ case "$1" in ''|*[!0-9-]*) echo 0;; *) echo "$1";; esac; }
# what Apple Music is playing from, shuffle, and (when not shuffling) the next 3 songs in that playlist/album
up_next(){ [ "$src" = youtube ] && return; osascript <<'APPLESCRIPT' 2>>"$DIR/music-debug.log"
tell application "Music"
  set out to ""
  try
    set p to current playlist
    set out to (name of p)
  on error
    return ""
  end try
  set sh to false
  try
    set sh to shuffle enabled
  end try
  set out to out & tab & (sh as text)
  if not sh then
    try
      set cid to persistent ID of current track
      set n to count of tracks of p
      if n < 4000 then
        set ids to persistent ID of every track of p
        set i to 0
        repeat with k from 1 to n
          if item k of ids is cid then
            set i to k
            exit repeat
          end if
        end repeat
        if i > 0 then
          repeat with k from (i + 1) to (i + 3)
            if k > n then exit repeat
            set t to track k of p
            set out to out & tab & (name of t) & "^" & (artist of t)
          end repeat
        end if
      end if
    end try
  end if
  return out
end tell
APPLESCRIPT
}
up_json(){ u="$(up_next)"; echo "upnext $(date +%T): $(printf %s "$u" | tr '\t' '|' | cut -c1-200)" >> "$DIR/music-debug.log"; [ -z "$u" ] && return; IFS=$'\t' read -r -a U <<< "$u"
  j=",\"from\":\"$(esc "${U[0]}")\",\"shuf\":$([ "${U[1]}" = true ] && echo true || echo false),\"next\":["; sep=""
  for x in "${U[@]:2}"; do j="$j$sep[\"$(esc "${x%%^*}")\",\"$(esc "${x#*^}")\"]"; sep=","; done; printf '%s]' "$j"; }
now=$(date +%s)
IFS=$'\037' read -r st nm ar al yr du ps pid src vid <<EOF2
$1
EOF2
if [ "$st" = error ]; then printf '%s  %s\n' "$(date)" "$nm" > "$DIR/nova-music-error.txt"; fi
# older macOS can hand back the raw code instead of the word
case "$st" in *kPSP*|*kPSF*|*kPSR*) st=playing;; *kPSp*) st=paused;; esac
case "$st" in playing|paused) ;; *) st=stopped;; esac
# AppleScript gives decimals (with your Mac's decimal mark): keep whole seconds
du=$(num "${du%%[.,]*}"); ps=$(num "${ps%%[.,]*}"); yr=$(num "$yr")
# YouTube in Brave: tidy the title, and pull the video id out of the address if that's all we got
if [ "$src" = youtube ]; then
  nm=$(printf '%s' "$nm" | sed -E 's/^\([0-9]+\) //; s/ - YouTube$//')
  case "$vid" in *youtube.com*) vid=$(printf '%s' "$vid" | sed -E 's#.*/shorts/([A-Za-z0-9_-]+).*#\1#; s#.*[?&]v=([A-Za-z0-9_-]+).*#\1#');; esac
  case "$vid" in *[!A-Za-z0-9_-]*) vid="";; esac
fi
prev_key="$last_key"; key="$st|$pid|$nm|$ar"; jump=0
if [ "$st" = playing ] && [ "$key" = "$last_key" ]; then
  diff=$((ps - (last_pos + now - last_t))); [ "${diff#-}" -gt 6 ] && jump=1
fi
if [ "$key" != "$last_key" ] || [ "$jump" = 1 ]; then
  # genre for Nova FM's daily stats (only asked once per song)
  gn=""; if [ "$st" != stopped ] && [ -z "$src" ]; then gn=$(osascript -e 'tell application "Music" to get genre of current track' 2>/dev/null | head -1); fi
  if [ "$st" = stopped ]; then body="{\"state\":\"stopped\",\"at\":$now,\"dev\":\"$(esc "$DEV")\"}"
  else body="{\"state\":\"$st\",\"title\":\"$(esc "$nm")\",\"artist\":\"$(esc "$ar")\",\"album\":\"$(esc "$al")\",\"year\":$yr,\"genre\":\"$(esc "$gn")\",\"dur\":$du,\"pos\":$ps,\"at\":$now,\"dev\":\"$(esc "$DEV")\"${src:+,\"src\":\"$(esc "$src")\",\"vid\":\"$(esc "$vid")\"}$( [ "$st" = playing ] && up_json )}"; fi
  d=$(date +%Y-%m-%d); [ "$d" != "$sent_day" ] && { sent_day=$d; sent=0; }
  # nothing to announce when it starts up with nothing playing; daily safety limit for the free channel
  if { [ -n "$last_key" ] || [ "$st" != stopped ]; } && [ "$sent" -lt "$CAP" ]; then
    # your own Cloudflare nova-bus first (no daily limit); the free ntfy.sh channel only if that fails
    BUS="${NOVA_BUS:-https://nova-bus.nathanboles28.workers.dev}"
    if curl -sf -m 8 -d "$body" "$BUS/bus/${NOVA_TOPIC}-music" >/dev/null 2>&1 || curl -sf -m 8 -d "$body" "https://ntfy.sh/${NOVA_TOPIC}-music" >/dev/null 2>&1; then sent=$((sent+1)); fi
  fi
  last_key="$key"
fi
last_pos=$ps; last_t=$now

# ---- commands from Nova: playlists, songs/artists/albums (your library first, then Apple Music), shuffle, pause, next, previous, volume (checked every ~7 s) ----
BUS="${NOVA_BUS:-https://nova-bus.nathanboles28.workers.dev}"
[ -z "$last_cmd_t" ] && last_cmd_t=$now
# Not in your library: find it on Apple Music (Apple's free search), open it in the Music app, and press play.
# Needs Accessibility for the Nova Music app (System Settings > Privacy & Security > Accessibility) the first time.
# Not in your library: find it on Apple Music (Apple's free search) and open it in the Music app.
# macOS won't let scripts press Play for you, so Music is asked to open it; if it doesn't start by itself, it's left ready for one tap.
catalog_play(){ q="$1"; ent="${2:-song}"; f="$DIR/.itunes.json"; LOG="$DIR/music-debug.log"
  # a song that isn't in your library: find it in Apple Music, then hand it to the Nova Music app, which has the
  # Accessibility permission to press play (a plain script can only open the page). The app reports back with --result.
  curl -sf -m 8 -G "https://itunes.apple.com/search" --data-urlencode "term=$q" -d "country=${NOVA_COUNTRY:-CA}" -d "media=music" -d "entity=$ent" -d "limit=5" -o "$f" || { echo "error search failed"; return; }
  key=trackViewUrl; nk=trackName; [ "$ent" = album ] && { key=collectionViewUrl; nk=collectionName; }
  # prefer a result whose title is in what was asked (so "hello adele" doesn't pick a cover)
  pick=0; ql=$(printf '%s' "$q" | tr '[:upper:]' '[:lower:]')
  for i in 0 1 2 3 4; do n=$(plutil -extract "results.$i.$nk" raw -o - "$f" 2>/dev/null) || break; a=$(plutil -extract "results.$i.artistName" raw -o - "$f" 2>/dev/null)
    nl=$(printf '%s' "$n" | tr '[:upper:]' '[:lower:]' | sed -E 's/ *[(\[].*//'); al=$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]')
    case "$ql" in *"$nl"*) case "$ql" in *"$al"*) pick=$i; break;; esac; [ "$pick" = 0 ] && [ -z "${firstn:-}" ] && { pick=$i; firstn=1; };; esac; done; firstn=""
  url=$(plutil -extract "results.$pick.$key" raw -o - "$f" 2>/dev/null); [ -z "$url" ] && { echo "notfound"; return; }
  nm=$(plutil -extract "results.$pick.$nk" raw -o - "$f" 2>/dev/null); ar=$(plutil -extract "results.$pick.artistName" raw -o - "$f" 2>/dev/null)
  tn=$(plutil -extract "results.$pick.trackNumber" raw -o - "$f" 2>/dev/null); [ -z "$tn" ] && tn=1
  echo "---- $(date) | asked: $q | found: $nm by $ar | $url | handing to the Nova Music app" >> "$LOG"
  S=$(printf '\037'); printf 'NOVAPLAY%s%s%s%s%s%s%s%s%s%s%s%s%s%s\n' "$S" "music://${url#https://}" "$S" "$nm" "$S" "$ar" "$S" "$ent" "$S" "$tn" "$S" "$v" "$S" "$k" >&3
  echo "deferred"
}
# ---- Nova FM: a short DJ break from Nova, read in Zoe's voice over the music (ducked), with optional jingles and beds ----
# Put your own sounds in ~/Music/Nova FM/jingles (played at the start) and ~/Music/Nova FM/beds (quiet music under the voice).
# Optional settings in nova-music.env: DJ_VOICE="Zoe (Premium)"  DJ_RATE=160  DJ_VOL=1.0  DJ_BED=0.22
FMDIR="${NOVA_FM_DIR:-$HOME/Music/Nova FM}"
# on air / speaking / off, to the dashboard: on the main channel and (as a backup) on the now-playing channel, and say in the log how it went
fm_post(){ B="${NOVA_BUS:-https://nova-bus.nathanboles28.workers.dev}"
  c1=$(curl -s -m 8 -o /dev/null -w '%{http_code}' -d "fmstate $1" "$B/bus/${NOVA_TOPIC}" 2>/dev/null)
  j=$(M="$1" perl -MJSON::PP -e 'print JSON::PP->new->encode({fm=>$ENV{M},at=>time})' 2>/dev/null)
  c2=$(curl -s -m 8 -o /dev/null -w '%{http_code}' -d "$j" "$B/bus/${NOVA_TOPIC}-music" 2>/dev/null)
  echo "fm $(date +%T) ${1%% *}: sent main $c1, music $c2 ($(printf %s "$1" | wc -c | tr -d ' ') chars)" >> "$DIR/music-debug.log"; }
fm_pick(){ ls "$1" 2>/dev/null | grep -iE '\.(mp3|m4a|wav|aiff?|caf)$' | awk 'BEGIN{srand()}{a[NR]=$0}END{if(NR)print a[int(rand()*NR)+1]}'; }
# which jingle (prints its full path):
#  sports / weather / news / id breaks: one from that folder
#  everything else: the general ones in jingles/, shuffled like a deck (all of them before any repeats, never the same twice in a row);
#  from midnight to 5 AM the ones in jingles/afterdark are mixed in, about 1 in 3
fm_jpick(){ k="$1"; J=""
  case "$k" in sports|weather|news|id|afterdark) f="$(fm_pick "$FMDIR/jingles/$k")"; [ -n "$f" ] && { echo "$FMDIR/jingles/$k/$f"; return; };; esac
  h=$((10#$(date +%H)))
  if [ "$h" -lt 5 ]; then f="$(fm_pick "$FMDIR/jingles/afterdark")"; [ -n "$f" ] && [ $((RANDOM % 3)) -eq 0 ] && { echo "$FMDIR/jingles/afterdark/$f"; return; }; fi
  G="$FMDIR/jingles"; all="$(ls "$G" 2>/dev/null | grep -iE '\.(mp3|m4a|wav|aiff?|caf)$')"; [ -z "$all" ] && return
  bag="$DIR/.jingle-deck"; last="$(cat "$DIR/.jingle-last" 2>/dev/null)"
  # take the next one from the deck that still exists; a new shuffled deck when it runs out
  while :; do
    if [ ! -s "$bag" ]; then printf '%s\n' "$all" | awk 'BEGIN{srand()}{print rand()"\t"$0}' | sort -n | cut -f2- > "$bag"
      [ "$(head -1 "$bag")" = "$last" ] && [ "$(wc -l < "$bag")" -gt 1 ] && { { tail -n +2 "$bag"; head -1 "$bag"; } > "$bag.t"; mv "$bag.t" "$bag"; }; fi
    f="$(head -1 "$bag")"; tail -n +2 "$bag" > "$bag.t"; mv "$bag.t" "$bag"
    [ -f "$G/$f" ] && break; [ ! -s "$bag" ] && [ -z "$f" ] && return
  done
  printf '%s' "$f" > "$DIR/.jingle-last"; echo "$G/$f"; }
# a jingle on its own between songs (no talking): the music dips, the jingle plays, the music comes back
fm_jingle(){ duckp="${1:-30}"; jkind="${2:-dj}"; L="$DIR/.dj-lock"
  mkdir "$L" 2>/dev/null || return
  # the dashboard can ask for a sports / weather / afterdark / id jingle to match what it shows on screen
  J="$(fm_jpick "$jkind")"; [ -z "$J" ] && { rmdir "$L"; return; }
  r=$(osascript -e 'tell application "Music" to (player state as text) & "|" & (sound volume as text)' 2>/dev/null)
  case "$r" in playing*) ;; *) rmdir "$L"; return;; esac
  v0=$(num "${r#*|}"); [ "$v0" -lt 1 ] 2>/dev/null && v0=50; [ "$duckp" -gt "${DJ_JDUCK:-15}" ] 2>/dev/null && duckp=${DJ_JDUCK:-15}; dv=$(( v0 * duckp / 100 ))
  echo "jingle $(date +%T): $(basename "$J") (music $v0 -> $dv)" >> "$DIR/music-debug.log"
  fm_fade "$v0" "$dv" 0.6; afplay -v "${DJ_JVOL:-1.15}" "$J"; sleep 0.2; fm_fade "$dv" "$v0" 1.6; rmdir "$L" 2>/dev/null; }
fm_fade(){ osascript - "$1" "$2" "$3" >/dev/null 2>&1 <<'APPLESCRIPT'
on run argv
  set a to (item 1 of argv) as integer
  set b to (item 2 of argv) as integer
  set s to (item 3 of argv) as real
  set n to 12
  tell application "Music"
    repeat with i from 1 to n
      set sound volume to (a + (b - a) * i / n) as integer
      delay (s / n)
    end repeat
  end tell
end run
APPLESCRIPT
}
fm_air(){ txt="$1"; duckp="${2:-30}"; kind="${3:-dj}"; L="$DIR/.dj-lock"
  # "sports@am_puck": the break's kind, then the show host's Kokoro voice (from the dashboard)
  hostv=""; case "$kind" in *@*) hostv="${kind#*@}"; kind="${kind%%@*}";; esac; [ -z "$kind" ] && kind=dj
  case "$hostv" in *[!a-z_]*) hostv="";; esac
  mkdir -p "$FMDIR/jingles/id" "$FMDIR/jingles/sports" "$FMDIR/jingles/weather" "$FMDIR/jingles/news" "$FMDIR/jingles/afterdark" "$FMDIR/beds" 2>/dev/null
  if ! mkdir "$L" 2>/dev/null; then [ -n "$(find "$L" -maxdepth 0 -mmin +3 2>/dev/null)" ] && rmdir "$L" 2>/dev/null; mkdir "$L" 2>/dev/null || return; fi
  # her voice: Kokoro (the AI voice, if nova-fm-kokoro-setup.sh was run on this Mac), otherwise Zoe. Rendered to a file first, so there's no pause once the music is down
  AF="$DIR/.dj.aiff"; eng=say; rm -f "$DIR/.dj.wav"
  if [ "${DJ_ENGINE:-kokoro}" = kokoro ] && curl -s -m 2 http://127.0.0.1:8583/ 2>/dev/null | grep -q nova-voice; then
    body=$(TXT="$txt" OUT="$DIR/.dj.wav" SP="${DJ_SPEED:-0.95}" KV="${hostv:-${DJ_KOKORO:-af_heart}}" perl -MJSON::PP -e 'print JSON::PP->new->encode({text=>$ENV{TXT},out=>$ENV{OUT},speed=>$ENV{SP}+0,voice=>$ENV{KV}})' 2>/dev/null)
    rr=$(curl -s -m 90 --data-binary "$body" http://127.0.0.1:8583/render 2>/dev/null)
    case "$rr" in *'"ok": true'*) [ -s "$DIR/.dj.wav" ] && { AF="$DIR/.dj.wav"; eng=kokoro
        KP="$HOME/Library/Application Support/NovaVoice/venv/bin/python"; [ -x "$KP" ] && "$KP" -c 'import sys,soundfile as sf,numpy as np;a,r=sf.read(sys.argv[1]);m=float(np.max(np.abs(a))) if len(a) else 0;(m>0.01) and sf.write(sys.argv[1],np.clip(a*(0.95/m),-1,1),r)' "$AF" 2>>"$DIR/music-debug.log"; };; *) echo "dj kokoro failed $(date +%T): $(printf %s "$rr" | cut -c1-120)" >> "$DIR/music-debug.log";; esac
  fi
  if [ "$eng" = say ]; then
    V="${DJ_VOICE:-Zoe (Premium)}"; say -v '?' 2>/dev/null | grep -qF "$V" || V="Samantha"
    # read the words into a file first, so there's no pause once the music is down
    # a speaker's pauses: a beat between sentences and a breath at commas (Apple voices otherwise read it in one flat run)
    ptxt=$(printf '%s' "$txt" | perl -CSD -Mutf8 -pe 's/([.!?])["”\x27]?\s+(?=[A-Z0-9"“])/$1 [[slnc 300]] /g; s/([,;:])\s+/$1 [[slnc 120]] /g; s/\s+[—–-]\s+/ [[slnc 160]] /g' 2>/dev/null); [ -z "$ptxt" ] && ptxt="$txt"
    say -v "$V" -r "${DJ_RATE:-160}" -o "$DIR/.dj.aiff" "$ptxt" 2>/dev/null || { rmdir "$L"; return; }
  fi
  playing=0; v0=50; r=""
  # read Music's state + volume. On a "welcome back" the song is often still starting, so wait up to ~5s for it to be playing
  for _ in 1 2 3 4 5 6 7; do r=$(osascript -e 'tell application "Music" to (player state as text) & "|" & (sound volume as text)' 2>/dev/null)
    case "$r" in playing*) break;; esac; sleep 0.7; done
  # duck whenever Music answered at all: if it's paused/starting, lowering the volume now still keeps the song under her voice when it kicks in
  case "$r" in *\|*) playing=1; v0=$(num "${r#*|}");; esac
  [ "$v0" -lt 1 ] 2>/dev/null && v0=50
  dv=$(( v0 * duckp / 100 ))
  echo "dj air $(date +%T) [$eng]: music='$r' duck $v0 -> $dv" >> "$DIR/music-debug.log"
  # "on" carries the words she's about to say, so the dashboard's captions always have them
  fm_post "on $(printf '%s' "$txt" | base64 | tr -d '\n')"
  # a jingle for this kind of break (jingles/sports, weather, news, id) or any general one in jingles/
  J="$(fm_jpick "$kind")"; jp=""
  # DJ_MODE=pause (default): like a real station between songs. The song pauses, she talks over nothing (or a quiet bed),
  # then the song starts again from the top, so no part of it is talked over. DJ_MODE=duck: the old way, talking over the song turned down.
  pmode="${DJ_MODE:-pause}"; ppos=0
  if [ "$playing" = 1 ] && [ "$pmode" = pause ]; then
    fm_fade "$v0" 0 0.5
    ppos=$(num "$(osascript -e 'tell application "Music" to player position' 2>/dev/null | cut -d. -f1)")
    osascript -e 'tell application "Music" to pause' >/dev/null 2>&1
    osascript -e "tell application \"Music\" to set sound volume to $v0" >/dev/null 2>&1
    echo "dj air: paused the song at ${ppos}s" >> "$DIR/music-debug.log"
  elif [ "$playing" = 1 ]; then fm_fade "$v0" "$dv" 0.7
    # make sure it actually went down (Music sometimes ignores the fade right as a song starts)
    cv=$(num "$(osascript -e 'tell application "Music" to sound volume' 2>/dev/null)")
    [ "$cv" -gt $(( dv + 3 )) ] 2>/dev/null && { osascript -e "tell application \"Music\" to set sound volume to $dv" >/dev/null 2>&1; echo "dj air: fade missed ($cv), forced $dv" >> "$DIR/music-debug.log"; }; fi
  # the jingle plays once the music is already down, and louder than before (DJ_JVOL, 1.0 = file's own level)
  [ -n "$J" ] && { echo "dj jingle: $(basename "$J")" >> "$DIR/music-debug.log"; afplay -v "${DJ_JVOL:-1.15}" "$J"; }
  B="$(fm_pick "$FMDIR/beds")"; bp=""
  [ -n "$B" ] && { afplay -v "${DJ_BED:-0.22}" "$FMDIR/beds/$B" & bp=$!; }
  # tell the dashboard the exact moment she starts talking and how long the clip is, so the captions follow her voice
  dur=$(afinfo "$AF" 2>/dev/null | awk '/estimated duration/{print $3; exit}')
  ms=$(perl -MTime::HiRes=time -e 'printf "%.0f", time*1000' 2>/dev/null)
  fm_post "speak ${dur:-0} ${ms:-0}" &
  afplay -v "${DJ_VOL:-1.0}" "$AF"
  [ -n "$bp" ] && kill "$bp" 2>/dev/null
  if [ "$playing" = 1 ] && [ "$pmode" = pause ]; then
    sleep 0.25
    # back to the very start if it had only just begun (a break at a song change), otherwise carry on where it was
    [ "${ppos:-0}" -lt 25 ] 2>/dev/null && osascript -e 'tell application "Music" to set player position to 0' >/dev/null 2>&1
    osascript -e 'tell application "Music" to play' >/dev/null 2>&1
  elif [ "$playing" = 1 ]; then sleep 0.3; fm_fade "$dv" "$v0" 2.2; fi
  fm_post off; rm -f "$DIR/.dj.aiff" "$DIR/.dj.wav"; rmdir "$L" 2>/dev/null; }
# start a break in the background so the now-playing checks keep running
fm_go(){ ( fm_air "$1" "$2" "$3" ) </dev/null >/dev/null 2>&1 3>&- & }
# YouTube in Brave (ad-blocked): the backup when Apple Music can't start a song. Searches for the official audio so it's
# the studio track, not the video. Brave already lets this app run JavaScript in it (that's how YouTube shows as Now Playing).
brave_js(){ osascript - "$1" 2>/dev/null <<'APPLESCRIPT'
on run argv
  set js to item 1 of argv
  set out to ""
  if application "Brave Browser" is not running then return ""
  tell application "Brave Browser"
    repeat with w in windows
      repeat with t in tabs of w
        if (URL of t) contains "youtube.com/watch" then
          try
            set out to (execute t javascript js)
          end try
        end if
      end repeat
    end repeat
  end tell
  return out
end run
APPLESCRIPT
}
yt_play(){ q="$1"; LOG="$DIR/music-debug.log"
  [ -d "/Applications/Brave Browser.app" ] || [ -d "$HOME/Applications/Brave Browser.app" ] || { echo "notfound"; return; }
  id=$(curl -sf -m 10 -A "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130 Safari/537.36" -H "Accept-Language: en-CA,en" -G "https://www.youtube.com/results" --data-urlencode "search_query=$q official audio" | grep -o '"videoId":"[A-Za-z0-9_-]\{11\}"' | head -1 | cut -d'"' -f4)
  [ -z "$id" ] && { echo "---- $(date) | youtube: nothing for $q" >> "$LOG"; echo "notfound"; return; }
  osascript -e 'tell application "Music" to pause' >/dev/null 2>&1
  brave_js "document.querySelectorAll('video').forEach(v=>v.pause())" >/dev/null
  open -a "Brave Browser" "https://www.youtube.com/watch?v=$id" >/dev/null 2>&1 || { echo "error Brave wouldn't open"; return; }
  t=""; for i in 1 2 3 4 5 6 7 8 9 10 11 12; do sleep 1
    t=$(brave_js "(()=>{if(!location.href.includes('$id'))return '';const v=document.querySelector('video');if(!v)return '';v.muted=false;if(v.paused)v.play();return (v.paused?'':'P|')+document.title.replace(/ - YouTube\$/,'')})()")
    case "$t" in P\|*) break;; esac; done
  echo "---- $(date) | youtube: $q -> $id | ${t:-no answer from Brave}" >> "$LOG"
  nm=$(printf '%s' "${t#P|}" | sed -E 's/^\([0-9]+\) //; s/ *[(\[](official|lyric|audio|visuali)[^)\]]*[)\]]//Ig; s/ +$//')
  [ -z "$nm" ] && nm="$q"
  echo "ok $nm on YouTube"
}
music_cmd(){ k="${1%%|*}"; v="${1#*|}"; r=""
  case "$k" in
    playlist) r=$(osascript - "$v" 2>&1 <<'APPLESCRIPT'
on run argv
  set q to item 1 of argv
  tell application "Music"
    set ps to (every user playlist whose name is q)
    if ps is {} then set ps to (every user playlist whose name contains q)
    if ps is {} then return "notfound " & q
    try
      set shuffle enabled to true
    end try
    play item 1 of ps
    return "ok " & (name of item 1 of ps)
  end tell
end run
APPLESCRIPT
); case "$r" in ok*|notfound*) ;; *) r="error $r";; esac;;
    song|album|artist|shuffle)
      if [ "$k" = shuffle ] && [ "$v" = "*" ]; then
        osascript -e 'tell application "Music"' -e 'set shuffle enabled to true' -e 'play library playlist 1' -e 'end tell' >/dev/null 2>&1; r="ok your library"
      else
        q2=$(printf '%s' "$v" | sed -E 's/ by / /g; s/[[:space:]]+/ /g')
        r=$(osascript - "$q2" "$k" 2>&1 <<'APPLESCRIPT'
on run argv
  set q to item 1 of argv
  set mode to item 2 of argv
  tell application "Music"
    set L to library playlist 1
    set res to (search L for q)
    if res is {} then return "notfound"
    if mode is "album" then
      set an to album of item 1 of res
      return my playSet((every track of L whose album is an), false, an)
    end if
    if mode is "song" then
      repeat with t in res
        if (name of t) is q then
          play t
          return "ok " & (name of t) & " by " & (artist of t)
        end if
      end repeat
    end if
    repeat with t in res
      if (artist of t) is q then
        set ar to artist of t
        return my playSet((every track of L whose artist is ar), true, ar)
      end if
    end repeat
    if mode is "song" then
      set t to item 1 of res
      play t
      return "ok " & (name of t) & " by " & (artist of t)
    end if
    set ar to artist of item 1 of res
    return my playSet((every track of L whose artist is ar), true, ar)
  end tell
end run
on playSet(ts, shuf, label)
  tell application "Music"
    set n to count of ts
    if n is 0 then return "notfound"
    if n > 150 then set n to 150
    if not (exists user playlist "Nova Queue") then make new user playlist with properties {name:"Nova Queue"}
    set P to user playlist "Nova Queue"
    delete every track of P
    repeat with i from 1 to n
      duplicate (item i of ts) to P
    end repeat
    set shuffle enabled to shuf
    play P
    return "ok " & label
  end tell
end playSet
APPLESCRIPT
)
        # not in the library: a song goes straight to YouTube in Brave (seconds, every time); Apple Music's catalog only
        # for albums, or a song when there's no Brave (set NOVA_CATALOG_FIRST=1 in nova-music.env to try Apple Music first)
        have_brave(){ [ -d "/Applications/Brave Browser.app" ] || [ -d "$HOME/Applications/Brave Browser.app" ]; }
        case "$r" in ok*) ;; *) if [ "$k" = song ] && have_brave && [ "${NOVA_CATALOG_FIRST:-0}" != 1 ]; then r=$(yt_play "$q2")
          elif [ "$k" = album ]; then r=$(catalog_play "$q2" album); else r=$(catalog_play "$q2" song); fi;; esac
        case "$r" in notfound*|error*) [ "$k" = song ] && have_brave && r=$(yt_play "$q2");; esac
        case "$r" in ok*|notfound*|notplayed*|needaccess*|opened*|deferred) ;; *) r="error $(printf '%s' "$r" | tr -d '|' | tr '\n' ' ' | cut -c1-120)";; esac
      fi;;
    yt)       r=$(yt_play "$v"); k=song;;
    pause)    osascript -e 'tell application "Music" to pause' >/dev/null 2>&1; brave_js "document.querySelectorAll('video').forEach(v=>v.pause())" >/dev/null;;
    play)     osascript -e 'tell application "Music" to play' >/dev/null 2>&1;;
    next)     osascript -e 'tell application "Music" to next track' >/dev/null 2>&1;;
    previous) osascript -e 'tell application "Music" to previous track' >/dev/null 2>&1;;
    volume)   osascript -e "tell application \"Music\" to set sound volume to $(num "$v")" >/dev/null 2>&1;;
    up)       osascript -e 'tell application "Music" to set sound volume to (sound volume + 15)' >/dev/null 2>&1;;
    down)     osascript -e 'tell application "Music" to set sound volume to (sound volume - 15)' >/dev/null 2>&1;;
    log)      echo "$v" >> "$DIR/music-debug.log";;   # a line from the dashboard for the Nova log
    jingle)   jd="${v%%|*}"; jk=""; case "$v" in *"|"*) jk="${v#*|}";; esac; case "$jk" in *[!a-z]*) jk="";; esac; ( fm_jingle "$(num "$jd")" "$jk" ) </dev/null >/dev/null 2>&1 3>&- & r="";;   # "jingle|30": a jingle between songs
    req)      # "req|artist|Luke Combs" = play that when the current song is nearly done
              printf '%s|%s|%s' "$now" "$pid" "$v" > "$DIR/.req"; echo "request $(date +%T): $v" >> "$DIR/music-debug.log";;
    dj)       # "dj|now|30|<base64 words>" = right away · "dj|next|30|..." = when the next song starts
              mode="${v%%|*}"; kind="dj"; case "$mode" in *:*) kind="${mode#*:}"; mode="${mode%%:*}";; esac; rest="${v#*|}"; duckp="$(num "${rest%%|*}")"; b64="${rest#*|}"
              b64=$(printf '%s' "$b64" | tr -d '\\\\'); words=$(printf '%s' "$b64" | base64 -D 2>/dev/null)
              if [ -n "$words" ]; then
                if [ "$mode" = now ]; then fm_go "$words" "$duckp" "$kind"; echo "dj now $(date +%T)" >> "$DIR/music-debug.log"; else printf '%s|%s|%s|%s|%s' "$now" "$duckp" "$b64" "$pid" "$kind" > "$DIR/.dj-queue"; printf '%s %s' "$ps" "$du" > "$DIR/.dj-qpos"; echo "dj queued $(date +%T) during: $nm" >> "$DIR/music-debug.log"; fi
              fi;;
  esac
  [ -n "$r" ] && [ "$r" != deferred ] && curl -sf -m 5 -d "musicresult ${r}|${v}|${k}" "$BUS/bus/${NOVA_TOPIC}" >/dev/null 2>&1
}
# keep itself up to date: every 30 minutes, fetch the latest copy from the dashboard's site and swap it in if it changed
# (checked for syntax first; the old copy is kept as nova-music.sh.bak-auto). The next run uses the new one.
if [ $((now - ${last_upd:-0})) -ge 1800 ]; then last_upd=$now
  ( T="$DIR/.nm-new"; curl -fsSL -m 20 "https://nathanboles28-dev.github.io/dashboard_vertical/mac/nova-music.sh?t=$now" -o "$T" 2>/dev/null \
    && grep -q 'Nova "Now playing" sender' "$T" && bash -n "$T" 2>/dev/null && ! cmp -s "$T" "$DIR/nova-music.sh" \
    && cp "$DIR/nova-music.sh" "$DIR/nova-music.sh.bak-auto" && chmod +x "$T" && mv -f "$T" "$DIR/nova-music.sh" \
    && echo "mac $(date +%H:%M:%S) music script updated itself" >> "$DIR/music-debug.log"; rm -f "$T" ) </dev/null >/dev/null 2>&1 3>&- &
fi
# Nova FM health check: once a minute, tell the dashboard this Mac is alive, what Music is doing and whether the voice is up
# (if the Kokoro voice is down, restart it, at most every 5 minutes)
if [ $((now - ${last_hb:-0})) -ge 60 ]; then
  last_hb=$now; mu="$st"; case "$1" in off*) mu=closed;; error*) mu=error;; esac; khk=$(num "$last_kfix")
  kv=down; { [ -e "$DIR/.dj-lock" ] || curl -s -m 4 http://127.0.0.1:8583/ 2>/dev/null | grep -q nova-voice; } && kv=up
  # only restart after two checks in a row say it's down (a busy voice can be slow to answer once)
  if [ "$kv" = down ] && [ ! -e "$DIR/.kdown" ]; then touch "$DIR/.kdown"; kv=slow; elif [ "$kv" = up ]; then rm -f "$DIR/.kdown"; fi
  if [ "$kv" = down ] && [ "${DJ_ENGINE:-kokoro}" = kokoro ] && [ $((now - khk)) -ge 300 ] && launchctl print "gui/$(id -u)/com.nova.voice" >/dev/null 2>&1; then
    last_kfix=$now; kv=restarting; rm -f "$DIR/.kdown"; launchctl kickstart -k "gui/$(id -u)/com.nova.voice" >/dev/null 2>&1 &
    echo "health $(date +%T): Kokoro voice was down, restarting it" >> "$DIR/music-debug.log"; fi
  [ "${DJ_ENGINE:-kokoro}" = kokoro ] || kv=off
  # what this Mac is drawing from the charger right now (milliwatts, Apple Silicon), for the "What Nova costs" page
  pw=$(ioreg -rw0 -c AppleSmartBattery 2>/dev/null | grep -o '"SystemPowerIn"=[0-9]*' | head -1 | grep -o '[0-9]*$'); [ -n "$pw" ] || pw=-
  ( curl -sf -m 8 -d "fmstate hb $mu $kv $now $pw" "$BUS/bus/${NOVA_TOPIC}" ) </dev/null >/dev/null 2>&1 3>&- &
fi
if [ $((now - ${last_poll:-0})) -ge 2 ]; then
  last_poll=$now
  out=$(curl -sf -m 5 "$BUS/bus/${NOVA_TOPIC}-mcmd/json?since=$last_cmd_t" 2>/dev/null)
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    t=$(printf '%s' "$line" | sed -n 's/.*"time":\([0-9]*\).*/\1/p'); m=$(printf '%s' "$line" | sed -n 's/.*"message":"\([^"]*\)".*/\1/p')
    [ -n "$t" ] && [ "$t" -gt "$last_cmd_t" ] && last_cmd_t=$t
    [ -n "$m" ] && music_cmd "$m"
  done <<< "$out"
fi
# a listener request: start it when the current song is in its last few seconds (or has already changed)
if [ -f "$DIR/.req" ] && [ "$st" = playing ]; then
  IFS='|' read -r rt rp rk rq < "$DIR/.req"
  if [ $((now - $(num "$rt"))) -gt 1200 ]; then rm -f "$DIR/.req"
  elif [ "$pid" != "$rp" ] || { [ "$(num "$du")" -gt 0 ] && [ $(( $(num "$du") - $(num "$ps") )) -le 7 ]; }; then
    rm -f "$DIR/.req"; echo "request playing $(date +%T): $rk $rq" >> "$DIR/music-debug.log"; music_cmd "$rk|$rq" >/dev/null 2>&1
  fi
fi
# Nova FM: a break is waiting -> play it as soon as a different song is playing (talks over its intro)
if [ -f "$DIR/.dj-queue" ] && [ "$st" = playing ]; then
  IFS='|' read -r qt qd qb qp qk < "$DIR/.dj-queue"
  if [ $((now - $(num "$qt"))) -gt 900 ]; then rm -f "$DIR/.dj-queue"; echo "dj expired $(date +%T)" >> "$DIR/music-debug.log"
  elif [ -n "$pid" ] && [ "$pid" = "$qp" ]; then printf '%s %s' "$ps" "$du" > "$DIR/.dj-qpos"   # how far into the song we are (to tell a finished song from a skipped one)
  elif [ -n "$pid" ] && [ "$pid" != "$qp" ]; then
    read -r lp ld < "$DIR/.dj-qpos" 2>/dev/null; lp=$(num "$lp"); ld=$(num "$ld"); rm -f "$DIR/.dj-queue" "$DIR/.dj-qpos"
    left=$((ld - lp)); lim=$((ld / 10)); [ "$lim" -lt 20 ] && lim=20
    if [ "$ld" -gt 0 ] && [ "$left" -gt "$lim" ]; then
      # the song the break was about got skipped (with ${left}s still to go): drop it, the dashboard writes a fresh one about a song you stay on
      echo "dj dropped $(date +%T): song skipped with ${left}s left" >> "$DIR/music-debug.log"; fm_post skip
    else echo "dj on air $(date +%T) over: $nm" >> "$DIR/music-debug.log"; fm_go "$(printf '%s' "$qb" | base64 -D 2>/dev/null)" "$qd" "${qk:-dj}"; fi
  fi
fi
# a copy of the recent log in Music > Nova FM, so it's easy to look at (or for Claude to read)
mkdir -p "$FMDIR" 2>/dev/null; [ "$DIR/music-debug.log" -nt "$FMDIR/nova-log.txt" ] && tail -n 400 "$DIR/music-debug.log" > "$FMDIR/nova-log.txt" 2>/dev/null
printf 'last_key=%q\nlast_pos=%q\nlast_t=%q\nsent_day=%q\nsent=%q\nlast_cmd_t=%q\nlast_poll=%q\nlast_hb=%q\nlast_kfix=%q\nlast_upd=%q\n' "$last_key" "$last_pos" "$last_t" "$sent_day" "$sent" "$last_cmd_t" "$last_poll" "$last_hb" "$last_kfix" "${last_upd:-0}" > "$SF"
