@echo off
setlocal
cd /d "%~dp0"
chcp 65001 >nul

set "PYTHON=.venv\Scripts\python.exe"
if not exist "%PYTHON%" set "PYTHON=python"

"%PYTHON%" demo_launcher.py %*
