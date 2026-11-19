#!/bin/bash
# Renders the before and after pictures of the README: scripts/fixtures/example.html as a Retina
# capture, and the same capture after Fosco blurred it. Needs build/Fosco.app (scripts/build-app.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
CHROME="${CHROME:-$(find "$HOME/.agent-browser/browsers" "$HOME/Library/Caches/ms-playwright" -maxdepth 6 -type f -name 'Google Chrome for Testing' 2>/dev/null | sort | tail -1)}"
[ -x "$CHROME" ] || { echo "Chrome for Testing not found; set CHROME=/path/to/chrome" >&2; exit 1; }

"$CHROME" --headless=new --hide-scrollbars --window-size=760,300 --force-device-scale-factor=2 \
  --screenshot="$PWD/docs/before.png" "file://$PWD/scripts/fixtures/example.html" >/dev/null 2>&1
# Captures of a Retina display say so in their resolution, and Fosco reads text at the size that implies.
sips -s dpiWidth 144 -s dpiHeight 144 docs/before.png >/dev/null
build/Fosco.app/Contents/MacOS/Fosco redact docs/before.png docs/after.png
