#!/usr/bin/env bash

## Sourced by the Windows build to put the toolchain on PATH in the right
## order.  Source it by hand too when debugging a build in an interactive
## MSYS2 shell:
##
##   source scripts/windows/build-env.sh && make emqx-enterprise
##
## Order matters.  MSVC's bin dir has to come before /usr/bin, otherwise the
## GNU `link.exe` from MSYS2 shadows the Microsoft linker and the port
## compiler fails with "link: extra operand".  /usr/bin still has to come
## before the Windows directories, so that the POSIX tools win over the
## `find.exe` and `sort.exe` in system32.
##
## Install Erlang and Elixir somewhere without spaces in the path. erlang.mk,
## which several deps build with, passes paths to cygpath unquoted, and erlc
## mis-quotes a spaced path to erl.exe; a "Program Files" install breaks both.
##
## This expects `vcvarsall.bat x64` to have run in the cmd.exe that launched
## the MSYS2 shell: that is what sets INCLUDE, LIB, and the MSVC bin dirs we
## fish back out of PATH below.
##
## Everything here is a bash builtin.  Nothing in /usr/bin can be called until
## PATH has been rebuilt, which is the whole point of the file.

# Where the toolchain was installed.  Override any of these in the
# environment if your layout differs.
# EMQX does not run on a stock OTP: it needs the emqx/otp fork (see
# Windows.md, "Erlang/OTP - a patched OTP is mandatory").  A stock release
# aborts at boot with unsupported_otp_version.  Prefer the patched install
# when it is present so a leftover stock OTP on PATH cannot be picked up by
# accident.
if [ -z "${ERL_HOME:-}" ] && [ -x /c/erlang/28.4.1-7-emqx/bin/erl.exe ]; then
    ERL_HOME=/c/erlang/28.4.1-7-emqx
fi
ERL_HOME="${ERL_HOME:-/c/erlang/28.4.1-7-emqx}"
ELIXIR_HOME="${ELIXIR_HOME:-/c/elixir/1.19.1}"
# greptimedb_rs is a Rust NIF, and its build script runs protoc.
PROTOC_HOME="${PROTOC_HOME:-/c/protoc}"
# aws-lc-sys, pulled in by that NIF's TLS stack, assembles with nasm.
NASM_HOME="${NASM_HOME:-/c/nasm/nasm-2.16.03}"
# rocksdb configures with the Visual Studio generator, which MSYS2's cmake
# cannot drive, so a native Windows cmake has to come first on PATH. 3.x, not
# 4.x: c_src/CMakeLists.txt and lz4 still declare cmake_minimum_required 3.5.
CMAKE_HOME="${CMAKE_HOME:-/c/cmake/cmake-3.31.9-windows-x86_64}"
## OTP used to report "win32" from erlang:system_info(system_architecture);
## OTP 28 reports "x86_64-pc-windows". Every `port_env` / hook in the
## ecosystem - the pc plugin's own MSVC defaults included - selects the
## Windows branch with a "win32" regex against that string, so on OTP 28 those
## branches silently stop matching and the port compiler falls back to its gcc
## defaults ("'c++' is not recognized"). REBAR_TARGET_ARCH overrides the
## string pc builds, which puts "win32" back in it. The x86_64 prefix is there
## so the wordsize is read off the name instead of probed with a compiler.
export REBAR_TARGET_ARCH="${REBAR_TARGET_ARCH:-x86_64-win32}"

export CARGO_HOME="${CARGO_HOME:-/c/rust/.cargo}"
export RUSTUP_HOME="${RUSTUP_HOME:-/c/rust/.rustup}"

## The MSVC and Windows SDK bin dirs, in the order vcvarsall.bat put them.
emqx_msvc_bin_dirs() {
    local dir out='' IFS=':'
    for dir in $PATH; do
        case "$dir" in
            */MSVC/*|*/Windows\ Kits/*)
                if [ -n "$out" ]; then
                    out="$out:$dir"
                else
                    out="$dir"
                fi
                ;;
        esac
    done
    printf '%s' "$out"
}

emqx_build_path() {
    local msvc
    msvc="$(emqx_msvc_bin_dirs)"
    if [ -n "$msvc" ]; then
        printf '%s:' "$msvc"
    fi
    # CMAKE_HOME before /usr/bin: MSYS2 ships a cmake of its own that would
    # otherwise win, and it cannot drive the Visual Studio generator.
    printf '%s/bin:/usr/bin:%s/bin:%s/bin:%s/bin:%s/bin:%s:/c/Windows/System32:/c/Windows' \
           "$CMAKE_HOME" "$ERL_HOME" "$ELIXIR_HOME" "$CARGO_HOME" "$PROTOC_HOME" "$NASM_HOME"
}

export PATH="$(emqx_build_path)"

## rocksdb 9.10 only wires its compression libraries up through
## thirdparty.inc when it is built with MSVC: the find_package(Snappy) path in
## its CMakeLists sits in the non-MSVC branch, so -Dsnappy_ROOT_DIR (which
## erlang-rocksdb passes) is simply ignored and the build fails on a missing
## snappy.h. thirdparty.inc instead reads these from the environment.
##
## The paths point at the bundled snappy and lz4 that erlang-rocksdb builds as
## ExternalProjects under deps/rocksdb/_build/cmake. Only Release is built
## here, so the debug entries point at the same libraries; they are there
## because thirdparty.inc always emits a debug/optimized pair.
##
## cygpath -m, not the MSYS2 form: cmake.exe is a native Windows program and
## MSYS2 only translates a short list of known variables, not these.
emqx_export_rocksdb_thirdparty() {
    local root rocks
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    rocks="$(cygpath -m "${root}/deps/rocksdb/_build/cmake")"

    export SNAPPY_INCLUDE="${rocks}/snappy/include"
    export SNAPPY_LIB_RELEASE="${rocks}/snappy/lib/snappy.lib"
    export SNAPPY_LIB_DEBUG="${SNAPPY_LIB_RELEASE}"

    export LZ4_INCLUDE="${rocks}/lz4/include"
    export LZ4_LIB_RELEASE="${rocks}/lz4/lib/lz4.lib"
    export LZ4_LIB_DEBUG="${LZ4_LIB_RELEASE}"
}

emqx_export_rocksdb_thirdparty

emqx_require() {
    if ! command -v "$1" >/dev/null; then
        echo "ERROR: $1 not found on PATH. $2" >&2
        return 1
    fi
}

emqx_check_build_env() {
    local rc=0
    emqx_require erl "Set ERL_HOME (currently '$ERL_HOME')." || rc=1
    emqx_require elixir "Set ELIXIR_HOME (currently '$ELIXIR_HOME')." || rc=1
    emqx_require make "Install it with: pacman -S make" || rc=1
    emqx_require cmake "Set CMAKE_HOME (currently '$CMAKE_HOME')." || rc=1
    emqx_require cl "Run vcvarsall.bat x64 before entering the MSYS2 shell." || rc=1
    emqx_require cargo "Set CARGO_HOME (currently '$CARGO_HOME')." || rc=1
    emqx_require protoc "Set PROTOC_HOME (currently '$PROTOC_HOME')." || rc=1
    emqx_require nasm "Set NASM_HOME (currently '$NASM_HOME')." || rc=1
    return $rc
}

emqx_check_build_env || return 1 2>/dev/null || exit 1
