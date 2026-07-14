@echo off
cmd /k ".venv\Scripts\python.exe -m uvicorn app.main:app --reload"
