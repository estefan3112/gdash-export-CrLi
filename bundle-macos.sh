#!/bin/bash
#
# bundle-macos.sh - build a self-contained GDash.app for Apple Silicon Macs.
#
# Run after ./make-all.sh. Result: build/GDash.app (and build/GDash-macos-arm64.zip)
#
# Needs (Homebrew): gtk+3 librsvg adwaita-icon-theme dylibbundler
#
# Why this script exists:
#   GTK3 draws its check boxes, spin buttons etc. with *SVG* symbolic icons.
#   If the gdk-pixbuf SVG loader can't be loaded, GTK aborts with
#     "ensure_surface_for_gicon: assertion failed ... Unable to load image-loading module"
#   which is exactly the crash when opening Preferences.
#   The old bundle had a loaders.cache with absolute /tmp/... paths from the machine
#   it was built on, and loaders still linked against /opt/homebrew. This script
#   relocates the loaders and lets launch.sh write a fresh loaders.cache at start.
#
# Optional: SIGN_ID="Developer ID Application: ..." NOTARY_PROFILE=notary ./bundle-macos.sh

set -euo pipefail

BREW="$(brew --prefix)"
SRC="$(cd "$(dirname "$0")" && pwd)"
APP="$SRC/build/GDash.app"
C="$APP/Contents"
LOADER_REL="lib/gdk-pixbuf-2.0/2.10.0/loaders"
BREW_LOADERS="$BREW/lib/gdk-pixbuf-2.0/2.10.0/loaders"

step() { echo; echo "== $1"; }

# ---------------------------------------------------------------- checks
[ -x "$SRC/src/gdash" ] || { echo "src/gdash not found - run ./make-all.sh first"; exit 1; }
command -v dylibbundler >/dev/null || { echo "missing: brew install dylibbundler"; exit 1; }
ls "$BREW_LOADERS"/libpixbufloader_svg.so >/dev/null 2>&1 \
  || ls "$BREW_LOADERS"/libpixbufloader-svg.so >/dev/null 2>&1 \
  || { echo "SVG pixbuf loader missing: brew install librsvg"; exit 1; }
[ -d "$BREW/share/icons/Adwaita" ] || { echo "missing: brew install adwaita-icon-theme"; exit 1; }

# ---------------------------------------------------------------- layout
step "Creating bundle skeleton"
rm -rf "$APP"
mkdir -p "$C/MacOS" "$C/Resources" "$C/libs" "$C/$LOADER_REL" \
         "$C/share/glib-2.0/schemas" "$C/share/icons"

cp "$SRC/src/gdash"   "$C/MacOS/gdash"
cp "$SRC/launch.sh"   "$C/MacOS/launch.sh"
chmod +x "$C/MacOS/launch.sh" "$C/MacOS/gdash"
cp "$SRC/Info.plist"  "$C/Info.plist"
cp "$SRC/AppIcon.icns" "$C/Resources/AppIcon.icns"

step "Copying game data"
# GDash looks for caves/, music/, themes/ ... in the current dir (launch.sh cd's to Contents)
for d in caves docs music shaders sound themes; do
    [ -d "$SRC/$d" ] || continue
    rsync -a --exclude 'Makefile*' --exclude '*.sh' --exclude '*.o' --exclude '.deps' "$SRC/$d" "$C/"
done
cp "$SRC/gamecontrollerdb.txt" "$C/" 2>/dev/null || true

