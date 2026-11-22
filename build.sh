#!/usr/bin/env bash
# Build lightdrop for every platform into dist/ (needs Go).
# Publish: see README.md. VERSION=<tag> stamps it into the binaries (lightdrop version).
set -euo pipefail
cd "$(dirname "$0")"
go vet ./... && go test ./...
mkdir -p dist
for t in darwin/arm64 darwin/amd64 linux/amd64 linux/arm64 windows/amd64; do
  os=${t%/*} arch=${t#*/} ext=''
  [ "$os" = windows ] && ext=.exe
  CGO_ENABLED=0 GOOS=$os GOARCH=$arch go build -trimpath -ldflags "-s -w -X main.version=${VERSION:-dev}" \
    -o "dist/lightdrop-$os-$arch$ext" .
done
ls -la dist
