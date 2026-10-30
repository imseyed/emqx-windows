:: This batch file handles managing an Erlang node as a Windows service.
::
:: Commands provided:
::
:: * install - install the release as a Windows service
:: * start - start the service and Erlang node
:: * stop - stop the service and Erlang node
:: * restart - run the stop command and start command
:: * uninstall - uninstall the service and kill a running node
:: * ping - check if the node is running
:: * ctl - run management commands
:: * console - start the Erlang release in an interactive shell
:: * attach - connect to a running node and open an interactive console
:: * remote_console - same as attach
:: * list - display a listing of installed Erlang services
:: * usage - display available commands

:: Set variables that describe the release
@set rel_name=emqx
@set rel_vsn={{ release_version }}
@set REL_VSN=%rel_vsn%
@set erts_vsn={{ erts_vsn }}
@set erl_opts={{ erl_opts }}

@set script=%~n0

@set EPMD_ARG=-start_epmd false -epmd_module ekka_epmd -proto_dist ekka
@set ERL_FLAGS=%EPMD_ARG%

:: Discover the release root directory from the directory
:: of this script
@set script_dir=%~dp0
@for %%A in ("%script_dir%\..") do @(
  set rel_root_dir=%%~fA
)

:: If release dir has space, change dir
@if not "%rel_root_dir%"=="%rel_root_dir: =%" (
    @chdir /d "%rel_root_dir%"
    @set rel_root_dir=.
)

@set "erts_dir=%rel_root_dir%\erts-%erts_vsn%"
@set "rootdir=%rel_root_dir%"
@set "rel_dir=%rel_root_dir%\releases\%rel_vsn%"
@set "RUNNER_ROOT_DIR=%rel_root_dir%"
:: hard code etc dir
@set "EMQX_ETC_DIR=%rel_root_dir%\etc"
@set "EMQX_LOG_DIR=%rel_root_dir%\log"
@set "etc_dir=%rel_root_dir%\etc"
@set "lib_dir=%rel_root_dir%\lib"
:: Mix releases write $RELEASE_LIB into the boot file, so every erl that
:: boots this release has to say where that is, or it dies with
:: "cannot expand $RELEASE_LIB in bootfile". bin/emqx does the same on
:: Unix.
@set "boot_var=-boot_var RELEASE_LIB "%lib_dir%""
@set "emqx_conf=%etc_dir%\emqx.conf"

@set "boot_file_name=%rel_dir%\start"
@set "service_name=%rel_name%_%rel_vsn%"
@set "bindir=%erts_dir%\bin"
@set progname=erl.exe
@set "clean_boot_file_name=%rel_dir%\start_clean"
@set "erlsrv=%bindir%\erlsrv.exe"
@set "escript=%bindir%\escript.exe"
@set "erl_exe=%bindir%\erl.exe"
@set "nodetool=%rel_root_dir%\bin\nodetool"
@set HOCON_ENV_OVERRIDE_PREFIX=EMQX_
@set node_type=-name
@set schema_mod=emqx_conf_schema
:: no advanced DB backend for Windows
@set EMQX_NODE__DB_BACKEND=mnesia
@set EMQX_NODE__DB_ROLE=core

:: Write the erl.ini file to set up paths relative to this script
@call :write_ini

:: If a start.boot file is not present, copy one from the named .boot file
@if not exist "%rel_dir%\start.boot" (
  copy "%rel_dir%\%rel_name%.boot" "%rel_dir%\start.boot" >nul
)

@set conf_path="%etc_dir%\emqx.conf"

@for /f "usebackq tokens=1,2 delims==" %%a in (`"%escript% %nodetool% hocon -s %schema_mod% -c %conf_path% multi_get node.name node.cookie node.data_dir"`) do @(
  if "%%a"=="node.name" set node_name=%%b
  if "%%a"=="node.cookie" set node_cookie=%%b
  if "%%a"=="node.data_dir" set data_dir=%%b
)

@set node_name=%node_name:"=%
@set node_cookie=%node_cookie:"=%
@set data_dir=%data_dir:"=%
:: remove trailing /
@if %data_dir:~-1%==/ SET data_dir=%data_dir:~0,-1%
:: remove trailing \
@if %data_dir:~-1%==\ SET data_dir=%data_dir:~0,-1%

@set abs_data_dir=%rel_root_dir%\%data_dir%
@if exist %abs_data_dir% (
  @set data_dir=%abs_data_dir%
)

@if not exist %data_dir%\ (
  @echo ERROR: data_dir %data_dir% does not exist
  @goto :eof
)

@if "%1"=="install" @goto install
@if "%1"=="uninstall" @goto uninstall
@if "%1"=="start" @goto start
@if "%1"=="stop" @goto stop
@if "%1"=="restart" @call :stop && @goto start
@if "%1"=="console" @goto console
@if "%1"=="ping" @goto ping
@if "%1"=="ctl" @goto ctl
@if "%1"=="list" @goto list
@if "%1"=="attach" @goto attach
@if "%1"=="remote_console" @goto attach
@if "%1"=="" @goto usage
@echo Unknown command: "%1"

@goto :eof

:create_mnesia_dir
@set create_dir_cmd=%escript% %nodetool% mnesia_dir "%data_dir%\mnesia" %node_name%
@for /f "delims=" %%Z in ('%%create_dir_cmd%%') do @(
  set mnesia_dir=%%Z
)
@goto :eof

:: get the current time with hocon
:get_cur_time
@for /f "usebackq tokens=1-6 delims=." %%a in (`"%escript% %nodetool% hocon now_time"`) do @(
  set now_time=%%a.%%b.%%c.%%d.%%e.%%f
)
@goto :eof

