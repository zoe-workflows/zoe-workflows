@echo off
setlocal
rem Zoe skill wrapper for Windows; mirrors scripts/zoe.sh exactly.
rem   1. resolve one absolute runtime: ZOE_BIN -> ZOE_SRC -> zoe on PATH
rem   2. run `capabilities --check-requirements <skill>\runtime-requirements.json`
rem   3. reject with RUNTIME_INCOMPATIBLE (exit 5) when it does not pass
rem   4. run the user request through the same resolved runtime
rem `--version` and `--which` skip the gate: they are the diagnosis path.
rem Exit codes: 0 success, 5 incompatible runtime, 126 runtime missing.
rem Error documents go to **stdout** (no `1>&2`), the same channel the runtime
rem itself prints to; a host must be able to parse one stream, not merge two.
rem
rem Each branch uses goto instead of a parenthesised block: inside a block cmd.exe
rem expands %ERRORLEVEL% (and every other %VAR%) at parse time, which would report
rem the *previous* value. The same reason keeps :run as a callable label.

rem %%~fI resolves the ".." so diagnostics never show "scripts\..\".
for %%I in ("%~dp0..") do set "SKILL=%%~fI"
set "REQ=%SKILL%\runtime-requirements.json"
rem No pipe characters in HINT: an unescaped "|" inside `echo` becomes a pipe.
rem Forward slashes only: cmd has no JSON escaper, and a backslash inside a JSON
rem string is an illegal escape ("\a") that makes the whole error unparseable.
set "HINT=Fix with one of: pipx install zoe-runtime, pipx upgrade zoe-runtime, ZOE_BIN=C:/abs/zoe.exe, ZOE_SRC=C:/abs/zoe-runtime"
rem Belt and braces: strip double quotes so a host-added path can never break
rem the JSON document either.
set "HINT_JSON=%HINT:"=%"
set "ZOE_HOW="
set "ZOE_PATH="

if defined ZOE_BIN goto use_bin
if defined ZOE_SRC goto use_src
where zoe >nul 2>nul
if not errorlevel 1 goto use_path
echo {"error":{"code":"RUNTIME_NOT_FOUND","message":"zoe runtime not found on this host (this skill ships no runtime)","hint":"%HINT_JSON%"}}
exit /b 126

:use_bin
if not exist "%ZOE_BIN%" goto bad_bin
set "ZOE_HOW=ZOE_BIN"
set "ZOE_PATH=%ZOE_BIN%"
goto diagnostics

:bad_bin
echo {"error":{"code":"RUNTIME_NOT_EXECUTABLE","message":"ZOE_BIN must be a trusted absolute executable path","hint":"%HINT_JSON%"}}
exit /b 126

:use_src
if not exist "%ZOE_SRC%\src\__main__.py" goto bad_src
set "ZOE_HOW=ZOE_SRC"
set "ZOE_PATH=%ZOE_SRC%"
set "PYTHONPATH=%ZOE_SRC%"
goto diagnostics

:bad_src
echo {"error":{"code":"RUNTIME_NOT_FOUND","message":"ZOE_SRC must be the absolute path of a zoe-runtime checkout containing src\\__main__.py","hint":"%HINT_JSON%"}}
exit /b 126

:use_path
for /f "delims=" %%I in ('where zoe') do if not defined ZOE_PATH set "ZOE_PATH=%%I"
set "ZOE_HOW=PATH"
goto diagnostics

:diagnostics
set "SHOW_PATH=%ZOE_PATH:\=/%"
set "SHOW_REQ=%REQ:\=/%"
set "SHOW_SKILL=%SKILL:\=/%"
if /I "%~1"=="--which" goto which
if /I "%~1"=="--version" goto forward

if not exist "%REQ%" goto missing_requirements

