# Building and Running EMQX on Windows

> Persian / فارسی: see [Windows.fa.md](./Windows.fa.md)

Windows packages were dropped from EMQX CI after 4.3, and the batch launchers
were deleted from the tree in late 2025. This document describes the Windows
build as it is wired up again on the 6.3 line.

Written and verified against:

| | |
| --- | --- |
| OS | Windows Server 2025 (Windows 11 / Server 2022 work the same way) |
| EMQX | 6.3.2 (`patch-6.3.2`) |
| Erlang/OTP | `emqx/otp` **OTP-28.4.1-7**, built from source (erts 16.3) |
| Elixir | 1.19.1 (built for OTP 28) |
| Toolchain | MSVC 17.14 (VS 2022 Build Tools), MSYS2, CMake 3.31.9, NASM 2.16.03, Rust 1.88.0, protoc 36.2 |
| OpenSSL | 3.6.5, static, built from source |

---

## Table of contents

1. [Before you start](#1-before-you-start)
2. [What a Windows build includes and excludes](#2-what-a-windows-build-includes-and-excludes)
3. [Prerequisites](#3-prerequisites)
   - [3.1 Visual Studio Build Tools](#31-visual-studio-build-tools)
   - [3.2 MSYS2](#32-msys2)
   - [3.3 CMake, NASM, protoc, Rust](#33-cmake-nasm-protoc-rust)
   - [3.4 OpenSSL (static)](#34-openssl-static)
   - [3.5 Erlang/OTP — a patched OTP is mandatory](#35-erlangotp--a-patched-otp-is-mandatory)
   - [3.6 Elixir](#36-elixir)
4. [Building EMQX](#4-building-emqx)
5. [Worked example — exact commands](#5-worked-example--exact-commands)
6. [Running the broker](#6-running-the-broker)
7. [Troubleshooting](#7-troubleshooting)
8. [Reference: what each script does](#8-reference-what-each-script-does)

---

## 1. Before you start

### Install everything under paths without spaces

Use `C:\erlang\...`, `C:\elixir\...`, not `C:\Program Files\...`. Several
dependencies (`mysql`, `ranch`) build with `erlang.mk`, which passes `ERLC`
unquoted through `cygpath`. A space in the path fails with:

```
erlc: Error executing '"\"C:\Program Files\erl-28.4.1\...'
```

### Check your CPU before trusting the binaries

The build produces native code. If your CPU is older than Haswell (2013) you
**must** keep the portable Snappy setting described in
[§7](#7-troubleshooting) — it is the default in this tree, but it matters when
you change build flags.

```bash
grep -m1 flags /proc/cpuinfo | tr ' ' '\n' | grep -E '^(avx|avx2|bmi2)$'
```

No output means no AVX/BMI2, and any library built with those instructions
will die with an illegal instruction at runtime.

### Disk space and time

Budget **~25 GB free** and several hours. The patched OTP build alone takes
roughly an hour; RocksDB another 30–50 minutes. Both are one-off.

---

## 2. What a Windows build includes and excludes

### Excluded

`build` switches these off when `SYSTEM=windows`:

| Dependency | Switch | What you lose |
| --- | --- | --- |
| quicer (msquic) | `BUILD_WITHOUT_QUIC=on` | MQTT over QUIC listeners. |
| jq | `BUILD_WITHOUT_JQ=on` | The `jq()` rule-engine function. jq runs its filters in an external port program built by an autotools script with no Windows path. `jq_port_sup` starts one child per scheduler, so the application would fail to start and take the node down with it — it is left out of the release rather than shipped broken. |
| bcrypt | `BUILD_WITHOUT_BCRYPT=on` | `bcrypt` as a `password_hash_algorithm`. Its NIF needs `sys/queue.h`, `err.h`, `unistd.h` and pthreads; MSVC has none of them and mingw-w64 ships neither `sys/queue.h` nor `err.h`. `emqx_machine_boot` already lists `bcrypt` in `?OPTIONAL_APPS`, so the node boots fine without it — use `pbkdf2` or `sha256`. |

### Included, but needing special handling

These have native code with no working Windows path upstream.
`scripts/windows/` builds them:

| Dependency | How |
| --- | --- |
| **rocksdb** | `build-rocksdb.sh` — CMake + MSVC, with Snappy and LZ4 built as static libs. Durable sessions and the `builtin_local` durable storage backend work. |
| **ezstd** | `build-ezstd.sh` — compiles zstd 1.5.2 plus the NIF with `cl.exe`, emitting both `.dll` and `.so`. |
| **crc32cer** | `build-crc32cer.sh` — a mandatory `on_load` NIF; without it the node aborts. Writes its own `crc32c_config.h`. |
| **lz4b** | `build-lz4b.sh` — also a mandatory `on_load` NIF. Provides an empty `strings.h` shim. |
| **datalayers**, **greptimedb_rs** | `build-rust-nif.sh` — Rust NIFs whose upstream hook is `./do_compile.sh`. rebar3 runs hooks through `cmd.exe`, which cannot execute a shell script, and the script names its artifact `.so` where `erlang:load_nif/2` wants `.dll`. |

`sasl_auth` still guards its hooks to `(linux|darwin|solaris)`, so its
NIF is absent — only Kerberos/GSSAPI authentication is affected.

Everything else — Kafka, Postgres, MySQL and the other data integrations —
builds normally.

### Single-node by design

`bin\emqx.cmd` forces `node.db_backend` to `mnesia` rather than the default
`rlog`; the Windows build is intended for a single node.

---

## 3. Prerequisites

### 3.1 Visual Studio Build Tools

Several dependencies ship NIFs written in C/C++. rebar3's port compiler uses
`cl.exe` and `link.exe` on Windows — **MinGW is not a substitute**.

Download `vs_BuildTools.exe` from
<https://visualstudio.microsoft.com/downloads/> (Tools for Visual Studio →
Build Tools for Visual Studio 2022), then:

```bat
vs_BuildTools.exe --quiet --wait --norestart ^
  --add Microsoft.VisualStudio.Workload.VCTools ^
  --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 ^
  --add Microsoft.VisualStudio.Component.Windows11SDK.26100
```

The Windows SDK is not optional: it supplies `sql.h`, `sqlext.h` and
`odbc32.lib`, which OTP's `odbc` application needs (see
[§3.5](#35-erlangotp--a-patched-otp-is-mandatory)).

Verify:

```bat
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsall.bat" x64
cl
```

`cl` should print `Microsoft (R) C/C++ Optimizing Compiler Version 19.xx`.

### 3.2 MSYS2

The build scripts are `bash` and `escript`. Install MSYS2 from
<https://www.msys2.org/> (default location `C:\msys64`), then from an MSYS2
shell:

```bash
pacman -Syu                     # restart the shell if it asks you to
pacman -S --needed make cmake jq zip unzip p7zip curl git patch perl tar diffutils
```

Cygwin also works — `scripts/get-distro.sh` maps `CYGWIN*`, `MSYS*` and
`MINGW*` alike to `windows` — but MSYS2 is what this build was exercised with.

> **PATH order matters.** MSYS2 ships a GNU `link.exe` that shadows the
> Microsoft linker, and `C:\Windows\System32\find.exe` shadows POSIX `find`.
> `scripts/windows/build-env.sh` sorts this out: MSVC first, then `/usr/bin`,
> then the Windows directories. `build` additionally pins `FIND` and `TAR` to
> their `/usr/bin` paths.

### 3.3 CMake, NASM, protoc, Rust

| Tool | Why | Where it is expected |
| --- | --- | --- |
| **CMake 3.x** (native Windows build, **not** MSYS2's) | RocksDB configures with the Visual Studio generator, which MSYS2's CMake cannot drive. Must be 3.x, not 4.x: `c_src/CMakeLists.txt` and LZ4 still declare `cmake_minimum_required 3.5`. | `C:\cmake\cmake-3.31.9-windows-x86_64` |
| **NASM** | `aws-lc-sys`, pulled in by the Rust NIFs' TLS stack, assembles with NASM. | `C:\nasm\nasm-2.16.03` |
| **protoc** | `greptimedb_rs`'s build script runs it. | `C:\protoc` |
| **Rust** (via rustup) | `datalayers` and `greptimedb_rs` are Rust NIFs. | `CARGO_HOME=C:\rust\.cargo`, `RUSTUP_HOME=C:\rust\.rustup` |

Downloads:

```powershell
# CMake 3.31.9 (zip, no installer needed)
# https://github.com/Kitware/CMake/releases/download/v3.31.9/cmake-3.31.9-windows-x86_64.zip

# NASM 2.16.03
# https://www.nasm.us/pub/nasm/releasebuilds/2.16.03/win64/nasm-2.16.03-win64.zip

# protoc
# https://github.com/protocolbuffers/protobuf/releases  (protoc-*-win64.zip)

# Rust
# https://win.rustup.rs/x86_64  -> rustup-init.exe
$env:CARGO_HOME  = "C:\rust\.cargo"
$env:RUSTUP_HOME = "C:\rust\.rustup"
.\rustup-init.exe -y --default-toolchain stable --profile minimal
```

These paths are the defaults in `scripts/windows/build-env.sh`; override
`CMAKE_HOME`, `NASM_HOME`, `PROTOC_HOME`, `CARGO_HOME` or `RUSTUP_HOME` in the
environment if your layout differs.

### 3.4 OpenSSL (static)

OTP's `crypto` needs OpenSSL, and on Windows it expects the layout the
official OpenSSL installer produces, with **static** libraries:

```
C:\OpenSSL-Win64\include\openssl\...
C:\OpenSSL-Win64\lib\VC\x64\MD\libcrypto_static.lib
C:\OpenSSL-Win64\lib\VC\x64\MD\libssl_static.lib
```

You can use the prebuilt installer from <https://slproweb.com/products/Win32OpenSSL.html>
(choose the full, not "Light", package). To build from source instead:

```bash
# Needs a NATIVE Windows perl. Strawberry Perl, portable edition:
#   https://strawberryperl.com/   (portable .zip, extracted to C:\strawberry)
cd /c/src/openssl-3.6.5
perl Configure VC-WIN64A --prefix=C:/OpenSSL-Win64 no-shared
nmake && nmake install
```

Two traps:

* **`Configure` rejects the MSYS perl** with *"This perl implementation doesn't
  produce Windows like paths"*. Use Strawberry Perl.
* **Put Strawberry on PATH only between the MSVC directories and `/usr/bin`.**
  Ahead of MSVC, its bundled `link.exe` shadows the Microsoft linker and you
  get `link: extra operand '/dll'`.

If you build with `no-shared`, the libraries land as `libcrypto.lib` /
`libssl.lib`; OTP looks for the `_static` names, so copy them:

```bash
mkdir -p /c/OpenSSL-Win64/lib/VC/x64/MD
cp /c/OpenSSL-Win64/lib/libcrypto.lib /c/OpenSSL-Win64/lib/VC/x64/MD/libcrypto_static.lib
cp /c/OpenSSL-Win64/lib/libssl.lib    /c/OpenSSL-Win64/lib/VC/x64/MD/libssl_static.lib
```

You know it worked when OTP's `configure` prints:

```
checking for OpenSSL in C:/OpenSSL-Win64... static libcrypto_static library in C:/OpenSSL-Win64/lib/VC/x64/MD
```

### 3.5 Erlang/OTP — a patched OTP is mandatory

EMQX does **not** run on a stock Erlang/OTP release. It boots against
[`emqx/otp`](https://github.com/emqx/otp), a fork carrying changes EMQX needs
at runtime. On stock OTP the node aborts with `unsupported_otp_version`, and
that check is not cosmetic. The two things it really guards:

* **`{packet, mqtt}`** — MQTT frame-length parsing implemented in the
  emulator's **C code** (`erts/emulator/drivers/common/packet_parser.c`,
  `erts/emulator/beam/atom.names`, `erl_bif_port.c`). On stock OTP,
  `inet:setopts(S, [{packet, mqtt}])` returns `{error, einval}`. Because it
  lives in erts, it cannot be back-fitted by patching `.beam` files.
* **`mnesia_hook`** — a `mnesia` module used by `mria`; `undef` on stock OTP.
  Setting `EMQX_NODE__DB_BACKEND=mnesia` does *not* avoid it:
  `mria_config:backend()` hard-codes `rlog`.

`ssl` carries fork changes too.

You can verify on any OTP install:

```bash
erl -noshell -eval '
  {ok,L}=gen_tcp:listen(0,[]),
  io:format("packet,mqtt: ~p~n",[inet:setopts(L,[{packet,mqtt}])]),
  io:format("mnesia_hook: ~p~n",[code:ensure_loaded(mnesia_hook)]),
  halt().'
```

Patched OTP prints `ok` and `{module,mnesia_hook}`. Stock prints
`{error,einval}` and `{error,nofile}`.

No Windows binaries of `emqx/otp` are published, so it must be built once.

#### 3.5.1 Clone, and turn CRLF translation off first

```bash
git clone https://github.com/emqx/otp.git /c/src/emqx-otp
cd /c/src/emqx-otp
git checkout OTP-28.4.1-7
```

The OTP tree has no `.gitattributes`, so a global `core.autocrlf=true` checks
the whole thing out with CRLF and the build fails deep inside the emulator
with:

```
ops.tab(27): '' is not a recognized type
```

The `''` is a carriage return overwriting the opening quote of the real
message. Fix it **per repository**, leaving your global preference alone:

```bash
git config core.autocrlf false
git config core.eol lf
git rm --cached -r . >/dev/null && git reset --hard
```

#### 3.5.2 Apply the three OTP patches

All three are bugs in OTP's own Windows build, not EMQX-specific:

```bash
git apply /c/src/emqx/scripts/windows/otp-28.4.1-7-windows.patch
```

What each fixes:

1. **`erts/emulator/Makefile.in`** — the win32 branch sets `DEP_FLAGS` from
   `$(INCLUDES)` instead of `$(DEP_INCLUDES)` (the non-win32 branch a few lines
   down already uses the latter), so the `depend` step cannot find
   `prim_file_nif.h`. If `erts/emulator/win32/Makefile` has already been
   generated, fix it there too.
2. **`erts/etc/win32/msys_tools/vc/cc.sh`** — adds a `-std=c++*|-std=gnu++*`
   case before `-l*)`, translating to `/std:c++NN /Zc:__cplusplus`.
   Unrecognised options fall through to the *linker*, so `-std=c++17` never
   reaches `cl.exe` and `configure` reports *"JIT disabled due to lack of
   compiler with C++17 support"*. `/Zc:__cplusplus` matters because MSVC
   otherwise reports `__cplusplus` as `199711L`, which is exactly what the
   probe tests. Correct output is `checking for C++17 support... yes`, and
   `bin/win32/beam.jit.dll` gets built.
3. **`erts/etc/win32/msys_tools/vc/ld.sh`** — widens the library-path case from
   `-L/*|-L.*)` to `-L?*)`. The original patterns match only POSIX-absolute
   (`-L/...`) or relative (`-L....`) paths, but `configure` records
   `SSL_LIBDIR = C:/OpenSSL-Win64/lib/VC/x64/MD` — a Windows drive path. It
   matches neither, falls through to the catch-all and reaches `link.exe`
   verbatim as `/LC:/OpenSSL-Win64/...`, which it dismisses with
   `LINK : warning LNK4044: unrecognized option ...; ignored`. The real failure
   appears on the next line as
   `LINK : fatal error LNK1181: cannot open input file 'libcrypto_static.lib'`
   — which names a *library*, so it reads like a missing OpenSSL install. The
   LNK4044 warning above it is the actual diagnosis.

#### 3.5.3 Skip the wx applications

`otp_build boot -a` builds *every* application, and nothing here provides
wxWidgets, so `wx` quietly produces no beams. Applications whose modules carry
`-behaviour(wx_object)` then fail, because OTP compiles with warnings as
errors:

```
dbg_wx_filedialog_win.erl:25:2: behaviour wx_object undefined
make: *** [Makefile:510: libs] Error 2
```

Use OTP's own mechanism — `lib/Makefile` reads `lib/SKIP-APPLICATIONS` and
filters those names out of `SUB_DIRECTORIES` for both the `libs` and `release`
targets:

```bash
printf 'wx\ndebugger\net\nobserver\n' > lib/SKIP-APPLICATIONS
```

EMQX needs none of them; `observer` is already in `emqx_machine_boot`'s
`?OPTIONAL_APPS`.

#### 3.5.4 Build and install it

From a shell that has MSVC on PATH:

```bash
export ERL_TOP=/c/src/emqx-otp
cd "$ERL_TOP"

eval "$(./otp_build env_win32 x64)"
./otp_build autoconf
./otp_build configure --with-ssl=C:/OpenSSL-Win64 --disable-dynamic-ssl-lib \
    --without-wx --without-javac
./otp_build boot -a
./otp_build release -a /c/erlang/28.4.1-7-emqx
```

Then — this step is easy to miss — generate the top-level scripts. `release -a`
installs `lib/`, `releases/` and `erts-*/` but **no `bin/`**:

```bash
cd /c/erlang/28.4.1-7-emqx && cmd.exe //c "Install.exe -s"
```

Three things to **not** do in that shell:

* **Do not add `--without-odbc`.** It is tempting, since no ODBC driver is
  needed to build EMQX — but `odbc` is a real dependency:
  `emqx_bridge_quasardb` and `emqx_bridge_snowflake` both list it in
  `extra_applications`, so the release cannot be assembled without it. It also
  fails unhelpfully: the Erlang side of `odbc` still compiles, only
  `lib/odbc/configure` never runs, so no `c_src/win32/Makefile` is generated
  and `boot -a` stops with `No rule to make target 'win32/Makefile'`. No
  `lib/odbc/SKIP` is written either, so the app is not cleanly excluded.
  Recovery without a full reconfigure:

  ```bash
  cd lib/odbc && rm -f SKIP
  ./configure --build=local-x86_64-pc-windows --host=local-x86_64-pc-windows \
      --target=local-x86_64-pc-windows CC=cc.sh CXX=cc.sh RANLIB=true AR=ar.sh \
      --cache-file=./odbc.config.cache
  ```

  Use a *fresh* cache file — the top-level one was primed by the run that
  passed `--without-odbc` and holds no ODBC probe results. Success looks like
  `checking for sql.h... yes` and `config.status: creating c_src/win32/Makefile`.

* **Do not set `MSYS2_ARG_CONV_EXCL='*'`.** The NIF helper scripts under
  `scripts/windows/` need it, but `otp_build` does not: it invokes `cmd //C`
  and relies on MSYS2 rewriting that to `/C`. With conversion disabled,
  `cmd.exe` sees `//C`, treats it as nothing to run, and waits on stdin — the
  build simply hangs.

* **Do not leave Strawberry Perl on PATH.** `erts/emulator/utils/make_preload`
  shells out as `` `w32_path.sh -d $file` ``, and a native perl runs backticks
  through `cmd.exe`, which cannot execute a `.sh`. The symptom is
  `beams.rc(26) : error RC2135 : file not found:` with an empty
  `ERLANG_CODE ""`. `configure` bakes `PERL` into the generated makefiles, so
  fixing PATH afterwards is not enough — re-run `configure` until it records
  `PERL = /c/msys64/usr/bin/perl`.

#### 3.5.5 Point the build at it

`scripts/windows/build-env.sh` already defaults to
`ERL_HOME=/c/erlang/28.4.1-7-emqx` and prefers it when present, so no edit is
needed if you installed to that path. Otherwise export `ERL_HOME` yourself.

### 3.6 Elixir

The release is assembled by Mix, so Elixir is required, not optional. Use the
build made **for OTP 28**:

* <https://github.com/elixir-lang/elixir/releases/tag/v1.19.1> → `elixir-otp-28.zip`

Extract to `C:\elixir\1.19.1`.

Verify both from a fresh shell:

```
> erl -noshell -eval "io:format(\"~s~n\",[erlang:system_info(otp_release)]),halt()."
28
> elixir --version
Elixir 1.19.1 (compiled with Erlang/OTP 28)
```

---

## 4. Building EMQX

### 4.1 The one command

From a `cmd.exe` prompt in the repository root:

```bat
scripts\windows\build.cmd emqx-enterprise
```

That wrapper is the whole story: it finds the Visual Studio install with
`vswhere`, runs `vcvarsall.bat x64`, hands the resulting environment to MSYS2,
then fetches dependencies, patches the native-dependency hooks, pre-builds the
NIFs and runs `make`. `vcvarsall.bat` must run from `cmd.exe`, which is the
only reason a batch file exists.

`emqx-enterprise` is the only release profile in 6.x — `Makefile` defines
`REL_PROFILES := emqx-enterprise`, and there is no separate open-source
profile to build. The licence that applies at runtime is a separate matter;
the release prints its terms on boot.

### 4.2 Driving it by hand

```bat
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsall.bat" x64
set MSYSTEM=MSYS
set MSYS2_PATH_TYPE=inherit
set CHERE_INVOKING=1
C:\msys64\usr\bin\bash.exe -lc "cd /c/src/emqx && source scripts/windows/build-env.sh && make mix-deps-get && ./scripts/windows/patch-native-deps.sh && make emqx-enterprise"
```

`MSYS2_PATH_TYPE=inherit` is required: without it the MSYS2 login shell
rebuilds `PATH` from scratch and the MSVC directories are lost, giving
`ERROR: cl not found on PATH`.

### 4.3 Output

```
_build\emqx-enterprise\rel\emqx
```

About 226 MB. The Erlang runtime is embedded (`erts-16.3\`), so the directory
is self-contained — the target machine does not need Erlang installed.

To produce a zip package instead:

```bat
scripts\windows\build.cmd emqx-enterprise-tgz
```

On Windows, `build` packs the release with `7z` into
`_packages\emqx-enterprise\emqx-enterprise-<vsn>-windows-amd64.zip`.

### 4.4 Rebuilding cleanly

A plain rebuild reuses compiled dependencies. That is usually what you want,
but **compiled beams remember the flags they were built with**. If you change
an exclusion (`BUILD_WITHOUT_*`) or a native build flag, delete the affected
dependency from `_build` or you will keep the old behaviour:

```bash
rm -rf _build/emqx-enterprise/lib/mria deps/mria/_build   # example: rocksdb toggled
rm -rf _build/emqx-enterprise/rel                         # force release re-assembly
```

---

## 5. Worked example — exact commands

This is the exact layout the 6.3.2 Windows build was produced with. Every path
is on `C:\` with no spaces.

### 5.1 Layout

| What | Path |
| --- | --- |
| EMQX source | `C:\xampp\htdocs\emqx` |
| OTP source (fork) | `C:\xampp\htdocs\emqx-otp` |
| Patched OTP install | `C:\erlang\28.4.1-7-emqx` |
| Stock OTP (bootstrap only) | `C:\erlang\28.4.1` |
| Elixir | `C:\elixir\1.19.1` |
| CMake | `C:\cmake\cmake-3.31.9-windows-x86_64` |
| NASM | `C:\nasm\nasm-2.16.03` |
| protoc | `C:\protoc` |
| Rust | `C:\rust\.cargo`, `C:\rust\.rustup` |
| OpenSSL | `C:\OpenSSL-Win64` |
| MSYS2 | `C:\msys64` |
| VS Build Tools | `C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools` |

### 5.2 Prerequisites

```powershell
# --- Visual Studio Build Tools -------------------------------------------
.\vs_BuildTools.exe --quiet --wait --norestart `
  --add Microsoft.VisualStudio.Workload.VCTools `
  --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
  --add Microsoft.VisualStudio.Component.Windows11SDK.26100

# --- MSYS2 ----------------------------------------------------------------
# install to C:\msys64, then in an MSYS2 shell:
#   pacman -Syu
#   pacman -S --needed make cmake jq zip unzip p7zip curl git patch perl tar diffutils

# --- CMake 3.31.9 ---------------------------------------------------------
Expand-Archive cmake-3.31.9-windows-x86_64.zip -DestinationPath C:\cmake

# --- NASM -----------------------------------------------------------------
Expand-Archive nasm-2.16.03-win64.zip -DestinationPath C:\nasm

# --- protoc ---------------------------------------------------------------
Expand-Archive protoc-win64.zip -DestinationPath C:\protoc

# --- Rust -----------------------------------------------------------------
$env:CARGO_HOME  = "C:\rust\.cargo"
$env:RUSTUP_HOME = "C:\rust\.rustup"
.\rustup-init.exe -y --default-toolchain stable --profile minimal

# --- Elixir 1.19.1 for OTP 28 --------------------------------------------
Expand-Archive elixir-otp-28.zip -DestinationPath C:\elixir\1.19.1

# --- Stock OTP 28.4.1, only to bootstrap the OTP build --------------------
.\otp_win64_28.4.1.exe /S /D=C:\erlang\28.4.1
```

### 5.3 Patched OTP

```bash
# in an MSYS2 shell that already has MSVC on PATH (see 5.4 for the wrapper)
git clone https://github.com/emqx/otp.git /c/xampp/htdocs/emqx-otp
cd /c/xampp/htdocs/emqx-otp
git checkout OTP-28.4.1-7

git config core.autocrlf false
git config core.eol lf
git rm --cached -r . >/dev/null && git reset --hard

git apply /c/xampp/htdocs/emqx/scripts/windows/otp-28.4.1-7-windows.patch
printf 'wx\ndebugger\net\nobserver\n' > lib/SKIP-APPLICATIONS

export ERL_HOME=/c/erlang/28.4.1          # stock OTP bootstraps the build
source /c/xampp/htdocs/emqx/scripts/windows/build-env.sh
export ERL_TOP=/c/xampp/htdocs/emqx-otp
cd "$ERL_TOP"

eval "$(./otp_build env_win32 x64)"
./otp_build autoconf
./otp_build configure --with-ssl=C:/OpenSSL-Win64 --disable-dynamic-ssl-lib \
    --without-wx --without-javac
./otp_build boot -a
./otp_build release -a /c/erlang/28.4.1-7-emqx

cd /c/erlang/28.4.1-7-emqx && cmd.exe //c "Install.exe -s"
```

Verify the fork is really in place:

```bash
/c/erlang/28.4.1-7-emqx/bin/erl.exe -noshell -eval '
  {ok,L}=gen_tcp:listen(0,[]),
  io:format("packet,mqtt: ~p~n",[inet:setopts(L,[{packet,mqtt}])]),
  io:format("mnesia_hook: ~p~n",[code:ensure_loaded(mnesia_hook)]),
  halt().'
# packet,mqtt: ok
# mnesia_hook: {module,mnesia_hook}
```

### 5.4 EMQX

```bat
cd C:\xampp\htdocs\emqx
scripts\windows\build.cmd emqx-enterprise
```

Result: `C:\xampp\htdocs\emqx\_build\emqx-enterprise\rel\emqx`

### 5.5 Run and test it

```bat
cd C:\xampp\htdocs\emqx\_build\emqx-enterprise\rel\emqx
bin\emqx.cmd start
bin\emqx_ctl.cmd status
```

Expected:

```
Node 'emqx@127.0.0.1' 6.3.2 is started
```

An end-to-end MQTT check using the `emqtt` client already inside the release:

```bash
cd /c/xampp/htdocs/emqx/_build/emqx-enterprise/rel/emqx
/c/erlang/28.4.1-7-emqx/bin/erl.exe -noshell \
  -pa lib/emqtt-*/ebin -pa lib/cowlib-*/ebin -pa lib/gproc-*/ebin -pa lib/getopt-*/ebin -eval '
{ok,S}=emqtt:start_link([{host,"127.0.0.1"},{port,1883},{clientid,<<"sub">>}]),{ok,_}=emqtt:connect(S),
{ok,_,[1]}=emqtt:subscribe(S,{<<"t/1">>,1}),
{ok,P}=emqtt:start_link([{host,"127.0.0.1"},{port,1883},{clientid,<<"pub">>}]),{ok,_}=emqtt:connect(P),
{ok,_}=emqtt:publish(P,<<"t/1">>,<<"hello">>,1),
receive {publish,M} -> io:format("RECEIVED: ~s~n",[maps:get(payload,M)]) after 5000 -> io:format("TIMEOUT~n") end,
halt().'
# RECEIVED: hello
```

### 5.6 Running a second node beside an existing EMQX

If the machine already runs another EMQX, move the new node out of its way.
`ekka_dist:port/1` computes the distribution port as **`4370 + the trailing
digits of the node name`**, so a name without a trailing number collides with
the default `4370` — pick a numeric suffix, not just a different name:

```bat
set EMQX_NODE__NAME=emqxtest9@127.0.0.1
set EMQX_RPC__PORT_DISCOVERY=manual
set EMQX_RPC__SERVER_PORT=5470
set EMQX_LISTENERS__TCP__DEFAULT__BIND=1884
set EMQX_LISTENERS__WS__DEFAULT__BIND=8085
set EMQX_DASHBOARD__LISTENERS__HTTP__BIND=18084
bin\emqx.cmd start
```

---

## 6. Running the broker

```bat
cd _build\emqx-enterprise\rel\emqx
bin\emqx.cmd start
bin\emqx_ctl.cmd status
```

`bin\emqx.cmd` supports `start`, `stop`, `restart`, `console`, `ping`,
`attach` / `remote_console`, `ctl`, `list`, and `install` / `uninstall` to
register the node as a Windows service via `erlsrv.exe`.

Two things worth knowing:

* **`console` needs a real console.** It runs `erl` without `-noinput`, so with
  redirected stdin the Erlang shell cannot start and the boot stalls
  permanently at `Command table is initializing.` while still holding the
  distribution port. For scripted or non-interactive use, prefer `start`, or
  add `-noinput`.
* **`bin\emqx` and `bin\emqx.cmd` are different launchers** for the same
  release; on Windows use the `.cmd`. Mix's own generated `bin\emqx.bat` is
  deleted during release assembly precisely so it cannot shadow `emqx.cmd` —
  `.BAT` precedes `.CMD` in the default `PATHEXT`.

---

## 7. Troubleshooting

### The node boots on an empty data dir, then kills the VM on every restart

Exit `132` from a shell that reports signals; Windows exception `0xC000001D`
(illegal instruction). There is **no log line, no `erl_crash.dump` and no
Windows event log entry**, because the process dies mid-instruction rather
than exiting.

The cause is the bundled Snappy, not EMQX. Snappy decides at configure time
whether to emit BMI2 instructions using `check_cxx_source_compiles` on
`_bzhi_u32`. MSVC needs no `-mbmi2` switch for that intrinsic, so the probe
always succeeds and `SNAPPY_HAVE_BMI2` is set to 1 whatever the target CPU is.
BMI2 arrived with Haswell (2013), so on anything older the library faults the
first time a block is compressed or an existing SST file is read back.

That is why the first boot looks healthy: fresh writes sit uncompressed in the
memtable and WAL, and nothing reads an SST until the next start.

`scripts/windows/patch-native-deps.sh` pins `-DSNAPPY_HAVE_BMI2=0`, matching
the `PORTABLE=ON` RocksDB is already built with. Set `EMQX_SNAPPY_BMI2=1` to
opt back in when the build host and every target are known to be Haswell or
newer.

Minimal reproduction, with no EMQX and no mnesia involved:

```erlang
{ok,Db} = rocksdb:open("/tmp/t", [{create_if_missing,true}]),
[rocksdb:put(Db, <<N:32>>, <<"v">>, []) || N <- lists:seq(1,2000)],
rocksdb:flush(Db, []).        %% dies here on a pre-Haswell CPU
```

Passing `{compression,none}` makes the same sequence pass — the quickest way
to confirm the diagnosis.

### `'c++' is not recognized` from the port compiler

`REBAR_TARGET_ARCH` is unset. OTP 24 reported `win32` from
`erlang:system_info(system_architecture)`; OTP 28 reports
`x86_64-pc-windows`. The `pc` plugin selects its MSVC defaults — and deps like
`snappyer` and `jiffy` select their Windows `port_env` — by matching a `win32`
regex against that string, so on OTP 28 every one of those branches stops
matching and the gcc defaults are used instead.

`scripts/windows/build-env.sh` exports `REBAR_TARGET_ARCH=x86_64-win32` to put
`win32` back into the string. **This is the single change without which no NIF
compiles on Windows.**

Note that rebar3's *core* hook filtering ignores `REBAR_TARGET_ARCH`, which is
why `patch-native-deps.sh` also widens hook patterns from `"win32"` to
`"win32|windows"`.

### `'cl.exe' is not recognized` / `fatal error C1083: Cannot open include file: 'assert.h'`

`vcvarsall.bat x64` was not run, or MSYS2 rebuilt `PATH` without the MSVC
directories. Check `command -v cl` inside the build shell, and make sure
`MSYS2_PATH_TYPE=inherit` is set before launching bash.

### `link: extra operand 'some.obj'`

GNU `link` is ahead of MSVC's linker on PATH. `link.exe --version` should
print `Microsoft (R) Incremental Linker`.

### `'.' is not recognized as an internal or external command`

Seen while compiling `datalayers` or `greptimedb_rs`:
`scripts/windows/patch-native-deps.sh` has not run since the deps were
fetched. `mix deps.clean` reverts the patch, so re-run it after one.

### `Missing artifact priv/<name>.so`

A native NIF was not pre-built. Mix symlinks a dependency's `priv/` **before**
compiling it, so the NIFs must exist beforehand — that is what the
`build_nif_now` calls at the end of `patch-native-deps.sh` are for. Re-run
that script.

### `emqx_ctl` says "not responding to pings" while the node is clearly up

EMQX uses its own distribution protocol. `bin\emqx.cmd` sets:

```
ERL_FLAGS=-start_epmd false -epmd_module ekka_epmd -proto_dist ekka
```

Every `erl`/`escript` the launcher spawns — including `nodetool`, which
`emqx_ctl` is built on — uses it. A node started **without** those flags speaks
plain `inet_tcp` and registers with the normal epmd, and the two cannot see
each other. If `epmd -names` lists your EMQX node, it was started with the
wrong distribution.

### `Protocol 'ekka': register/listen error: "port 4370 is in use"`

Another EMQX node already owns that port. See
[§5.6](#56-running-a-second-node-beside-an-existing-emqx) — give the node name
a numeric suffix.

### A build dies in `quicer` or `jq`

The matching `BUILD_WITHOUT_*` did not reach Mix. They are exported by `build`
for `SYSTEM=windows`; export them by hand if you invoke `mix` directly.

### `ops.tab(27): '' is not a recognized type` while building OTP

CRLF line endings in the OTP source tree. See
[§3.5.1](#351-clone-and-turn-crlf-translation-off-first).

---

## 8. Reference: what each script does

| Script | Purpose |
| --- | --- |
| `scripts/windows/build.cmd` | Entry point. Locates Visual Studio with `vswhere`, runs `vcvarsall.bat x64`, verifies `cl.exe`, then hands off to MSYS2 bash with the environment inherited. |
| `scripts/windows/build-env.sh` | Builds `PATH` in the right order (MSVC → CMake → `/usr/bin` → Erlang/Elixir/Rust/protoc/NASM → Windows dirs), exports `REBAR_TARGET_ARCH`, points RocksDB at the Snappy/LZ4 static libs, and verifies the toolchain is complete. Source it in an MSYS2 shell. |
| `scripts/windows/patch-native-deps.sh` | Adds or widens Windows compile hooks for `ezstd`, `crc32cer`, `lz4b` and `rocksdb`; reroutes the Rust NIF hooks through bash; pins `SNAPPY_HAVE_BMI2=0`; then pre-builds every native NIF. Idempotent. Run after `make mix-deps-get`. |
| `scripts/windows/build-rocksdb.sh` | Builds RocksDB with MSVC/CMake plus static Snappy and LZ4, producing `priv/liberocksdb.dll`. |
| `scripts/windows/build-ezstd.sh` | Builds zstd and the `ezstd` NIF with `cl.exe`. |
| `scripts/windows/build-crc32cer.sh` | Builds the `crc32cer` NIF (mandatory `on_load`). |
| `scripts/windows/build-lz4b.sh` | Builds the `lz4b` NIF (mandatory `on_load`). |
| `scripts/windows/build-rust-nif.sh` | Runs a Rust NIF's `do_compile.sh` through bash, then copies `priv/*.so` to `.dll` so `erlang:load_nif/2` finds it. |
| `scripts/windows/otp-28.4.1-7-windows.patch` | The three OTP build fixes from [§3.5.2](#352-apply-the-three-otp-patches). |

The four `build-<nif>.sh` scripts for `rocksdb`, `ezstd`, `crc32cer` and
`lz4b` are idempotent — they no-op when the library already exists. Set
`FORCE=1` to rebuild one anyway. `build-rust-nif.sh` has no such guard; it
defers to cargo, which does its own caching.
