#!/usr/bin/env bash

## Build the ezstd NIF on Windows.
##
## ezstd ships a POSIX-only recipe: build_deps.sh builds zstd with zstd's own
## GNU makefile, and c_src/Makefile links the NIF with gcc-style flags. Its
## compile hook is guarded to "(linux|darwin)", so on Windows nothing is built
## at all - and because ezstd is the one dependency that declares
## {artifacts, ["priv/ezstd_nif.so"]}, rebar3 turns that into a hard error
## rather than a missing NIF.
##
## zstd itself is portable C, so this skips zstd's makefile and CMake both and
## just hands the library sources to cl.exe, then compiles and links the two
## NIF translation units against it. No import library is needed for the
## enif_* symbols: on Windows erl_nif.h resolves them through a function table
## that ERL_NIF_INIT fills in.
##
## Run with the ezstd dependency directory as the working directory, which is
## what rebar3 does for a hook.

set -euo pipefail

# Keep MSYS2 from rewriting cl.exe's arguments as paths.
export MSYS2_ARG_CONV_EXCL='*'

ZSTD_REPO="${ZSTD_REPO:-https://github.com/facebook/zstd.git}"
## Pinned to the same commit build_deps.sh uses (tag v1.5.2), so the Windows
## package ships the same zstd as every other platform.
ZSTD_COMMIT="${ZSTD_COMMIT:-e47e674cd09583ff0503f0f6defd6d23d8b718d3}"

DEPS_LOCATION="_build/deps"
ZSTD_DIR="${DEPS_LOCATION}/zstd"
OUT_DLL="priv/ezstd_nif.dll"
## rebar3 checks for the .so by name; a copy next to the .dll satisfies it
## without having to patch the dependency's artifacts entry.
OUT_SO="priv/ezstd_nif.so"

if [ ! -d c_src ]; then
    echo "ERROR: run this from the ezstd dependency directory (no c_src here: $(pwd))" >&2
    exit 1
fi

## EMQX_WIN_NIF_IDEMPOTENT: the dependency is pinned, so once the NIF is built
## there is nothing to rebuild. Both the pre-build in patch-native-deps.sh and
## the rebar3 hook call this script, and a forced rebuild is FORCE=1.
if [ -f "priv/ezstd_nif.dll" ] && [ "${FORCE:-0}" != "1" ]; then
    echo "ezstd: priv/ezstd_nif.dll is already built (FORCE=1 to rebuild)"
    exit 0
fi

for tool in cl.exe lib.exe link.exe git; do
    command -v "$tool" >/dev/null || {
        echo "ERROR: $tool not on PATH; source scripts/windows/build-env.sh first" >&2
        exit 1
    }
done

ERL_ROOT="$(erl -noshell -eval 'io:format("~s",[code:root_dir()]), halt().')"
ERTS_INCLUDE="$(cygpath -w "${ERL_ROOT}/usr/include")"

win() { cygpath -w -a "$1"; }

## 1. zstd sources
if [ ! -d "${ZSTD_DIR}/lib" ]; then
    mkdir -p "${DEPS_LOCATION}"
    git clone --filter=blob:none --no-checkout "${ZSTD_REPO}" "${ZSTD_DIR}"
fi
if [ ! -f "${ZSTD_DIR}/lib/zstd.h" ]; then
    git -C "${ZSTD_DIR}" checkout --detach "${ZSTD_COMMIT}"
fi

## 2. zstd as a static library
ZSTD_LIB="${ZSTD_DIR}/lib"
ZSTD_OBJ_DIR="${ZSTD_DIR}/_msvc_obj"
ZSTD_STATIC="${ZSTD_DIR}/zstd_static.lib"

if [ ! -f "${ZSTD_STATIC}" ]; then
    mkdir -p "${ZSTD_OBJ_DIR}"
    zstd_srcs=()
    for d in common compress decompress; do
        for c in "${ZSTD_LIB}/${d}"/*.c; do
            zstd_srcs+=("$(win "$c")")
        done
    done
    echo "ezstd: compiling ${#zstd_srcs[@]} zstd sources with cl.exe"
    # Resolve every path before the subshell: cl.exe writes its .obj files
    # into the working directory, so the compile has to run from the obj dir,
    # and a relative path would be resolved against it.
    zstd_inc="$(win "${ZSTD_LIB}")"
    zstd_inc_common="$(win "${ZSTD_LIB}/common")"
    # ZSTD_DISABLE_ASM: the x86-64 BMI2 path is a .S file that only GCC/Clang
    # can assemble. MSVC is not __GNUC__ so zstd excludes it anyway; being
    # explicit keeps that from depending on zstd's own feature detection.
    ( cd "${ZSTD_OBJ_DIR}" && cl.exe /nologo /c /O2 /MD /DNDEBUG /DZSTD_DISABLE_ASM=1 \
        /DXXH_NAMESPACE=ZSTD_ \
        -I"${zstd_inc}" -I"${zstd_inc_common}" \
        "${zstd_srcs[@]}" )
    lib.exe /nologo /OUT:"$(win "${ZSTD_STATIC}")" "$(win "${ZSTD_OBJ_DIR}")\*.obj"
fi

## 3. the NIF itself
NIF_OBJ_DIR="c_src/_msvc_obj"
mkdir -p "${NIF_OBJ_DIR}" priv
nif_srcs=()
for c in c_src/*.cc; do
    nif_srcs+=("$(win "$c")")
done
echo "ezstd: compiling ${#nif_srcs[@]} NIF sources with cl.exe"
zstd_inc="$(win "${ZSTD_LIB}")"
csrc_inc="$(win "c_src")"
( cd "${NIF_OBJ_DIR}" && cl.exe /nologo /c /O2 /MD /EHsc /DNDEBUG /std:c++14 \
    -I"${ERTS_INCLUDE}" -I"${zstd_inc}" -I"${csrc_inc}" \
    "${nif_srcs[@]}" )

link.exe /nologo /DLL \
    "$(win "${NIF_OBJ_DIR}")\*.obj" \
    "$(win "${ZSTD_STATIC}")" \
    /OUT:"$(win "${OUT_DLL}")"

cp -f "${OUT_DLL}" "${OUT_SO}"
echo "ezstd: built ${OUT_DLL} (and ${OUT_SO} for rebar3's artifacts check)"
