@echo off
rem Runs backend tests using the project's virtual environment.

cd /d "%~dp0" || exit /b 1
cmd /k ".venv\Scripts\python.exe -m pytest tests -q -p no:cacheprovider %*"
