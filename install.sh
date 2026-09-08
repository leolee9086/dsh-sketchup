#!/usr/bin/env bash
set -euo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PLUGINS=${SKETCHUP_PLUGINS_DIR:-"$HOME/Library/Application Support/SketchUp 2024/SketchUp/Plugins"}
if [ ! -d "$PLUGINS" ]; then echo "SketchUp Plugins directory not found: $PLUGINS" >&2; exit 1; fi
STAMP=$(date +%Y%m%d-%H%M%S)
if [ -f "$PLUGINS/dsh_sketchup_bridge.rb" ]; then cp "$PLUGINS/dsh_sketchup_bridge.rb" "$PLUGINS/dsh_sketchup_bridge.rb.bak-$STAMP"; fi
rm -rf "$PLUGINS/dsh_sketchup_bridge.bak-$STAMP"
if [ -d "$PLUGINS/dsh_sketchup_bridge" ]; then mv "$PLUGINS/dsh_sketchup_bridge" "$PLUGINS/dsh_sketchup_bridge.bak-$STAMP"; fi
cp "$ROOT/ruby/dsh_sketchup_bridge.rb" "$PLUGINS/"
cp -R "$ROOT/ruby/dsh_sketchup_bridge" "$PLUGINS/"
if command -v dsh >/dev/null 2>&1; then
  dsh plugin --profile web add -w "@yuxianglin/dsh-bridge-sketchup@link:$ROOT"
else
  echo "Ruby extension installed; dsh was not found, so register the Host package manually." >&2
fi
echo "Installed SketchUp Ruby extension and Host package. Restart DSH and SketchUp."