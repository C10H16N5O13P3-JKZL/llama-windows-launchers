@echo off
setlocal
rem No questions: drop a .gguf here. Backend is auto-selected, server mode, automatic port.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\start-llama.ps1" -AutoPort -AutoBackend %*
set "result=%errorlevel%"
pause
exit /b %result%
