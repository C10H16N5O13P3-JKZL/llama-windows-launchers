@echo off
setlocal
rem Drag a GGUF onto this file, or double-click to pick or enter a model. All args go to start-server.
if /i "%~1"=="help" goto help
if /i "%~1"=="-help" goto help
if /i "%~1"=="-h" goto help
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-server.ps1" -AutoPort -AutoBackend %*
goto done
:help
echo Usage: start-gguf.bat "E:\models\model.gguf" [-b Auto^|iGPU^|Vulkan^|CPU^|CUDA] [-v legacy] [-c 8192]
echo Drag a GGUF onto this file, or run without arguments to pick or enter a model.
echo Backend defaults to Auto: CUDA with an NVIDIA GPU, else Vulkan, else CPU (installed only).
echo Automatically tries 200 consecutive ports starting at 28080. Use -p and -pt to change this.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-server.ps1" -Help
:done
set "result=%errorlevel%"
pause
exit /b %result%
