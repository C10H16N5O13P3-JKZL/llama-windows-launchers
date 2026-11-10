@echo off
setlocal
rem Server on Vulkan. Usage: start-server.bat -m "E:\models\model.gguf" (or -h for help).
rem Dropping a .gguf onto this file starts it with automatic port selection.
set "auto="
if /i "%~x1"==".gguf" set "auto=-AutoPort"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\start-llama.ps1" %auto% %*
set "result=%errorlevel%"
pause
exit /b %result%
