#!/bin/bash
set -euo pipefail
mkdir -p logs
LOGFILE="logs/build_$(date +%Y-%m-%d_%H-%M-%S).log"
echo "Starting build at $(date)" | tee -a "$LOGFILE"

# redirect ALL output
exec > >(tee -a "$LOGFILE") 2>&1
echo "=================================================="
echo "GDash Build Started"
echo "Date: $(date)"
echo "Platform: $(uname -s)"
echo "=================================================="

# Environment info
echo
echo "[ENVIRONMENT]"
echo "CC: ${CC:-default}"
echo "CXX: ${CXX:-default}"
echo "CFLAGS: ${CFLAGS:-}"
echo "CXXFLAGS: ${CXXFLAGS:-}"
echo "LDFLAGS: ${LDFLAGS:-}"
echo

sec2min() {
    printf "%d:%02d" "$((10#$1 / 60))" "$((10#$1 % 60))"
}

makei18n() {
    echo
    echo "[I18N]"
    pushd po
    make update-po
    popd
}

makeDocs() {
    echo
    echo "[DOCS]"
    pushd docs
    make Docs
    popd
}

step() {
    echo
    echo "--------------------------------------------------"
    echo "$1"
    echo "--------------------------------------------------"
}

SECONDS=0

step "Cleaning generated files"
rm -vf po/gdash.pot po/de.gmo po/hu.gmo || true
rm -vf ./configure ./config.h.in || true
find . -name "Makefile" -exec rm -vf {} \;
# NOTE: we keep po/Makefile.in.in, po/POTFILES.in

step "Creating cave list"
pushd caves
./create_makefile.sh
popd

# fix for macOS
# IMPORTANT:
# Do NOT use autoreconf here.
# autoreconf pulls in modern gettext/autopoint infrastructure
# from Homebrew (gettext 0.24), which is incompatible with
# GDash's shipped gettext 0.17 templates in po/.
# We intentionally run autotools manually to preserve the
# original gettext infrastructure.

step "Generating autotools files"
aclocal -I /opt/homebrew/opt/gettext/share/gettext/m4 -I /opt/homebrew/opt/gettext/share/aclocal
autoheader
automake --add-missing
autoconf
sed -i.bak 's/@POMAKEFILEDEPS@//g' po/Makefile.in.in
sed -i.bak 's/@UPDATEPOFILES@//g' po/Makefile.in.in
sed -i.bak 's/@GMOFILES@//g' po/Makefile.in.in
sed -i.bak 's/check-macro-version//g' po/Makefile.in.in
export CFLAGS="-I/opt/homebrew/include ${CFLAGS:-}"
export CXXFLAGS="-I/opt/homebrew/include ${CXXFLAGS:-}"
export LDFLAGS="-L/opt/homebrew/lib ${LDFLAGS:-}"

#step "Running autoreconf"
#autoreconf

step "Detecting platform"
case "$(uname -s)" in
    Linux*)
        platform=Linux
        ;;
    Darwin*)
        platform=Mac
        export LDFLAGS="${LDFLAGS:-} -framework OpenGL"
        ;;
    CYGWIN*)
        platform=cygwin
        export DISPLAY=:0.0
        ps | grep /usr/bin/xinit > /dev/null || {
            startxwin > /dev/null 2>&1 &
            echo "Waiting 5s for X server..."
            sleep 5
        }
        ;;
    MINGW*)
        platform=MinGW
        ;;
    MSYS_NT*)
        platform=Git
        ;;
    *)
        platform="UNKNOWN:$(uname -s)"
        ;;
esac
echo "Platform: $platform"

step "Configure"
./configure CPPFLAGS=-Wno-deprecated-declarations
# Workaround for old gettext infrastructure on modern macOS/Homebrew
# Inject missing top_builddir into generated po/Makefile
sed -i.bak '1s/^/top_builddir = ..\
\
/' po/Makefile
# step "Clean"
# make clean
step "Translations"
makei18n
step "Build"
make -j$(sysctl -n hw.ncpu 2>/dev/null || nproc || echo 4)
echo build time: $(sec2min $SECONDS)
echo -e "\a"

step "Documentation"
makeDocs

echo
echo "=================================================="
echo "Build completed successfully"
echo "Build time: $(sec2min $SECONDS)"
echo "Logfile: $LOGFILE"
echo "=================================================="
echo -e "\a"