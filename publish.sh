#!/usr/bin/env bash
# Publish: GitHub runs CI on main, builds every binary and the Mac app, and makes
# a release under a date tag. The install lines download from the latest release.
set -euo pipefail
REPO=yakubmurcek/lightdrop
gh workflow run release.yml -R "$REPO" --ref main
sleep 5
run=$(gh run list -R "$REPO" --workflow release.yml --limit 1 --json databaseId --jq '.[0].databaseId')
gh run watch "$run" -R "$REPO" --exit-status
gh release view -R "$REPO" --json tagName,url --jq '"published \(.tagName): \(.url)"'
