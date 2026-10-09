#!/bin/sh
# Build and install the local Hammerspoon proxy helper as a root-owned Setuid binary.

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SOURCE="$SCRIPT_DIR/setproxy.c"
BINARY="$SCRIPT_DIR/setproxy"
TEMP_BINARY="$SCRIPT_DIR/setproxy.new"

cleanup() {
	rm -f "$TEMP_BINARY"
}
trap cleanup EXIT INT TERM

clang -std=c17 -Wall -Wextra -Wpedantic -O2 -o "$TEMP_BINARY" "$SOURCE"
mv -f "$TEMP_BINARY" "$BINARY"

sudo chown root:wheel "$BINARY"
sudo chmod 4755 "$BINARY"

ls -l "$BINARY"
