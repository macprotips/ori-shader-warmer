#!/bin/zsh
# warm.sh <game dir> <wine binary> <bottle>
#
# Builds Ori's shader caches from scratch and installs them. Runs from the app bundle's Resources folder,
# next to extract, oriwarm_t.exe and plan.txt.gz.
#
# Output, one line each, for the app to parse:
#   PHASE <n> <label>   PROGRESS <done> <total>   ERROR <message>   DONE <summary>
#
# Set NOINSTALL=1 to build without replacing the caches the game reads.

R="${0:a:h}"; GAME="$1"; WINE="$2"; BOTTLE="$3"
WORK="$HOME/Library/Application Support/Ori Shader Warmer"
WINWORK="Z:${WORK//\//\\}"
CACHES="$(getconf DARWIN_USER_CACHE_DIR)"
D3DM="$CACHES/d3dm"
BUILT="$D3DM/oriwarm_t.exe/shaders.cache"

fail() { echo "ERROR $1"; exit 1; }
trap 'pkill -9 -f oriwarm_t.exe; exit 2' TERM INT

[[ -d "$GAME/oriwotw_Data" ]] || fail "That folder doesn't look like Ori and the Will of the Wisps."
[[ -x "$WINE" ]] || fail "CrossOver wasn't found."
ps -Ao command | grep -q '^C:.*[o]riwotw.exe' && fail "Ori is running. Quit the game and try again."
mkdir -p "$WORK"

echo "PHASE 1 Reading the game's shaders"
setopt pipefail
rm -rf "$WORK/shaders"
"$R/extract" "$GAME" "$WORK/shaders" | grep --line-buffered '^PROGRESS' || fail "Couldn't read the game's shaders."

echo "PHASE 2 Starting the shader compiler"
cp "$R/oriwarm_t.exe" "$WORK/"
gunzip -c "$R/plan.txt.gz" > "$WORK/plan.txt"
rm -f "$WORK/warm.log"
rm -rf "$D3DM/oriwarm_t.exe"
total=$(( $(wc -l < "$WORK/plan.txt") ))
skip=0; started=

# If the compiler crashes, restart it after the draw that crashed. What it has cached so far is kept.
for attempt in 1 2 3 4 5 6; do
  WINEDLLOVERRIDES="winedbg.exe=d" "$WINE" --bottle "$BOTTLE" --workdir "$WINWORK" "$WINWORK\\oriwarm_t.exe" \
    "$WINWORK\\shaders" --plan "$WINWORK\\plan.txt" --skipdraws $skip --sleep 20000 >/dev/null 2>&1 &
  pid=$!
  while kill -0 $pid 2>/dev/null; do
    n=$(grep -c '^DRAW' "$WORK/warm.log" 2>/dev/null)
    if [[ -z $started && ${n:-0} -gt 0 ]]; then started=1; echo "PHASE 2 Compiling shaders"; fi
    echo "PROGRESS $(( skip + ${n:-0} )) $total"
    sleep 1
  done
  grep -q '^SUMMARY' "$WORK/warm.log" 2>/dev/null && break
  last=$(grep '^DRAW' "$WORK/warm.log" 2>/dev/null | tail -1 | awk '{print $2}')
  [[ -n "$last" ]] || fail "The shader compiler didn't start. Check that D3DMetal is enabled for the \"$BOTTLE\" bottle in CrossOver."
  skip=$(( last + 1 ))
  pkill -9 -f oriwarm_t.exe
done
grep -q '^SUMMARY' "$WORK/warm.log" || fail "The shader compiler kept crashing."
echo "PROGRESS $total $total"

echo "PHASE 3 Installing"
# Metal names its cache folder after this Mac's GPU and macOS build.
data=$(ls "$BUILT"/*/functions.data 2>/dev/null | head -1)
[[ -n "$data" ]] || fail "No shader cache was produced. Check that D3DMetal is enabled for the \"$BOTTLE\" bottle in CrossOver."
metal="${data:h}"

# Metal starts evicting entries from a cache file at about 1 GB.
size=$(stat -f %z "$data")
(( size > 1040000000 )) && fail "The cache came out larger than macOS allows ($(( size >> 20 )) MB)."

if [[ -z "${NOINSTALL:-}" ]]; then
  # Each process uses one of the numbered cache files, whichever is free when it starts, so install into the first four.
  shared="$CACHES/com.codeweavers.CrossOver.wineloader/com.apple.metal/${metal:t}"
  mkdir -p "$shared"
  for n in "" 1 2 3; do
    for ext in data list; do
      cp -c "$metal/functions.$ext" "$shared/functions$n.$ext.new" && mv "$shared/functions$n.$ext.new" "$shared/functions$n.$ext" \
        || fail "Couldn't install the cache."
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
