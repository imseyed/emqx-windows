#!/usr/bin/env bash

## Make the native dependencies that have no Windows recipe buildable here.
##
## Three deps need their rebar.config adjusted, and none of them can be fixed
## upstream from this repo:
##
##   datalayers, greptimedb_rs  Rust NIFs whose hook is {compile,
##       "./do_compile.sh"} with no OS filter. rebar3 runs hooks through
##       cmd.exe on Windows, which cannot execute a shell script, so the build
##       dies with "'.' is not recognized as an internal or external command".
##       They are repointed at build-rust-nif.sh, which runs do_compile.sh
##       through bash and gives the artifact the .dll name load_nif/2 wants.
##
##   ezstd, crc32cer, lz4b  Their hooks are guarded to the Unix platforms, so
##       nothing is built here. ezstd is the one dep that declares
##       {artifacts, _}, which turns its missing NIF into a build error;
##       crc32cer and lz4b instead raise from on_load, and in an embedded
##       release that aborts the kernel application, so the node will not
##       boot without them. Each gets a win32 hook calling the matching
##       build-*.sh.
##
## Run after `make mix-deps-get` and before compiling. Idempotent, so it is
## safe to run on every build.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEPS_DIR="${REPO_ROOT}/deps"

require_script() {
    if [ ! -f "${REPO_ROOT}/scripts/windows/$1" ]; then
        echo "ERROR: scripts/windows/$1 is missing" >&2
        exit 1
    fi
}

require_script build-rust-nif.sh
require_script build-ezstd.sh
require_script build-crc32cer.sh
require_script build-lz4b.sh
require_script build-rocksdb.sh

RUST_WRAPPER="${REPO_ROOT}/scripts/windows/build-rust-nif.sh"

## --- the two Rust NIFs -----------------------------------------------------
for dep in datalayers greptimedb_rs; do
    config="${DEPS_DIR}/${dep}/rebar.config"
    if [ ! -f "$config" ]; then
        echo "skip: ${dep} is not checked out"
        continue
    fi
    if grep -q 'build-rust-nif.sh' "$config"; then
        echo "skip: ${dep} is already patched"
        continue
    fi
    if ! grep -q '"\./do_compile\.sh"' "$config"; then
        echo "skip: ${dep} does not use the ./do_compile.sh hook any more"
        continue
    fi
    sed -i "s|\"\./do_compile\.sh\"|\"bash '${RUST_WRAPPER}'\"|" "$config"
    echo "patched: ${config}"
done

