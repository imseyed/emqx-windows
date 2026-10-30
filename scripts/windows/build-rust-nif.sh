#!/usr/bin/env bash

## rebar3 compile hook wrapper for the Rust NIF dependencies on Windows.
##
## Two things need fixing up for those deps, and neither can be expressed in
## their own rebar.config, which is upstream:
##
##   1. Their hook is `./do_compile.sh`. rebar3 runs hooks through cmd.exe on
##      Windows, and cmd cannot execute a shell script, so the hook has to be
##      routed through bash. scripts/windows/patch-native-deps.sh rewrites the
##      hook to call this script instead.
##
##   2. do_compile.sh always names the artifact `.so`, because that is what
##      OTP wants on Linux and macOS alike. On Windows erlang:load_nif/2
##      appends `.dll`, so the built library is copied to that name as well.
##
## Run with the dependency directory as the working directory, which is what
## rebar3 does for a hook.

set -euo pipefail

if [ ! -x ./do_compile.sh ] && [ ! -f ./do_compile.sh ]; then
    echo "ERROR: no do_compile.sh in $(pwd)" >&2
    exit 1
fi

bash ./do_compile.sh

shopt -s nullglob
copied=0
for so in priv/*.so; do
    dll="${so%.so}.dll"
    cp -f "$so" "$dll"
    echo "windows: $so -> $dll"
    copied=1
done

if [ "$copied" = 0 ]; then
    echo "ERROR: do_compile.sh produced no priv/*.so in $(pwd)" >&2
    exit 1
fi
