#!/bin/zsh
# warm.sh <game dir> <wine binary>
#
# Builds Ori's shader caches from scratch and installs them. Runs from the app bundle's Resources folder,
# next to extract, oriwarm_t.exe and plan.txt.gz.
#
# Environment:
#   BOTTLE         CrossOver bottle to run in. Without it, the Wine environment (WINEPREFIX etc.) is used as given.
#                  D3DMetal is used either way, whatever the bottle is set to.
#   METAL_CACHES   Folders in the user cache directory to install the Metal cache into, one per line.
#   NOINSTALL=1    Build without replacing the caches the game reads.
#
# Output, one line each, for the app to parse:
#   PHASE <n> <label>   PROGRESS <done> <total>   ERROR <message>   DONE <summary>

R="${0:a:h}"; GAME="$1"; WINE="$2"
WORK="$HOME/Library/Application Support/Ori Shader Warmer"
WINWORK="Z:${WORK//\//\\}"
CACHES="$(getconf DARWIN_USER_CACHE_DIR)"
D3DM="$CACHES/d3dm"
BUILT="$D3DM/oriwarm_t.exe/shaders.cache"

fail() { echo "ERROR $1"; exit 1; }
trap 'kill $(jobs -p) 2>/dev/null; pkill -9 -f oriwarm_t.exe; exit 2' TERM INT

[[ -d "$GAME/oriwotw_Data" ]] || fail "That folder doesn't look like Ori and the Will of the Wisps."
[[ -x "$WINE" ]] || fail "CrossOver or NotProton wasn't found."
# A running game shows up as a Windows path, e.g. C:\...\oriwotw.exe.
ps -Ao command | grep -qiE '^[a-z]:\\.*oriwotw\.exe' && fail "Ori is running. Quit the game and try again."
# Programs still running under Wine hold Metal cache files open and would overwrite the new ones.
# Wine takes a few seconds to wind down after its last program quits, so give it a moment.
crossover_busy() { pgrep -qf 'CrossOver.*wineserver'; }
for i in {1..15}; do crossover_busy || break; sleep 1; done
crossover_busy && fail "Quit Steam and any other programs running in CrossOver or NotProton, then try again."
(( $(df -k "$HOME" | awk 'NR==2 {print $4}') > 3000000 )) || fail "Not enough free disk space. About 3 GB is needed."
mkdir -p "$WORK"

echo "PHASE 1 Reading the game's shaders"
setopt pipefail
rm -rf "$WORK/shaders"
"$R/extract" "$GAME" "$WORK/shaders" | grep --line-buffered '^PROGRESS' &
wait $! || fail "Couldn't read the game's files. If macOS asked for access, allow it in System Settings, Privacy & Security, then try again."
gunzip -c "$R/plan.txt.gz" > "$WORK/plan.txt" || fail "Couldn't unpack the shader list. Check that there is free disk space."

# The recipe names shaders by content. If most are missing, this is a game version the recipe wasn't made for.
missing=$(awk 'NR == FNR { have[$1] = 1; next } { n++; if (!($1 in have)) m++ } END { print int(100 * m / n) }' \
  <(ls "$WORK/shaders" | sed 's/\.dxbc$//') "$WORK/plan.txt")
[[ "$missing" == <-> ]] && (( missing < 10 )) || fail "This version of Ori isn't supported yet."