## --- the three Unix-guarded C NIFs -----------------------------------------
## Each gets a {"win32|windows", compile, ...} entry appended to its existing
## pre_hooks list.
##
## Both spellings are needed because the two layers that filter on "arch" do
## not agree on the string. rebar3 core builds it from
## erlang:system_info(system_architecture) alone, which is "x86_64-pc-windows"
## on OTP 28, and ignores REBAR_TARGET_ARCH - so a "win32"-only hook never
## fires. The pc plugin does honour REBAR_TARGET_ARCH, which build-env.sh sets
## to x86_64-win32 so that pc and the deps port_env blocks pick their MSVC
## branches. An alternation matches whichever string is in play.
add_win32_hook() {
    local dep="$1" script="$2"
    local config="${DEPS_DIR}/${dep}/rebar.config"

    if [ ! -f "$config" ]; then
        echo "skip: ${dep} is not checked out"
        return
    fi
    if grep -q "${script}" "$config"; then
        echo "skip: ${dep} is already patched"
        return
    fi

    WRAPPER="${REPO_ROOT}/scripts/windows/${script}" DEP="$dep" perl -0777 -i -pe '
        my $w = $ENV{WRAPPER};
        my $dep = $ENV{DEP};
        my $hook = qq({"win32|windows", compile, "bash \x27$w\x27"});
        # Append to the first {pre_hooks, [ ... ]} list, whatever is in it.
        unless (s/\{pre_hooks,\s*\[/{pre_hooks,\n  [$hook,\n/s) {
            die "$dep: no pre_hooks list to extend\n";
        }
    ' "$config"
    echo "patched: ${config}"
}

## rocksdb is different: it already ships win32 hooks that configure with
## CMake and build with MSBuild, so nothing has to be written for it. They
## just never fire, because rebar3 matches the hook arch against
## "x86_64-pc-windows" and the hooks say "win32". Widening the pattern is the
## whole fix.
widen_win32_pattern() {
    local dep="$1"
    local config="${DEPS_DIR}/${dep}/rebar.config"

    if [ ! -f "$config" ]; then
        echo "skip: ${dep} is not checked out"
        return
    fi
    if grep -q '"win32|windows"' "$config"; then
        echo "skip: ${dep} is already patched"
        return
    fi
    if ! grep -q '{"win32"' "$config"; then
        echo "skip: ${dep} has no win32 hooks to widen"
        return
    fi
    sed -i 's|{"win32"|{"win32\|windows"|g' "$config"
    echo "patched: ${config}"
}

widen_win32_pattern rocksdb

## Snappy decides at *configure* time whether to emit BMI2 instructions, and
## the probe it uses is `check_cxx_source_compiles` on `_bzhi_u32`. MSVC needs
## no -mbmi2 switch for that intrinsic, so the probe always succeeds and
## SNAPPY_HAVE_BMI2 is set to 1 regardless of what the target CPU supports.
##
## BMI2 arrived with Haswell (2013). On anything older - a Westmere Xeon, for
## instance - the resulting liberocksdb.dll dies with an illegal instruction
## (exit 132, Windows 0xC000001D) the moment a block is compressed or an
## existing SST file is read. Nothing is logged, no crash dump is written and
## no Windows error event is raised, so it surfaces as a node that boots fine
## on an empty data dir and then kills the VM on the next start, once there is
## an SST to read back.
##
## RocksDB itself is already configured with PORTABLE=ON here; this makes the
## bundled Snappy agree. Set EMQX_SNAPPY_BMI2=1 to opt back in when the build
## host and every target are known to be Haswell or newer.
pin_snappy_bmi2() {
    local cmake_file="${DEPS_DIR}/rocksdb/c_src/CMake/build-snappy.cmake"
    local want="${EMQX_SNAPPY_BMI2:-0}"

    if [ ! -f "$cmake_file" ]; then
        echo "skip: rocksdb is not checked out, no build-snappy.cmake"
        return
    fi
    if grep -q 'SNAPPY_HAVE_BMI2' "$cmake_file"; then
        echo "skip: build-snappy.cmake already pins SNAPPY_HAVE_BMI2"
        return
    fi
    sed -i \
        "s|-DCMAKE_POSITION_INDEPENDENT_CODE=ON|-DCMAKE_POSITION_INDEPENDENT_CODE=ON\n        -DSNAPPY_HAVE_BMI2=${want}|" \
        "$cmake_file"
    echo "patched: ${cmake_file} (SNAPPY_HAVE_BMI2=${want})"
}

pin_snappy_bmi2

add_win32_hook ezstd    build-ezstd.sh
add_win32_hook crc32cer build-crc32cer.sh
add_win32_hook lz4b     build-lz4b.sh

echo "note: these edits live in deps/; 'mix deps.clean' undoes them, so re-run this after one."

## --- pre-build the C NIFs --------------------------------------------------
## The hooks above are not enough on their own. Mix lays out a dependency's
## build path - including the symlink to its priv/ - before it hands the
## dependency to rebar3, so a NIF that only appears during compile never
## reaches _build/<profile>/lib/<dep>/priv. ezstd makes that fatal: rebar3
## looks for its declared artifact in the build path and fails the build.
##
## Building them here, before anything compiles, means priv/ already exists
## when Mix sets the build path up. The scripts no-op when the library is
## already there, so the hooks stay useful for a forced recompile without
## paying for the work twice.
build_nif_now() {
    local dep="$1" script="$2"
    local dir="${DEPS_DIR}/${dep}"

    if [ ! -d "$dir" ]; then
        echo "skip: ${dep} is not checked out, nothing to pre-build"
        return
    fi
    ( cd "$dir" && bash "${REPO_ROOT}/scripts/windows/${script}" )
}

build_nif_now rocksdb  build-rocksdb.sh
build_nif_now ezstd    build-ezstd.sh
build_nif_now crc32cer build-crc32cer.sh
build_nif_now lz4b     build-lz4b.sh
