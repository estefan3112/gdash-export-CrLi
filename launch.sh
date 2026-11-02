#!/bin/bash
# GDash.app launcher (CFBundleExecutable). Lives in Contents/MacOS.
DIR="$(cd "$(dirname "$0")/.." && pwd)"     # = .../GDash.app/Contents
cd "$DIR"                                    # GDash finds caves/, themes/, ... in cwd

LOG=~/Library/Logs/gdash.log
CACHE_DIR=~/Library/Caches/GDash
LOADERS="$DIR/lib/gdk-pixbuf-2.0/2.10.0/loaders"
mkdir -p "$CACHE_DIR" ~/Library/Logs

# loaders.cache needs absolute paths, but the app can live anywhere
# (/Applications, ~/Downloads, ...). Write a fresh one for the current location.
sed "s|@LOADERDIR@|$LOADERS|g" "$DIR/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache.in" \
    > "$CACHE_DIR/loaders.cache"

export XDG_DATA_DIRS="$DIR/share"
export GSETTINGS_SCHEMA_DIR="$DIR/share/glib-2.0/schemas"
export GDK_PIXBUF_MODULEDIR="$LOADERS"
export GDK_PIXBUF_MODULE_FILE="$CACHE_DIR/loaders.cache"
# sdl2-compat finds libSDL3.0.dylib by name at runtime -> look in our libs/ first
export DYLD_FALLBACK_LIBRARY_PATH="$DIR/libs:/usr/local/lib:/usr/lib"

{
    echo "=== GDash start $(date) ==="
    echo "Contents: $DIR"
} > "$LOG"

exec ./MacOS/gdash "$@" >> "$LOG" 2>&1
