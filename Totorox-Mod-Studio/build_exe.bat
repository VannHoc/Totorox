@echo off
chcp 65001 >nul
setlocal EnableExtensions
pushd "%~dp0"

set "PYTHON_EXE=C:\Users\studi\AppData\Local\Python\pythoncore-3.15-64\python.exe"
if not exist "%PYTHON_EXE%" (
    set "PYTHON_EXE=python"
)

"%PYTHON_EXE%" -c "import sys; print(sys.version)" >nul 2>&1
if errorlevel 1 (
    echo [LOI] Khong tim thay Python.
    popd
    pause
    exit /b 1
)

echo [1/3] Kiem tra thu vien runtime...
"%PYTHON_EXE%" -c "import importlib.util, fastapi, uvicorn, zstandard, cryptography, lz4, tkinter; assert importlib.util.find_spec('multipart') or importlib.util.find_spec('python_multipart')" >nul 2>&1
if errorlevel 1 (
    if exist "..\Totorox-Backend\requirements.txt" (
        "%PYTHON_EXE%" -m pip install -r "..\Totorox-Backend\requirements.txt"
    ) else (
        "%PYTHON_EXE%" -m pip install fastapi uvicorn[standard] python-multipart zstandard cryptography lz4
    )
    if errorlevel 1 (
        echo [LOI] Cai dat thu vien runtime that bai.
        popd
        pause
        exit /b 1
    )
)

echo [2/3] Kiem tra PyInstaller...
"%PYTHON_EXE%" -m PyInstaller --version >nul 2>&1
if errorlevel 1 (
    echo [INFO] Chua co PyInstaller, dang tu dong cai dat...
    "%PYTHON_EXE%" -m pip install --upgrade pyinstaller
    if errorlevel 1 (
        echo [LOI] Khong the cai dat PyInstaller.
        popd
        pause
        exit /b 1
    )
)

echo [3/3] Dang dong goi TotoroxModStudio.exe bang TotoroxModStudio.spec...
"%PYTHON_EXE%" -m PyInstaller --noconfirm --clean "%~dp0TotoroxModStudio.spec"
if errorlevel 1 (
    echo [LOI] Dong goi PyInstaller that bai!
    popd
    pause
    exit /b 1
)

echo.
echo [THANH CONG] Da dong goi xong tai: "%~dp0dist\TotoroxModStudio\TotoroxModStudio.exe"
popd
exit /b 0
