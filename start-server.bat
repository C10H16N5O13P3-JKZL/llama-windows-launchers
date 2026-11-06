@echo off
rem Double-click to start llama-server on the iGPU (Vulkan). Extra args are passed to the PS script.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-server.ps1" %*
set "result=%errorlevel%"
pause
exit /b %result%
