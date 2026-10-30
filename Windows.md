# Build and run EMQX on Windows

Windows packages were dropped from CI after EMQX 4.3, and the batch launchers
were deleted from the tree in late 2025. This document describes the build as
it is wired up again on the 6.3 line, and is written against Windows Server
2025 / Windows 11 with EMQX 6.3.2.

## What a Windows build leaves out

Two native dependencies have no Windows build and are switched off by `build`
when `SYSTEM=windows`:

| Dependency | Switch | What you lose |
| --- | --- | --- |
| RocksDB | `BUILD_WITHOUT_ROCKSDB=on` | Durable sessions and the `builtin_raft`/`builtin_local` durable storage backends. `durable_sessions.enable` defaults to `false`, so a node boots fine without it, but turning it on will fail. |
| quicer (msquic) | `BUILD_WITHOUT_QUIC=on` | MQTT over QUIC listeners. |
| jq | `BUILD_WITHOUT_JQ=on` | The `jq()` rule-engine function. jq runs its filters in an external port program built by an autotools script with no Windows path; the `jq` application cannot start without it, which would take the whole node down, so the app is left out of the release rather than shipped broken. |
| bcrypt | `BUILD_WITHOUT_BCRYPT=on` | `bcrypt` as a `password_hash_algorithm`. Its NIF wants `sys/queue.h`, `err.h`, `unistd.h` and pthreads; MSVC has none of them, and mingw-w64 ships neither `sys/queue.h` nor `err.h`. `emqx_machine_boot` already lists `bcrypt` in `?OPTIONAL_APPS`, so the node boots without it. Use `pbkdf2` or `sha256` instead. |

Two more dependencies carry native code that is not switched off but does need
handling:

* `sasl_auth`, `crc32cer` and `jq`'s NIF guard their compile hooks to
  `linux|darwin|solaris|freebsd`, so on Windows their Erlang modules build and
  the NIF simply is not there. Only the code paths that call into them —
  Kerberos/GSSAPI authentication, and the Pulsar integration's checksums —
  are affected.
* `datalayers` and `greptimedb_rs` are Rust NIFs whose hook is
  `./do_compile.sh`. rebar3 runs hooks through `cmd.exe`, which cannot execute
  a shell script, and `do_compile.sh` names its artifact `.so` where
  `erlang:load_nif/2` wants `.dll` on Windows. `scripts/windows/` carries two
  small scripts for this; see *Building* below.

Everything else — including the Kafka, Postgres and other data integrations —
is built normally.

`node.db_backend` is forced to `mnesia` by `bin/emqx.cmd` rather than the
default `rlog`, because the Windows build is meant to run as a single node.

## Build environment

### Visual Studio Build Tools (C/C++ compiler)

Several dependencies ship Erlang NIFs written in C/C++ (`jiffy`, `snappyer`).
rebar3's port compiler uses `cl.exe` and `link.exe` on Windows, so a Microsoft
toolchain is required — MinGW is not a supported substitute.

Install the 2022 Build Tools with the C++ workload:

```
vs_BuildTools.exe --quiet --wait --norestart ^
  --add Microsoft.VisualStudio.Workload.VCTools ^
  --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 ^
  --add Microsoft.VisualStudio.Component.Windows11SDK.26100
```

### Erlang/OTP — a patched OTP is mandatory

The versions are pinned in [`.tool-versions`](./.tool-versions). EMQX does
**not** run on a stock Erlang/OTP release: it boots against
[`emqx/otp`](https://github.com/emqx/otp), a fork that carries changes EMQX
depends on at runtime. On a stock OTP the node aborts with
`unsupported_otp_version` — and that check is not cosmetic. The two things it
is really guarding are:

* **`{packet, mqtt}`** — MQTT frame-length parsing implemented in the
  emulator's C code (`erts/emulator/drivers/common/packet_parser.c`,
  `erts/emulator/beam/atom.names`, `erl_bif_port.c`). On stock OTP
  `inet:setopts(S, [{packet, mqtt}])` returns `{error, einval}`. Because it
  lives in erts, it cannot be back-fitted by patching `.beam` files.