:generate_app_config
@call :get_cur_time
:: Same input sources, in the same order, as bin/emqx uses on Unix:
::   etc\base.hocon -> data\configs\cluster.hocon -> etc\emqx.conf -> EMQX_* env
:: cluster.hocon does not exist before the first boot; hocon skips it.
@%escript% %nodetool% hocon -v -t %now_time% -s %schema_mod% ^
  -c "%etc_dir%\base.hocon" ^
  -c "%data_dir%\configs\cluster.hocon" ^
  -c "%etc_dir%\emqx.conf" ^
  -d "%data_dir%\configs" generate
@set "generated_args=%data_dir%\configs\vm.%now_time%.args"
@set "merged_args=%data_dir%\configs\vm.%now_time%.merged.args"
:: hocon only generates the VM flags that are backed by a schema key, so the
:: static ones in etc\vm.args (+sbwt, +stbt, -stdlib restricted_shell,
:: -cache_boot_paths, -mnesia dump_log_*, ...) have to be merged in, or the
:: node boots with VM defaults. Every uncommented line in etc\vm.args is a
:: flag the schema does not also emit, so plain concatenation is enough
:: here - no key appears in both files.
@copy /y "%etc_dir%\vm.args" "%merged_args%" >nul
@echo.>>"%merged_args%"
@type "%generated_args%" >>"%merged_args%"
@echo.>>"%merged_args%"
:: Elixir consolidated protocols sit next to the boot file; without this the
:: release falls back to the unconsolidated ones. Forward slashes so the path
:: survives the args file parser.
@set "fwd_rel_dir=%rel_dir:\=/%"
@echo -pa "%fwd_rel_dir%/consolidated">>"%merged_args%"
:: write the node type and node name in to vm args file
@echo %node_type% %node_name%>>"%merged_args%"
@set generated_config_args=-config "%data_dir%\configs\app.%now_time%.config" -args_file "%merged_args%"
@goto :eof

:: Write the erl.ini file
:write_ini
@set "erl_ini=%erts_dir%\bin\erl.ini"
@set converted_bindir=%bindir:\=\\%
@set converted_rootdir=%rootdir:\=\\%
@echo [erlang] > "%erl_ini%"
@echo Bindir=%converted_bindir% >> "%erl_ini%"
@echo Progname=%progname% >> "%erl_ini%"
@echo Rootdir=%converted_rootdir% >> "%erl_ini%"
@goto :eof

:: Display usage information
:usage
@echo usage: %~n0 ^(install^|uninstall^|start^|stop^|restart^|console^|ping^|ctl^|list^|remote_console^|attach^)
@goto :eof

:: Install the release as a Windows service
:: or install the specified version passed as argument
:install
@call :create_mnesia_dir
@call :generate_app_config
:: Install the service
@set args="-boot %boot_file_name% %boot_var% %generated_config_args% -setcookie %node_cookie% -mnesia dir '%mnesia_dir%'"
@set description=EMQX node %node_name% in %rootdir%
@if "" == "%2" (
  %erlsrv% add %service_name% %node_type% "%node_name%" -on restart -c "%description%" ^
           -i "emqx" -w "%rootdir%" -m %erl_exe% -args %args% ^
           -st "init:stop()."
  :: %service_name%, not a hardcoded "emqx": on a host that already runs another
  :: EMQX installation, "emqx" is that service, and this would reconfigure it.
  sc config %service_name% start=delayed-auto
)
@goto :eof

:: Uninstall the Windows service
:uninstall
@%erlsrv% remove %service_name%
@goto :eof

:: Start the Windows service
:start
:: window service?
:: @%erlsrv% start %service_name%
@call :create_mnesia_dir
@call :generate_app_config
@set args=-detached %generated_config_args% -setcookie %node_cookie% -mnesia dir '%mnesia_dir%'
@echo off
cd /d "%rel_root_dir%"
@echo on
:: werl.exe was removed in OTP 26; erl.exe is the only launcher left, and
:: the node is detached anyway (see %args% above).
@start "%rel_name%" %erl_exe% -mode embedded -boot "%boot_file_name%" %boot_var% %args%
@goto :eof

:: Stop the Windows service
:stop
:: window service?
:: @%erlsrv% stop %service_name%
@%escript% %nodetool% %node_type% %node_name% -setcookie %node_cookie% stop
@goto :eof

:: Start a console
:console
@set "EMQX_LOG__CONSOLE_HANDLER__ENABLE=true"
@set "EMQX_LOG__FILE_HANDLERS__DEFAULT__ENABLE=false"
@call :create_mnesia_dir
@call :generate_app_config
@set args=%generated_config_args% -setcookie %node_cookie% -mnesia dir '%mnesia_dir%'
@echo off
cd /d %rel_root_dir%
@echo on
%erl_exe% -mode embedded -boot "%boot_file_name%" %boot_var% %args%
@goto :eof

:: Ping the running node
:ping
@%escript% %nodetool% ping %node_type% "%node_name%" -setcookie "%node_cookie%"
@goto :eof

:: ctl to execute management commands
:ctl
@for /f "usebackq tokens=1*" %%i in (`echo %*`) DO @ set params=%%j
@%escript% %nodetool% %node_type% "%node_name%" -setcookie "%node_cookie%" rpc_infinity emqx_ctl run_command %params%
@goto :eof

:: List installed Erlang services
:list
@%erlsrv% list %service_name%
@goto :eof

:: Attach to a running node
:attach
%erl_exe% -hidden -remsh "%node_name%" -boot "%clean_boot_file_name%" %boot_var% "%node_type%" "remsh_%node_name%" -setcookie "%node_cookie%"
@goto :eof
