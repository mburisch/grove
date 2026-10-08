#!/bin/zsh
# Turns a 1024×1024 SVG or PNG into the app icon set at App/Assets.xcassets/AppIcon.appiconset.
# The icon source is design/AppIcon.svg.
# The image should follow the macOS icon grid: the rounded-square body is about 824×824,
# centered, with a transparent margin around it.
#
# Usage: scripts/make-app-icon.sh design/AppIcon.svg
set -euo pipefail

SRC="${1:?usage: scripts/make-app-icon.sh design/AppIcon.svg}"
[[ -f "$SRC" ]] || { echo "error: $SRC not found" >&2; exit 1; }
read -r W H <<< "$(sips -g pixelWidth -g pixelHeight "$SRC" | awk '/pixel/ {printf "%d ", $2}')"
[[ "$W" == 1024 && "$H" == 1024 ]] || { echo "error: $SRC is ${W}×${H}, expected 1024×1024" >&2; exit 1; }

cd "$(dirname "$0")/.."
SET="App/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$SET"
rm -f "$SET"/icon_*.png(N)

images=()
for size in 16 32 128 256 512; do
  for scale in 1 2; do
    px=$(( size * scale ))
    suffix=""; (( scale == 2 )) && suffix="@2x"
    name="icon_${size}x${size}${suffix}.png"
    sips -s format png -z $px $px "$SRC" --out "$SET/$name" >/dev/null
    images+=("    { \"idiom\" : \"mac\", \"size\" : \"${size}x${size}\", \"scale\" : \"${scale}x\", \"filename\" : \"$name\" }")
  done
done

{
  echo '{'
  echo '  "images" : ['
  print -l -- "${(j:,\n:)images}"
  echo '  ],'
  echo '  "info" : { "author" : "xcode", "version" : 1 }'
  echo '}'
} > "$SET/Contents.json"

echo "==> $SET"
