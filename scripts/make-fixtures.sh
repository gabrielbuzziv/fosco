#!/bin/bash
# Renders scripts/fixtures/dashboard.html in headless Chrome into the screenshots + ground-truth
# JSON that the tests use. Only needed when the fixture page changes.
set -euo pipefail
cd "$(dirname "$0")/.."
CHROME="${CHROME:-$(find "$HOME/.agent-browser/browsers" "$HOME/Library/Caches/ms-playwright" -maxdepth 6 -type f -name 'Google Chrome for Testing' 2>/dev/null | sort | tail -1)}"
[ -x "$CHROME" ] || { echo "Chrome for Testing not found; set CHROME=/path/to/chrome" >&2; exit 1; }
OUT="Tests/FoscoCoreTests/Fixtures"
PAGE="file://$PWD/scripts/fixtures/dashboard.html"

render() { # name width height scale query
  local name=$1 size="$2,$3" scale=$4 url="$PAGE?$5"
  "$CHROME" --headless=new --hide-scrollbars --window-size="$size" --force-device-scale-factor="$scale" \
    --screenshot="$PWD/$OUT/$name.png" "$url" >/dev/null 2>&1
  "$CHROME" --headless=new --hide-scrollbars --window-size="$size" --force-device-scale-factor="$scale" \
    --virtual-time-budget=2000 --dump-dom "$url" 2>/dev/null \
    | python3 -c 'import sys, re, html; m = re.search(r"<pre id=\"truth\">(.*?)</pre>", sys.stdin.read(), re.S); sys.stdout.write(html.unescape(m.group(1)))' \
    > "$OUT/$name.json"
  echo "$name: $(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["width"], "x", d["height"], "@", d["scale"], "targets", len(d["targets"]), "decoys", len(d["decoys"]))' "$OUT/$name.json")"
}

render dashboard-light-1x 2560 1440 1 "theme=light&h=1340"
render dashboard-dark-1x  2560 1440 1 "theme=dark&h=1340"
render dashboard-light-2x 1720 1100 2 "theme=light&h=1000"
render dashboard-small-1x 2560 1440 1 "theme=dark&zoom=0.85&h=1340"