* **`mnesia_hook`** — a new `mnesia` module used by `mria`. On stock OTP it is
  `undef`. Note that setting `EMQX_NODE__DB_BACKEND=mnesia` does *not* avoid
  this: `mria_config:backend()` hard-codes `rlog`.

`ssl` carries fork changes as well.

Pre-built Windows binaries of `emqx/otp` are not published, so it has to be
built from source once. See
[Building the patched OTP on Windows](#building-the-patched-otp-on-windows)
below.

### Elixir

The release is assembled by Mix, so Elixir is required, not optional.

* Elixir 1.19.1 built for OTP 28 —
  <https://github.com/elixir-lang/elixir/releases/tag/v1.19.1> (`elixir-otp-28.zip`)

Verify both from a fresh shell:

```
> erl -noshell -eval "io:format(\"~s~n\",[erlang:system_info(otp_release)]),halt()."
28
> elixir --version
Elixir 1.19.1 (compiled with Erlang/OTP 28)
```

**Install both under paths without spaces.** `C:\erlang\28.4.1-7-emqx` and
`C:\elixir\1.19.1`, not `C:\Program Files\...`. `erlang.mk`, which several
deps (`mysql`, `ranch`) build with, passes `ERLC` unquoted through `cygpath`,
and a space in the path makes it fail with
`erlc: Error executing '"\"C:\Program Files\erl-28.4.1\...'`.

### MSYS2 (bash and the POSIX tools)

The build scripts are `bash` and `escript`. MSYS2 provides bash plus the
tools the build shells out to:

```
pacman -S --needed make cmake jq zip unzip p7zip curl git patch perl tar diffutils
```

Cygwin works too — `scripts/get-distro.sh` maps `CYGWIN*`, `MSYS*` and
`MINGW*` alike to `windows` — but MSYS2 is what the current build was
exercised with.

**PATH order matters.** MSYS2 ships a GNU `link.exe` that will shadow the
Microsoft linker, and `C:\Windows\System32\find.exe` will shadow POSIX `find`.
`scripts/windows/build-env.sh` sorts this out: MSVC first, then `/usr/bin`,
then the Windows directories. `build` additionally pins `FIND` and `TAR` to
their `/usr/bin` paths.

### Building the patched OTP on Windows

`emqx/otp` publishes no Windows binaries, so build it once and keep the
result. Everything below is a one-off; the EMQX build itself does not repeat
it.

```bash
git clone https://github.com/emqx/otp.git /c/src/emqx-otp
cd /c/src/emqx-otp
git checkout OTP-28.4.1-7
```

**Turn CRLF translation off in this clone before anything else.** The OTP tree
has no `.gitattributes`, so a global `core.autocrlf=true` checks the whole
thing out with CRLF and the build fails deep inside the emulator with
`ops.tab(27): '' is not a recognized type` — the `''` is a carriage return
overwriting the opening quote of the real message. Per-repository, so a global
preference is left alone:

```bash
git config core.autocrlf false
git config core.eol lf
git rm --cached -r . >/dev/null && git reset --hard
```

#### OpenSSL

OTP's `crypto` needs OpenSSL, and on Windows it wants the layout the official
OpenSSL installer produces, with **static** libraries:

```
C:/OpenSSL-Win64/include/openssl/...
C:/OpenSSL-Win64/lib/VC/x64/MD/libcrypto_static.lib
C:/OpenSSL-Win64/lib/VC/x64/MD/libssl_static.lib
```

Building OpenSSL from source needs a **native Windows perl** (Strawberry
Perl); its `Configure` rejects the MSYS perl with *"This perl implementation
doesn't produce Windows like paths"*. Put Strawberry on PATH only between the
MSVC directories and `/usr/bin` — ahead of MSVC and its `link.exe` shadows the
Microsoft linker (`link: extra operand '/dll'`).

`configure` succeeded when it reported:

```
checking for OpenSSL in C:/OpenSSL-Win64... static libcrypto_static library in C:/OpenSSL-Win64/lib/VC/x64/MD
```

#### Three patches are required

All three are bugs in OTP's own Windows build, not EMQX-specific. They are
kept as a single patch file, so applying them takes one command:

```bash
git apply /path/to/emqx/scripts/windows/otp-28.4.1-7-windows.patch
```

What each one fixes:

1. `erts/emulator/Makefile.in` — the win32 branch sets `DEP_FLAGS` from
   `$(INCLUDES)` instead of `$(DEP_INCLUDES)` (the non-win32 branch a few
   lines down already uses the latter), so the `depend` step cannot find
   `prim_file_nif.h`. Change it to `$(DEP_INCLUDES)`. If
   `erts/emulator/win32/Makefile` has already been generated, fix it there too.
2. `erts/etc/win32/msys_tools/vc/cc.sh` — add a `-std=c++*|-std=gnu++*` case
   before the `-l*)` case, translating to `/std:c++NN /Zc:__cplusplus`.
   Unrecognised options fall through to the *linker*, so `-std=c++17` never
   reaches `cl.exe` and `configure` reports
   `JIT disabled due to lack of compiler with C++17 support`. `/Zc:__cplusplus`
   matters because MSVC otherwise reports `__cplusplus` as `199711L`, which is
   exactly what the probe tests. Correct output is
   `checking for C++17 support... yes`, and `bin/win32/beam.jit.dll` gets built.
3. `erts/etc/win32/msys_tools/vc/ld.sh` — widen the library-path case from
   `-L/*|-L.*)` to `-L?*)`. The original patterns only match a POSIX-absolute
   (`-L/...`) or relative (`-L....`) path, but `configure` records
   `SSL_LIBDIR = C:/OpenSSL-Win64/lib/VC/x64/MD` and so emits a Windows drive
   path. That matches neither, falls through to the catch-all, and reaches
   `link.exe` verbatim as `/LC:/OpenSSL-Win64/...`, which it dismisses with
   `LINK : warning LNK4044: unrecognized option ...; ignored`. The directory
   is therefore dropped and the next line is the real failure:
   `LINK : fatal error LNK1181: cannot open input file 'libcrypto_static.lib'`.
   Note the fatal error names a *library*, not a path, so it reads like a
   missing OpenSSL install — the LNK4044 warning immediately above it is the
   actual diagnosis.

#### Skip the wx applications

`otp_build boot -a` builds *every* application, and nothing here provides
wxWidgets, so `wx` quietly produces no beams. The apps whose modules carry
`-behaviour(wx_object)` then fail, because OTP compiles with warnings as
errors:

```
dbg_wx_filedialog_win.erl:25:2: behaviour wx_object undefined
make: *** [Makefile:510: libs] Error 2
```

Use OTP's own mechanism rather than patching makefiles — `lib/Makefile` reads
`lib/SKIP-APPLICATIONS` and filters those names out of `SUB_DIRECTORIES` for
both the `libs` and the `release` target:

```bash
printf 'wx\ndebugger\net\nobserver\n' > lib/SKIP-APPLICATIONS
```

EMQX needs none of them; `observer` is already listed in
`emqx_machine_boot`'s `OPTIONAL_APPS`.

#### Build it

From a shell that has MSVC on PATH (`scripts/windows/build-env.sh` arranges
that):

```bash
eval `./otp_build env_win32 x64`
./otp_build autoconf
./otp_build configure --with-ssl=C:/OpenSSL-Win64 --disable-dynamic-ssl-lib \
    --without-wx --without-javac
./otp_build boot -a
./otp_build release -a /c/erlang/28.4.1-7-emqx
```

**Do not add `--without-odbc`.** It is tempting, because no ODBC driver is
needed to *build* EMQX — but `odbc` is a real dependency:
`emqx_bridge_quasardb` and `emqx_bridge_snowflake` both list it in
`extra_applications`, so the release cannot be assembled without it. The flag
also fails in an unhelpful way: the Erlang side of `odbc` still compiles, only
`lib/odbc/configure` never runs, so no `c_src/win32/Makefile` is generated and
`boot -a` stops with `No rule to make target 'win32/Makefile'` — and because
no `lib/odbc/SKIP` is written either, the app is not cleanly excluded.
ODBC itself needs nothing extra: `sql.h`, `sqlext.h` and `odbc32.lib` all ship
with the Windows SDK, so `vcvarsall.bat` has already put them on `INCLUDE` and
`LIB`. If you did pass the flag, configuring that one application is enough to
recover — a full reconfigure is not needed:

```bash
cd lib/odbc && rm -f SKIP
./configure --build=local-x86_64-pc-windows --host=local-x86_64-pc-windows \
    --target=local-x86_64-pc-windows CC=cc.sh CXX=cc.sh RANLIB=true AR=ar.sh \
    --cache-file=./odbc.config.cache
```

Use a *fresh* cache file: the top-level one was primed by the run that passed
`--without-odbc`, so it holds no ODBC probe results to reuse. Success looks
like `checking for sql.h... yes` and `config.status: creating
c_src/win32/Makefile`.

Two more things to *not* do in that shell:

* **Do not set `MSYS2_ARG_CONV_EXCL='*'`.** The NIF helper scripts under
  `scripts/windows/` need it, but `otp_build` does not: it invokes `cmd //C`
  and relies on MSYS2 rewriting that to `/C`. With conversion disabled,
  `cmd.exe` sees `//C`, treats it as nothing to run, and waits on stdin — the
  build simply hangs.
* **Do not leave Strawberry Perl on PATH.** `erts/emulator/utils/make_preload`
  shells out as `` `w32_path.sh -d $file` ``, and a native perl runs backticks
  through `cmd.exe`, which cannot execute a `.sh`. The symptom is
  `beams.rc(26) : error RC2135 : file not found:` with an empty
  `ERLANG_CODE ""`. Note `configure` bakes `PERL` into the generated
  makefiles, so fixing PATH afterwards is not enough — re-run `configure`
  until it records `PERL = /c/msys64/usr/bin/perl`.

Finally point the build at it:

```bash
# scripts/windows/build-env.sh
ERL_HOME=/c/erlang/28.4.1-7-emqx
```

## Building

From a `cmd.exe` prompt in the repo root:

```
scripts\windows\build.cmd emqx-enterprise
```

That wrapper is the whole story: it finds the Visual Studio install with
`vswhere`, runs `vcvarsall.bat x64`, hands the resulting environment to MSYS2,
and from there fetches the dependencies, patches the two Rust NIF hooks and
runs `make`. `vcvarsall.bat` has to run from `cmd.exe`, which is why a batch
file exists at all.

The three pieces it uses, if you would rather drive them by hand:

| Script | Does what |
| --- | --- |
| `scripts/windows/build-env.sh` | Builds PATH in the right order and checks the toolchain is complete. Source it in an MSYS2 shell. |
| `scripts/windows/patch-native-deps.sh` | Rewrites the `datalayers` and `greptimedb_rs` compile hooks to go through bash. Idempotent; run after `make mix-deps-get`. |
| `scripts/windows/build-rust-nif.sh` | The hook those two deps end up calling. Runs their `do_compile.sh`, then copies the built `priv/*.so` to `.dll` so `erlang:load_nif/2` finds it. |

Equivalently, by hand:

```
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsall.bat" x64
set MSYSTEM=MSYS
set MSYS2_PATH_TYPE=inherit
C:\msys64\usr\bin\bash.exe -lc "cd /c/path/to/emqx && source scripts/windows/build-env.sh && make mix-deps-get && ./scripts/windows/patch-native-deps.sh && make emqx-enterprise"
```

The release lands in `_build/emqx-enterprise/rel/emqx`.

To produce a zip package instead, use `make emqx-enterprise-tgz`; on Windows
`build` packs the release with `7z` into
`_packages/emqx-enterprise/emqx-enterprise-<vsn>-windows-amd64.zip`.

## Running

```
> cd _build\emqx-enterprise\rel\emqx
> .\bin\emqx console
```

and, from a second shell:

```
> .\bin\emqx_ctl status
```

`bin\emqx.cmd` also supports `start`, `stop`, `restart`, `ping`, `attach` /
`remote_console`, `list`, and `install` / `uninstall` to register the node as a
Windows service via `erlsrv.exe`.

Note that `bin\emqx` (the bash script) and `bin\emqx.cmd` are two different
launchers for the same release; on Windows use the `.cmd` one. Mix's own
generated `bin\emqx.bat` is deleted during release assembly precisely so that
it cannot shadow `emqx.cmd` — `.BAT` precedes `.CMD` in the default `PATHEXT`.

## Troubleshooting

* **The node boots on an empty data dir, then kills the VM on every restart**
  — exit `132` from a shell that reports signals, Windows exception
  `0xC000001D` (illegal instruction). There is no log line, no
  `erl_crash.dump` and no entry in the Windows event log, because the process
  dies mid-instruction rather than exiting.

  The cause is the bundled Snappy, not EMQX. Snappy decides at configure time
  whether to emit BMI2 instructions using
  `check_cxx_source_compiles` on `_bzhi_u32`; MSVC needs no `-mbmi2` switch
  for that intrinsic, so the probe always succeeds and `SNAPPY_HAVE_BMI2` is
  set to 1 whatever the target CPU is. BMI2 arrived with Haswell (2013), so on
  anything older the library faults the first time a block is compressed or an
  existing SST file is read back. That is why the first boot looks healthy:
  fresh writes sit in the memtable and WAL, uncompressed, and nothing reads an
  SST until the next start.

  `scripts/windows/patch-native-deps.sh` pins `-DSNAPPY_HAVE_BMI2=0`, which
  matches the `PORTABLE=ON` RocksDB is already built with. Set
  `EMQX_SNAPPY_BMI2=1` to opt back in when the build host and every target
  are known to be Haswell or newer.

  Minimal reproduction, with no EMQX and no mnesia involved:

  ```erlang
  {ok,Db} = rocksdb:open("/tmp/t", [{create_if_missing,true}]),
  [rocksdb:put(Db, <<N:32>>, <<"v">>, []) || N <- lists:seq(1,2000)],
  rocksdb:flush(Db, []).        %% dies here on a pre-Haswell CPU
  ```

  Passing `{compression,none}` makes the same sequence pass, which is the
  quickest way to confirm the diagnosis.

  Check the CPU before assuming a build is portable:
  `grep -m1 flags /proc/cpuinfo | tr ' ' '\n' | grep -E '^(avx2?|bmi2)$'`.

* `'cl.exe' is not recognized` — `vcvarsall.bat x64` was not run, or MSYS2's
  PATH was built without the MSVC directories. Check `command -v cl` inside
  the build shell.

* `fatal error C1083: Cannot open include file: 'assert.h'` — `INCLUDE`/`LIB`
  are unset, same cause as above.

* `link: extra operand 'some.obj'` — GNU `link` is ahead of MSVC's linker.
  `link.exe --version` should print `Microsoft (R) Incremental Linker`.

* `'c++' is not recognized as an internal or external command` from the port
  compiler means `REBAR_TARGET_ARCH` is unset. OTP 24 reported `win32` from
  `erlang:system_info(system_architecture)`; OTP 28 reports
  `x86_64-pc-windows`. The `pc` plugin selects its MSVC defaults - and deps
  like `snappyer` and `jiffy` select their Windows `port_env` - by matching a
  `win32` regex against that string, so on OTP 28 every one of those branches
  stops matching and the gcc defaults are used instead.
  `scripts/windows/build-env.sh` exports `REBAR_TARGET_ARCH=x86_64-win32` to
  put `win32` back into the string. This is the single change without which no
  NIF compiles on Windows.

* A build that dies in `rocksdb`, `quicer` or `jq` means the matching
  `BUILD_WITHOUT_*` did not reach Mix. They are exported by `build` for
  `SYSTEM=windows`; export them by hand if you are invoking `mix` directly.

* `'.' is not recognized as an internal or external command` while compiling
  `datalayers` or `greptimedb_rs` means scripts/windows/patch-native-deps.sh
  has not run since the deps were fetched. `mix deps.clean` reverts the patch,
  so re-run it after one.
