@echo off
chcp 65001 >nul
setlocal EnableExtensions
pushd "%~dp0"

set "PYTHON_EXE=C:\Users\studi\AppData\Local\Python\pythoncore-3.15-64\python.exe"
if not exist "%PYTHON_EXE%" (
    set "PYTHON_EXE=python"
)

"%PYTHON_EXE%" -c "import sys; print(sys.executable)" >nul 2>&1
if errorlevel 1 (
    echo [LOI] Khong tim thay Python 3.x. Vui long cai dat Python va thu lai.
    popd
    pause
    exit /b 1
)

echo [Totorox Mod Studio 3.0] Kiem tra thu vien Python...
"%PYTHON_EXE%" -c "import importlib.util, fastapi, uvicorn, zstandard, cryptography, lz4, tkinter; assert importlib.util.find_spec('multipart') or importlib.util.find_spec('python_multipart')" >nul 2>&1
if errorlevel 1 (
    echo [Totorox Mod Studio 3.0] Dang cai dat cac thu vien con thieu tu requirements.txt...
    if exist "..\Totorox-Backend\requirements.txt" (
        "%PYTHON_EXE%" -m pip install -r "..\Totorox-Backend\requirements.txt"
    ) else (
        "%PYTHON_EXE%" -m pip install fastapi uvicorn[standard] python-multipart zstandard cryptography lz4
    )
    if errorlevel 1 (
        echo [LOI] Cai dat thu vien that bai. Kiem tra ket noi mang hoac pip.
        popd
        pause
        exit /b 1
    )
)

echo [Totorox Mod Studio 3.0] Dang khoi dong may chu cuc bo...
"%PYTHON_EXE%" "%~dp0app.py" %*
set "EXIT_CODE=%ERRORLEVEL%"

popd
if not "%EXIT_CODE%"=="0" pause
exit /b %EXIT_CODE%
