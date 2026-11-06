@echo off
rem Double-click to start the NPU chat server (OpenVINO). Extra args are passed to the PS script.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-npu.ps1" %*
set "result=%errorlevel%"
pause
exit /b %result%