rem Keep the gate output: a runtime that cannot run its own preflight is a
rem different problem from one that answers "your version is too old", and
rem reporting both as RUNTIME_INCOMPATIBLE sends the user to the wrong fix.
set "GATE_LOG=%TEMP%\zoe_gate_%RANDOM%%RANDOM%%RANDOM%.log"
call :run capabilities --check-requirements "%REQ%" > "%GATE_LOG%" 2>&1
if not errorlevel 1 goto gate_passed
findstr /C:"Traceback" /C:"No module named" /C:"SyntaxError" /C:"cannot import" "%GATE_LOG%" >nul 2>nul
if not errorlevel 1 goto broken
goto incompatible

:gate_passed
del "%GATE_LOG%" >nul 2>nul
goto forward

:which
echo {"which":"%SHOW_PATH%","source":"%ZOE_HOW%","requirements":"%SHOW_REQ%","skill":"%SHOW_SKILL%"}
exit /b 0

:missing_requirements
echo {"error":{"code":"RUNTIME_REQUIREMENTS_MISSING","message":"packaged skill is missing runtime-requirements.json; reinstall the skill","hint":"%HINT_JSON%"}}
exit /b 126

:incompatible
rem Read the version through a temp file: `for /f` on a quoted executable path
rem breaks as soon as the path contains a space.
set "VFILE=%TEMP%\zoe_version_%RANDOM%%RANDOM%%RANDOM%.txt"
set "VER=unknown"
if /I "%ZOE_HOW%"=="ZOE_SRC" goto version_from_source
"%ZOE_PATH%" --version > "%VFILE%" 2>nul
if exist "%VFILE%" set /p VER=<"%VFILE%"
if exist "%VFILE%" del "%VFILE%" >nul 2>nul
goto incompatible_report

:version_from_source
python -m src --version > "%VFILE%" 2>nul
if exist "%VFILE%" set /p VER=<"%VFILE%"
if exist "%VFILE%" del "%VFILE%" >nul 2>nul

:incompatible_report
rem The version string comes from the runtime itself: normalise separators so a
rem patched build ("0.5.2+local/build") cannot break the JSON.
set "VER_JSON=%VER:\=/%"
set "VER_JSON=%VER_JSON:"=%"
echo {"error":{"code":"RUNTIME_INCOMPATIBLE","message":"zoe runtime at %SHOW_PATH% does not satisfy %SHOW_REQ%","details":{"runtime_version":"%VER_JSON%","source":"%ZOE_HOW%","requirements":"%SHOW_REQ%"},"hint":"%HINT_JSON%"}}
exit /b 5

:broken
rem The runtime itself failed: importing it raised. This is not a version
rem problem, and telling the user to upgrade would waste their time. The gate
rem log is kept (its raw text may contain quotes and newlines, which cannot be
rem embedded in JSON safely) and its path is reported instead.
set "GATE_JSON=%GATE_LOG:\=/%"
echo {"error":{"code":"RUNTIME_BROKEN","message":"zoe runtime at %SHOW_PATH% cannot run its own preflight","details":{"source":"%ZOE_HOW%","gate_log":"%GATE_JSON%"},"hint":"Run it manually: the gate log path in details holds the traceback. Reinstall with pipx install --force zoe-runtime"}}
exit /b 126

:forward
call :run %*
exit /b %ERRORLEVEL%

rem Dispatch shared by the gate and the user request, so they can never diverge
rem onto different binaries.
:run
if /I "%ZOE_HOW%"=="ZOE_SRC" goto run_source
rem `call` and not a bare invocation: when ZOE_BIN points at a .cmd/.bat shim,
rem running it without `call` transfers control and this script never resumes —
rem the gate would be skipped entirely and its output could not be inspected.
call "%ZOE_PATH%" %*
exit /b %ERRORLEVEL%

:run_source
where python >nul 2>nul
if errorlevel 1 goto run_source_py
python -m src %*
exit /b %ERRORLEVEL%

:run_source_py
py -3 -m src %*
exit /b %ERRORLEVEL%