step "Copying translations"
# bindtextdomain(PACKAGE, cwd) -> Contents/<lang>/LC_MESSAGES/gdash.mo
for gmo in "$SRC"/po/*.gmo; do
    [ -f "$gmo" ] || continue
    lang="$(basename "$gmo" .gmo)"
    mkdir -p "$C/$lang/LC_MESSAGES"
    cp "$gmo" "$C/$lang/LC_MESSAGES/gdash.mo"
done

# ---------------------------------------------------------------- pixbuf loaders
step "Copying gdk-pixbuf loaders"
for f in "$BREW_LOADERS"/*.so; do
    cp -L "$f" "$C/$LOADER_REL/"
done
chmod u+w "$C/$LOADER_REL"/*.so

step "Generating loaders.cache template"
# Query the ORIGINAL Homebrew loaders (they resolve their own @rpath/@loader_path
# deps there), then replace each module's directory with a placeholder that
# launch.sh fills in at start-up.
GDK_PIXBUF_MODULEDIR="$BREW_LOADERS" "$BREW/bin/gdk-pixbuf-query-loaders" \
  | sed -E 's|^"[^"]*/(libpixbufloader[^"/]*)"|"@LOADERDIR@/\1"|' \
  > "$C/$LOADER_REL/../loaders.cache.in"
grep -q svg "$C/$LOADER_REL/../loaders.cache.in" || { echo "SVG loader did not register!"; exit 1; }

# ---------------------------------------------------------------- dylibs
step "Bundling dylibs (gdash + loaders)"
XARGS=(-x "$C/MacOS/gdash")
for f in "$C/$LOADER_REL"/*.so; do XARGS+=(-x "$f"); done
dylibbundler -of -b "${XARGS[@]}" \
    -d "$C/libs" -p @executable_path/../libs/ \
    -s "$BREW/lib" -s "$BREW/opt/librsvg/lib"

step "Removing duplicate LC_RPATH entries"
# dylibbundler rewrites every rpath to the same @executable_path/../libs/.
# A file that had two rpaths (e.g. the librsvg SVG loader) ends up with a
# duplicate, and current macOS dyld refuses to load it ("duplicate LC_RPATH").
rpaths() { otool -l "$1" | awk '/cmd LC_RPATH/{getline; getline; print $2}'; }
for f in "$C/MacOS/gdash" "$C/libs"/*.dylib "$C/$LOADER_REL"/*.so; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    for rp in $(rpaths "$f" | sort | uniq -d); do
        while [ "$(rpaths "$f" | grep -cxF "$rp")" -gt 1 ]; do
            install_name_tool -delete_rpath "$rp" "$f"
        done
        echo "  fixed: $(basename "$f")"
    done
done

step "Adding SDL3 (Homebrew's sdl2 is sdl2-compat, which dlopen()s SDL3 at start)"
if strings -a "$C/libs/libSDL2-2.0.0.dylib" | grep -q "libSDL3"; then
    SDL3="$BREW/opt/sdl3/lib/libSDL3.0.dylib"
    [ -f "$SDL3" ] || { echo "missing: brew install sdl3"; exit 1; }
    cp -L "$SDL3" "$C/libs/libSDL3.dylib"   # sdl2-compat looks for @loader_path/libSDL3.dylib
    chmod u+w "$C/libs/libSDL3.dylib"
    install_name_tool -id @executable_path/../libs/libSDL3.dylib "$C/libs/libSDL3.dylib"
    echo "  bundled libSDL3.dylib"
else
    echo "  real SDL2 - nothing to do"
fi

step "Checking for leftover Homebrew references"
leftover=0
for f in "$C/MacOS/gdash" "$C/libs"/*.dylib "$C/$LOADER_REL"/*.so; do
    if otool -L "$f" | tail -n +2 | grep -q "$BREW"; then
        echo "  still links Homebrew: $f"; otool -L "$f" | grep "$BREW"; leftover=1
    fi
done
[ $leftover -eq 0 ] && echo "  none - bundle is self-contained"

# ---------------------------------------------------------------- GTK data
step "Copying icon themes"
cp -RL "$BREW/share/icons/Adwaita" "$C/share/icons/"
[ -d "$BREW/share/icons/hicolor" ] && cp -RL "$BREW/share/icons/hicolor" "$C/share/icons/" || true
for t in "$C/share/icons"/*; do
    "$BREW/bin/gtk3-update-icon-cache" -q -f -t "$t" 2>/dev/null || true
done

step "Compiling GSettings schemas (needed by the GTK file chooser)"
cp "$BREW"/share/glib-2.0/schemas/org.gtk.Settings.*.gschema.xml "$C/share/glib-2.0/schemas/"
"$BREW/bin/glib-compile-schemas" "$C/share/glib-2.0/schemas"

# ---------------------------------------------------------------- sign + zip
step "Code signing"
# codesign --deep only signs code in standard places (MacOS/, Frameworks/, PlugIns/),
# NOT our libs/ and lib/.../loaders/. Every file touched by install_name_tool has a
# broken signature, and macOS kills the process when such a page is mapped.
# So: sign every Mach-O ourselves, inside-out, then the app.
if [ -n "${SIGN_ID:-}" ]; then
    SIGN_ARGS=(--force --options runtime --timestamp --sign "$SIGN_ID")
else
    SIGN_ARGS=(--force --sign -)
fi
for f in "$C/libs"/*.dylib "$C/$LOADER_REL"/*.so "$C/$LOADER_REL"/*.dylib; do
    [ -f "$f" ] || continue
    [ -L "$f" ] && continue
    codesign "${SIGN_ARGS[@]}" "$f"
done
codesign "${SIGN_ARGS[@]}" "$C/MacOS/gdash"
if [ -n "${SIGN_ID:-}" ]; then
    codesign --force --deep --options runtime --timestamp --sign "$SIGN_ID" "$APP"
else
    codesign --force --deep --sign - "$APP"     # ad-hoc, enough to run locally
fi
codesign --verify --deep --verbose=1 "$APP"

step "Zipping"
rm -f "$SRC/build/GDash-macos-arm64.zip"
ditto -c -k --keepParent "$APP" "$SRC/build/GDash-macos-arm64.zip"

# ---------------------------------------------------------------- notarize
# Local:  SIGN_ID="Developer ID Application: ..." NOTARY_PROFILE=notary ./bundle-macos.sh
# CI:     NOTARY_APPLE_ID / NOTARY_TEAM_ID / NOTARY_PASSWORD set by the workflow
if [ -n "${SIGN_ID:-}" ] && { [ -n "${NOTARY_PROFILE:-}" ] || [ -n "${NOTARY_APPLE_ID:-}" ]; }; then
    step "Notarizing (takes a few minutes)"
    if [ -n "${NOTARY_PROFILE:-}" ]; then
        AUTH=(--keychain-profile "$NOTARY_PROFILE")
    else
        AUTH=(--apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD")
    fi
    OUT="$(xcrun notarytool submit "$SRC/build/GDash-macos-arm64.zip" "${AUTH[@]}" --wait)"
    echo "$OUT"
    if ! echo "$OUT" | grep -q "status: Accepted"; then
        SUB_ID="$(echo "$OUT" | awk '/^ *id:/{print $2; exit}')"
        echo "Notarization FAILED - log:"
        [ -n "$SUB_ID" ] && xcrun notarytool log "$SUB_ID" "${AUTH[@]}" || true
        exit 1
    fi
    step "Stapling and re-zipping"
    xcrun stapler staple "$APP"
    rm -f "$SRC/build/GDash-macos-arm64.zip"
    ditto -c -k --keepParent "$APP" "$SRC/build/GDash-macos-arm64.zip"
    spctl -a -vv "$APP" || true
else
    echo
    echo "(not notarized - set SIGN_ID and NOTARY_PROFILE to notarize)"
fi

echo
echo "Done: $APP"
echo "      $SRC/build/GDash-macos-arm64.zip"
