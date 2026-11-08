@echo off
setlocal
rem Double-click to start llama-server on the iGPU (Vulkan). Extra args are passed to the PS script.
rem Dropping a .gguf onto this file starts it with automatic port selection.
set "auto="
if /i "%~x1"==".gguf" set "auto=-AutoPort"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-server.ps1" %auto% %*
set "result=%errorlevel%"
pause
exit /b %result%
