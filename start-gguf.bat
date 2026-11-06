@echo off
setlocal
rem Drag a GGUF onto this file, or enter its full path. Remaining args go to start-server.
if /i "%~1"=="help" goto help
if /i "%~1"=="-help" goto help
if /i "%~1"=="-h" goto help
if not "%~1"=="" goto withargs
set /p "model=GGUF full path: "
set "model=%model:"=%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-server.ps1" -AutoPort -Model "%model%"
goto done
:withargs
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-server.ps1" -AutoPort -Model %*
goto done
:help
echo Usage: start-gguf.bat "E:\models\model.gguf" [-b iGPU^|Vulkan^|CPU^|CUDA] [-v legacy] [-c 8192]
echo Drag a GGUF onto this file, or run without arguments to enter its path.
echo Automatically tries 200 consecutive ports starting at 28080. Use -p and -pt to change this.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-server.ps1" -Help
:done
set "result=%errorlevel%"
pause
exit /b %result%
