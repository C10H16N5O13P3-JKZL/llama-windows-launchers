@echo off
rem Double-click (no arguments) opens the interactive backend menu.
if "%~1"=="" goto menu
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\manage-llama.ps1" %*
set "result=%errorlevel%"
pause
exit /b %result%

:menu
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\manage-llama.ps1" -Interactive
exit /b %errorlevel%
