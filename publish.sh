#!/usr/bin/env bash
# Publish a fresh build to the lightdrop gist (where the installers download
# from). Run after build.sh: bash publish.sh
set -euo pipefail
git() { command git -c credential.helper= -c "credential.helper=!gh auth git-credential" "$@"; }
cd "$(dirname "$0")"
GIST=7cc69d2af1db4b710846e113a69fcae2
work=$(mktemp -d)
trap 'rm -r "$work"' EXIT
git clone -q "https://gist.github.com/$GIST.git" "$work"
cp dist/lightdrop-* install.sh install.ps1 "$work/"
# The Mac app is built on a Mac (build-app.sh) and copied into dist/ here first.
cp dist/LightDrop-app.zip "$work/" 2>/dev/null || echo "no dist/LightDrop-app.zip: the Mac app is not updated"
rm -f "$work/drop" "$work/drop.ps1"   # the dufs-based predecessor
cd "$work"
git add -A
git -c user.name="lightdrop build" -c user.email=noreply@example.com commit -qm "lightdrop build" || echo "nothing changed"
git push -q "$@"
