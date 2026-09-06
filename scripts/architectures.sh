#!/bin/bash
# Shared by application, engine and source-only rebuilds. Bash 3.2 compatible.
xdvpn_architectures() {
    case "$1" in
        arm64|x86_64) echo "$1" ;;
        *) echo "Invalid architecture: [$1]. Set ARCHS to arm64 or x86_64; build separate packages." >&2; return 1 ;;
    esac
}

xdvpn_verify_architectures() {
    local binary="$1" expected="$2" actual
    actual="$(xdvpn_architectures "$(/usr/bin/lipo -archs "$binary")")" || return 1
    if [ "$actual" != "$expected" ]; then
        echo "Architecture mismatch: $binary: expected [$expected], got [$actual]" >&2
        return 1
    fi
    /usr/bin/vtool -arch "$expected" -show-build "$binary" | awk '
        $1 == "minos" { found=1; if ($2 != "14.0") bad=1 }
        END { if (!found || bad) { print "Expected macOS 14.0 deployment target"; exit 1 } }
    '
}

xdvpn_verify_engine() {
    local binary="$1" expected="$2"
    xdvpn_verify_architectures "$binary" "$expected" || return 1
    /usr/bin/otool -arch "$expected" -L "$binary" | awk 'NR > 1 && $1 !~ /^\/usr\/lib\// && $1 !~ /^\/System\/Library\// { print "External library: " $1; bad=1 } END { exit bad }' || return 1
    /usr/bin/nm -arch "$expected" -u "$binary" | awk '$NF == "_strchrnul" { print "Unsupported macOS 14 import: " $NF; bad=1 } END { exit bad }'
}
