#!/bin/sh
# lightdrop installer for macOS and Linux:
#   curl -fsSL https://github.com/yakubmurcek/lightdrop/releases/latest/download/install.sh | sh
# Downloads the binary for this machine and starts the background receiver; on a
# Mac also the LightDrop notch app (drag a file to the notch to send it).
set -eu
BASE=https://github.com/yakubmurcek/lightdrop/releases/latest/download
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64)  t=darwin-arm64 ;;
  Darwin-x86_64) t=darwin-amd64 ;;
  Linux-x86_64)  t=linux-amd64 ;;
  Linux-aarch64) t=linux-arm64 ;;
  *) echo "lightdrop: no build for $(uname -s) $(uname -m)" >&2; exit 1 ;;
esac
tmp=$(mktemp)
curl -fsSL "$BASE/lightdrop-$t" -o "$tmp"
chmod +x "$tmp"
"$tmp" install
rm -f "$tmp"
if [ "$(uname -s)" = Darwin ]; then
  zip=$(mktemp)
  if curl -fsSL "$BASE/LightDrop-app.zip" -o "$zip"; then
    mkdir -p "$HOME/Applications"
    pkill -f LightDrop.app/Contents/MacOS/LightDrop 2>/dev/null || true
    rm -rf "$HOME/Applications/LightDrop.app"
    ditto -x -k "$zip" "$HOME/Applications"
    open "$HOME/Applications/LightDrop.app"
    echo "lightdrop: LightDrop is running — drag a file to the notch to send it"
  fi
  rm -f "$zip"
fi
