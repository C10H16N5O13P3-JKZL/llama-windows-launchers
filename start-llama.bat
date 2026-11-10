@echo off
setlocal
rem Unified entry: double-click, or drop a .gguf here. Asks for model, backend and mode (server/chat).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\start-llama.ps1" -Ask -AutoBackend -AutoPort %*
set "result=%errorlevel%"
pause
exit /b %result%
