@echo off
setlocal
rem Intel NPU with model aliases (lfm2.5, qwen3-8b) and OpenVINO GenAI. Args go to tools\start-npu.ps1.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\start-npu.ps1" %*
set "result=%errorlevel%"
pause
exit /b %result%
