#!/bin/bash
DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$DIR"
echo "Loading GDash... please wait..."
exec ./MacOS/gdash "$@" \
  > ~/Library/Logs/gdash.log 2>&1
