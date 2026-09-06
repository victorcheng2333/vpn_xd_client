#!/bin/bash
# The checkout can move or be copied with .build intact. Swift module caches
# embed absolute paths, so give each workspace its own package and module cache.
XDVPN_CACHE_ID="$(printf '%s' "$PWD" | /usr/bin/shasum -a 256 | /usr/bin/cut -c1-16)"
XDVPN_BUILD_ROOT="$PWD/.build/workspace-$XDVPN_CACHE_ID"
export CLANG_MODULE_CACHE_PATH="$XDVPN_BUILD_ROOT/clang-module-cache"
