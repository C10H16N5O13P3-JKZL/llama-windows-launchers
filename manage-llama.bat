@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0manage-llama.ps1" %*
set "result=%errorlevel%"
pause
exit /b %result%
