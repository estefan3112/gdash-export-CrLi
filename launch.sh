#!/bin/bash
DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$DIR"
echo "Loading GDash... please wait..."
export XDG_DATA_DIRS="$DIR/share"
export GDK_PIXBUF_MODULEDIR="$DIR/lib/gdk-pixbuf-2.0/2.10.0/loaders"
export GDK_PIXBUF_MODULE_FILE="$DIR/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache"
exec ./MacOS/gdash "$@" \
  > ~/Library/Logs/gdash.log 2>&1
