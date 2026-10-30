#!/usr/bin/env bash

## Build the lz4b NIF on Windows.
##
## lz4b's compile hook is guarded to "(linux|darwin|solaris)" plus a freebsd
## entry, so nothing is built here, and its NIF is not optional: lz4b_nif:init/0
## raises {failed_to_load_nif, ...} from on_load, which in an embedded release
## aborts the kernel application and the node never boots.
##
## c_src/Makefile is erlang.mk-shaped (gcc flags, -shared, a .so target) and
## builds lz4 with lz4's own makefile. lz4 is portable C, so this hands both it
## and the NIF to cl.exe instead.

set -euo pipefail

# Keep MSYS2 from rewriting cl.exe's arguments as paths.
export MSYS2_ARG_CONV_EXCL='*'

## Same version c_src/Makefile pins.
LZ4_VSN="${LZ4_VSN:-1.10.0}"
LZ4_REPO="${LZ4_REPO:-https://github.com/lz4/lz4.git}"

BUILD_DIR="c_build_win"
LZ4_DIR="${BUILD_DIR}/lz4"
SHIM_DIR="${BUILD_DIR}/shim"
OBJ_DIR="${BUILD_DIR}/obj"
OUT_DLL="priv/lz4b_nif.dll"

if [ ! -f c_src/lz4b.c ]; then
    echo "ERROR: run this from the lz4b dependency directory (no c_src/lz4b.c here: $(pwd))" >&2
    exit 1
fi

## EMQX_WIN_NIF_IDEMPOTENT: the dependency is pinned, so once the NIF is built
## there is nothing to rebuild. Both the pre-build in patch-native-deps.sh and
## the rebar3 hook call this script, and a forced rebuild is FORCE=1.
if [ -f "priv/lz4b_nif.dll" ] && [ "${FORCE:-0}" != "1" ]; then
    echo "lz4b: priv/lz4b_nif.dll is already built (FORCE=1 to rebuild)"
    exit 0
fi

for tool in cl.exe link.exe git; do
    command -v "$tool" >/dev/null || {
        echo "ERROR: $tool not on PATH; source scripts/windows/build-env.sh first" >&2
        exit 1
    }
done

win() { cygpath -w -a "$1"; }

ERL_ROOT="$(erl -noshell -eval 'io:format("~s",[code:root_dir()]), halt().')"
ERTS_INCLUDE="$(cygpath -w "${ERL_ROOT}/usr/include")"

## 1. lz4 sources
if [ ! -f "${LZ4_DIR}/lib/lz4.c" ]; then
    mkdir -p "${BUILD_DIR}"
    rm -rf "${LZ4_DIR}"
    git clone --depth 1 --branch "v${LZ4_VSN}" "${LZ4_REPO}" "${LZ4_DIR}"
fi

## 2. c_src/lz4b.h includes <strings.h>, which MSVC does not have. Nothing
##    from it is actually used (no bzero/strcasecmp/index in lz4b.c), so an
##    empty header on the include path is enough to satisfy the include.
mkdir -p "${SHIM_DIR}"
cat > "${SHIM_DIR}/strings.h" <<'HEADER'
/* Empty stand-in for the POSIX <strings.h>, which MSVC does not ship.
   lz4b.h includes it but uses nothing from it.
   Written by scripts/windows/build-lz4b.sh. */
#ifndef EMQX_WIN_STRINGS_H_
#define EMQX_WIN_STRINGS_H_
#endif
HEADER

## 3. compile
mkdir -p "${OBJ_DIR}" priv

lz4_inc="$(win "${LZ4_DIR}/lib")"
shim_inc="$(win "${SHIM_DIR}")"
csrc_inc="$(win c_src)"

lz4_srcs=()
for c in lz4.c lz4hc.c lz4frame.c xxhash.c; do
    lz4_srcs+=("$(win "${LZ4_DIR}/lib/${c}")")
done
nif_src="$(win c_src/lz4b.c)"

echo "lz4b: compiling lz4 ${LZ4_VSN} and the NIF with cl.exe"
# Paths are resolved above: cl.exe drops its .obj files in the working
# directory, so the compile runs from the obj dir.
( cd "${OBJ_DIR}" && cl.exe /nologo /c /O2 /MD -I"${lz4_inc}" "${lz4_srcs[@]}" )

( cd "${OBJ_DIR}" && cl.exe /nologo /c /O2 /MD \
    -I"${ERTS_INCLUDE}" -I"${lz4_inc}" -I"${csrc_inc}" -I"${shim_inc}" \
    "${nif_src}" )

link.exe /nologo /DLL "$(win "${OBJ_DIR}")\*.obj" /OUT:"$(win "${OUT_DLL}")"

echo "lz4b: built ${OUT_DLL}"
