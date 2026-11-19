#!/bin/bash
# Builds Fosco, replaces the installed copy and starts it.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh
DESTINATION="${DESTINATION:-/Applications/Fosco.app}"

# SIGTERM makes the running copy quit cleanly; wait for it before replacing its files.
if pkill -x Fosco 2>/dev/null; then
  for _ in $(seq 50); do pgrep -x Fosco >/dev/null || break; sleep 0.1; done
fi
rm -rf "$DESTINATION"
cp -R build/Fosco.app "$DESTINATION"
open "$DESTINATION"
echo "installed $DESTINATION"
