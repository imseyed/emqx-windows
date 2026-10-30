@echo off
:: Build EMQX on Windows.
::
:: Usage, from any cmd.exe prompt, in the repo root:
::
::   scripts\windows\build.cmd emqx-enterprise
::   scripts\windows\build.cmd emqx-enterprise-tgz
::
:: Anything passed here is handed to `make`, so with no argument the default
:: goal builds $(PROFILE). Override MSYS2_ROOT if MSYS2 is not in C:\msys64.
::
:: This exists because the build needs two environments stitched together:
:: MSVC (for the NIF port compiler) and MSYS2 (for bash, make and the POSIX
:: tools the build scripts shell out to). vcvarsall.bat can only be run from
:: cmd.exe, so it runs here and MSYS2 inherits what it exported.

setlocal

if "%MSYS2_ROOT%"=="" set "MSYS2_ROOT=C:\msys64"

if not exist "%MSYS2_ROOT%\usr\bin\bash.exe" (
  echo ERROR: no MSYS2 bash at "%MSYS2_ROOT%\usr\bin\bash.exe".
  echo Install MSYS2, or set MSYS2_ROOT to where it lives.
  exit /b 1
)

:: Locate the Visual Studio installation that carries vcvarsall.bat.
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" (
  echo ERROR: vswhere.exe not found; is Visual Studio Build Tools installed?
  echo See Windows.md for the install command.
  exit /b 1
)

set "VSINSTALL="
for /f "usebackq delims=" %%i in (`^""%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath^"`) do set "VSINSTALL=%%i"

if not defined VSINSTALL (
  echo ERROR: no Visual Studio install with the x64 C++ toolset was found.
  echo See Windows.md for the install command.
  exit /b 1
)

set "VCVARSALL=%VSINSTALL%\VC\Auxiliary\Build\vcvarsall.bat"
if not exist "%VCVARSALL%" (
  echo ERROR: vcvarsall.bat not found under "%VSINSTALL%".
  exit /b 1
)

call "%VCVARSALL%" x64
if errorlevel 1 (
  echo ERROR: vcvarsall.bat failed.
  exit /b 1
)

where cl.exe >nul 2>&1
if errorlevel 1 (
  echo ERROR: cl.exe is still not on PATH after vcvarsall.bat.
  exit /b 1
)

:: Hand the MSVC environment to MSYS2 rather than letting it build its own.
set MSYSTEM=MSYS
set MSYS2_PATH_TYPE=inherit
set CHERE_INVOKING=1

:: `make` with no target builds $(PROFILE), which is emqx-enterprise.
set "MAKE_ARGS=%*"

:: Deps are fetched first, then patched, then built: two of them carry a
:: compile hook that cmd.exe cannot run. See patch-native-deps.sh.
::
:: cygpath is addressed by its full path: at this point PATH is still the
:: Windows one, so nothing from /usr/bin is resolvable by name yet.
"%MSYS2_ROOT%\usr\bin\bash.exe" -lc "cd \"$(/usr/bin/cygpath -u '%CD%')\" && source scripts/windows/build-env.sh && make mix-deps-get && ./scripts/windows/patch-native-deps.sh && make %MAKE_ARGS%"
exit /b %ERRORLEVEL%
