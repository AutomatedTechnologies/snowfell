#!/bin/sh
# Snowfell build entry point — thin wrapper over the Makefile manifest.
#   ./build.sh check   syntax-check all sources against the 10.13 SDK
#   ./build.sh app     assemble Snowfell.app (macOS only)
set -eu
cd "$(dirname "$0")"
exec make "${1:-check}"
