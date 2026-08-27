#!/bin/bash
# Renders assets/dranik-icon.svg into assets/Dranik.icns.
#
# Needs rsvg-convert (brew install librsvg). The .icns is committed so that
# `make app` never needs it — this only has to run when the artwork changes.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v rsvg-convert >/dev/null; then
    echo "rsvg-convert not found. brew install librsvg" >&2
    exit 1
fi

SET=$(mktemp -d)/Dranik.iconset
mkdir -p "$SET"

render() { rsvg-convert -w "$1" -h "$1" assets/dranik-icon.svg -o "$SET/$2"; }

render 16   icon_16x16.png
render 32   icon_16x16@2x.png
render 32   icon_32x32.png
render 64   icon_32x32@2x.png
render 128  icon_128x128.png
render 256  icon_128x128@2x.png
render 256  icon_256x256.png
render 512  icon_256x256@2x.png
render 512  icon_512x512.png
render 1024 icon_512x512@2x.png

iconutil -c icns "$SET" -o assets/Dranik.icns
rm -rf "$(dirname "$SET")"
echo "wrote assets/Dranik.icns ($(du -h assets/Dranik.icns | cut -f1))"
