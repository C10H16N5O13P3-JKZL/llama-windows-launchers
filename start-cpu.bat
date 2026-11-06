@echo off
rem Usage: start-cpu.bat -m "E:\models\model.gguf" (or -h for help).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-server.ps1" -Backend CPU %*
set "result=%errorlevel%"
pause
exit /b %result%
