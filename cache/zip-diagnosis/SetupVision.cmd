@echo off
setlocal
cd /d "%~dp0"
echo Setting up this macro's local minimap vision environment.
echo.
if exist ".venv\Scripts\python.exe" goto install
where py >nul 2>nul
if not errorlevel 1 (
    py -3 -m venv ".venv"
    if errorlevel 1 goto failed
    goto install
)
where python >nul 2>nul
if errorlevel 1 (
    echo Python 3 was not found. Install Python 3, then run this file again.
    goto failed
)
python -m venv ".venv"
if errorlevel 1 goto failed
:install
".venv\Scripts\python.exe" -m pip install -r "requirements-vision.txt"
if errorlevel 1 goto failed
".venv\Scripts\python.exe" -I -c "import cv2, numpy, mss; print('Minimap vision dependencies are ready.')"
if errorlevel 1 goto failed
echo.
echo Setup complete. Close and reopen AAPathMacro.ahk.
echo The macro will use this folder's .venv automatically.
pause
exit /b 0
:failed
echo.
echo Setup did not finish. Keep this window's error message for diagnosis.
pause
exit /b 1
