#!/usr/bin/env bash
# Publish a fresh build as a GitHub release: the install lines download from the
# latest one. Run after build.sh (and build-app.sh on a Mac): bash publish.sh
set -euo pipefail
cd "$(dirname "$0")"
REPO=yakubmurcek/lightdrop
git push -q origin HEAD   # the release's tag points at this commit
tag=v$(date +%Y.%m.%d) n=1
while gh release view "$tag" -R "$REPO" >/dev/null 2>&1; do n=$((n + 1)); tag=v$(date +%Y.%m.%d).$n; done
files=(dist/lightdrop-* install.sh install.ps1)
# The Mac app is built on a Mac (build-app.sh); without it Macs keep the app they have.
if [ -f dist/LightDrop-app.zip ]; then files+=(dist/LightDrop-app.zip); else echo "no dist/LightDrop-app.zip: the Mac app is not updated"; fi
gh release create "$tag" -R "$REPO" --target "$(git rev-parse HEAD)" --title "lightdrop $tag" \
  --notes "Install or update: run the install line from the README." "${files[@]}"