echo "PHASE 2 Starting the shader compiler"
# Clear the cache files this run will replace before compiling. Left-over entries from another D3DMetal
# version in them were seen to spoil a build.
if [[ -z "${NOINSTALL:-}" ]]; then
  for folder in ${(f)METAL_CACHES:-com.codeweavers.CrossOver.wineloader}; do
    rm -f "$CACHES/$folder"/com.apple.metal/*/functions{,1,2,3}.{data,list}(N)
  done
fi
cp "$R/oriwarm_t.exe" "$WORK/"
rm -f "$WORK/warm.log"
rm -rf "$D3DM/oriwarm_t.exe"
total=$(awk 'NR == FNR { have[$1] = 1; next } ($1 in have) && ($2 == "-" || $2 in have) { n++ } END { print n + 0 }' \
  <(ls "$WORK/shaders" | sed 's/\.dxbc$//') "$WORK/plan.txt")
skip=0; started=

compile() {
  if [[ -n "$BOTTLE" ]]; then
    "$WINE" --bottle "$BOTTLE" --workdir "$WINWORK" "$WINWORK\\oriwarm_t.exe" "$@"
  else
    (cd "$WORK" && "$WINE" "$WINWORK\\oriwarm_t.exe" "$@")
  fi
}

# If the compiler crashes or stops making progress, restart it after the last draw it finished.
# What it has cached so far is kept.
for attempt in 1 2 3 4 5 6; do
  rm -f "$WORK/warm.log"
  CX_GRAPHICS_BACKEND=d3dmetal WINEDLLOVERRIDES="winedbg.exe=d" WINEDEBUG=-all compile "$WINWORK\\shaders" --plan "$WINWORK\\plan.txt" \
    --skipdraws $skip --sleep 20000 >/dev/null 2>&1 &
  pid=$!
  seen=-1; still=0
  while kill -0 $pid 2>/dev/null; do
    n=$(grep -c '^DRAW' "$WORK/warm.log" 2>/dev/null); n=${n:-0}
    if [[ -z $started && $n -gt 0 ]]; then started=1; echo "PHASE 2 Compiling shaders"; fi
    echo "PROGRESS $(( skip + n )) $total"
    if (( n == seen && n > 0 )); then (( ++still > 300 )) && break; else seen=$n; still=0; fi   # stuck for 5 minutes
    sleep 1
  done
  grep -q '^SUMMARY' "$WORK/warm.log" 2>/dev/null && break
  pkill -9 -f oriwarm_t.exe
  last=$(grep '^DRAW' "$WORK/warm.log" 2>/dev/null | tail -1 | awk '{print $2}')
  if [[ -n "$last" ]]; then skip=$(( last + 1 ))
  elif (( attempt == 1 )); then fail "The shader compiler didn't start. Make sure CrossOver can run programs in the \"$BOTTLE\" bottle."
  fi
  sleep 2
done
grep -q '^SUMMARY' "$WORK/warm.log" || fail "The shader compiler kept crashing."
echo "PROGRESS $total $total"

echo "PHASE 3 Installing"
# Metal names its cache folder after this Mac's GPU and macOS build.
data=$(ls "$BUILT"/*/functions.data 2>/dev/null | head -1)
[[ -n "$data" ]] || fail "No shader cache was produced. Make sure D3DMetal is available in your version of CrossOver."
metal="${data:h}"

if [[ -z "${NOINSTALL:-}" ]]; then
  trap '' TERM INT   # a half-installed cache is worse than finishing the last few seconds
  # Each process uses one of the numbered cache files, whichever is free when it starts, so install into the first four.
  for folder in ${(f)METAL_CACHES:-com.codeweavers.CrossOver.wineloader}; do
    shared="$CACHES/$folder/com.apple.metal/${metal:t}"
    mkdir -p "$shared"
    for n in "" 1 2 3; do
      for ext in data list; do
        cp -c "$metal/functions.$ext" "$shared/functions$n.$ext.new" && mv "$shared/functions$n.$ext.new" "$shared/functions$n.$ext" \
          || fail "Couldn't install the cache."
      done
    done
  done
  # D3DMetal's own cache for the game.
  mkdir -p "$D3DM/oriwotw.exe/shaders.cache"
  for dir in "$BUILT"/MTLGPUFamily*(N); do
    rm -rf "$D3DM/oriwotw.exe/shaders.cache/${dir:t}"
    cp -cR "$dir" "$D3DM/oriwotw.exe/shaders.cache/"
  done
fi

rm -rf "$WORK/shaders" "$WORK/plan.txt"
echo "DONE $total shader combinations ready"
