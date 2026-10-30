#!/usr/bin/env bash

## Build the rocksdb NIF on Windows.
##
## erlang-rocksdb already ships Windows hooks that configure with CMake's
## Visual Studio generator and build with MSBuild, and
## scripts/windows/patch-native-deps.sh widens their arch pattern so they
## fire. This script exists for two reasons on top of that:
##
##   1. Mix lays out a dependency's build path - including the symlink to its
##      priv/ - before handing the dependency to rebar3, so a NIF that only
##      appears during compile never reaches _build/<profile>/lib/rocksdb/priv
##      and the node dies on rocksdb's on_load. Building here, from
##      patch-native-deps.sh, means priv/ exists first.
##
##   2. Build order. snappy and lz4 are ExternalProjects, and only the
##      erocksdb target declares a dependency on them - the rocksdb
##      ExternalProject does not. On a clean tree MSBuild is free to compile
##      rocksdb before snappy has installed its headers, which fails on a
##      missing snappy.h. Building those two targets first makes the order
##      explicit.
##
## The snappy and lz4 paths themselves are passed through the environment by
## scripts/windows/build-env.sh; see the note there about thirdparty.inc.
##
## Run with the rocksdb dependency directory as the working directory.

set -euo pipefail

export MSYS2_ARG_CONV_EXCL='*'

OUT_DLL="priv/liberocksdb.dll"
BUILD_DIR="_build/cmake"

if [ ! -f c_src/CMakeLists.txt ]; then
    echo "ERROR: run this from the rocksdb dependency directory (no c_src/CMakeLists.txt here: $(pwd))" >&2
    exit 1
fi

## EMQX_WIN_NIF_IDEMPOTENT: the dependency is pinned, so once the NIF is built
## there is nothing to rebuild. This is the slowest native build in the tree
## by a wide margin, so skipping matters. FORCE=1 rebuilds.
if [ -f "$OUT_DLL" ] && [ "${FORCE:-0}" != "1" ]; then
    echo "rocksdb: ${OUT_DLL} is already built (FORCE=1 to rebuild)"
    exit 0
fi

for tool in cmake cl.exe; do
    command -v "$tool" >/dev/null || {
        echo "ERROR: $tool not on PATH; source scripts/windows/build-env.sh first" >&2
        exit 1
    }
done

if [ -z "${SNAPPY_INCLUDE:-}" ]; then
    echo "ERROR: SNAPPY_INCLUDE is unset; source scripts/windows/build-env.sh first" >&2
    exit 1
fi

mkdir -p "${BUILD_DIR}"

echo "rocksdb: configuring with the Visual Studio generator"
( cd "${BUILD_DIR}" && cmake -DCMAKE_GENERATOR_PLATFORM=x64 \
    -DWITH_BUNDLE_LZ4=ON -DWITH_BUNDLE_SNAPPY=ON ../../c_src )

for target in snappy lz4; do
    echo "rocksdb: building ${target} first (rocksdb does not depend on it)"
    cmake --build "${BUILD_DIR}" --config Release --target "${target}" --parallel
done

echo "rocksdb: building the NIF (this is the long one)"
cmake --build "${BUILD_DIR}" --config Release --parallel

if [ ! -f "$OUT_DLL" ]; then
    echo "ERROR: the build reported success but ${OUT_DLL} is missing" >&2
    exit 1
fi

echo "rocksdb: built ${OUT_DLL}"
