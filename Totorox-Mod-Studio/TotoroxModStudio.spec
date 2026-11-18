# -*- mode: python ; coding: utf-8 -*-
import importlib.util
import os
from PyInstaller.utils.hooks import collect_data_files, collect_submodules

STUDIO_DIR = os.path.abspath(SPECPATH)
BACKEND_DIR = os.path.abspath(os.path.join(STUDIO_DIR, "..", "Totorox-Backend"))

datas = [
    (os.path.join(STUDIO_DIR, "studio.html"), "."),
    (os.path.join(STUDIO_DIR, "assets", "bypass_seed.zst"), "assets"),
    (os.path.join(BACKEND_DIR, "aov_zstd_uncompressed.bin"), "."),
    (os.path.join(BACKEND_DIR, "core_processor.py"), "."),
]
datas += collect_data_files("certifi")

hiddenimports = [
    # Studio & Backend modules
    "studio_engine",
    "jtcom",
    "core_processor",
    # FastAPI / Starlette / Pydantic / AnyIO
    "fastapi",
    "starlette",
    "starlette.formparsers",
    "pydantic",
    "pydantic_core",
    "annotated_types",
    "typing_extensions",
    "anyio",
    "anyio._backends",
    "anyio._backends._asyncio",
    # Multipart (python-multipart 0.0.9 exposes `multipart`, >=0.0.12 exposes `python_multipart`)
    *(
        ["multipart", "multipart.multipart", "multipart.decoders", "multipart.exceptions"]
        if importlib.util.find_spec("multipart")
        else []
    ),
    *(
        ["python_multipart", *collect_submodules("python_multipart")]
        if importlib.util.find_spec("python_multipart")
        else []
    ),
    # Uvicorn dynamic factories
    "uvicorn",
    "uvicorn.logging",
    "uvicorn.loops",
    "uvicorn.loops.auto",
    "uvicorn.loops.asyncio",
    "uvicorn.protocols",
    "uvicorn.protocols.http",
    "uvicorn.protocols.http.auto",
    "uvicorn.protocols.http.h11_impl",
    "uvicorn.protocols.http.httptools_impl",
    "uvicorn.protocols.websockets",
    "uvicorn.protocols.websockets.auto",
    "uvicorn.protocols.websockets.websockets_impl",
    "uvicorn.lifespan",
    "uvicorn.lifespan.on",
    "uvicorn.lifespan.off",
    "uvicorn.middleware",
    "uvicorn.middleware.proxy_headers",
    "h11",
    "httptools",
    "websockets",
    "click",
    # Binary / Crypto codecs
    "zstandard",
    "cryptography",
    "cryptography.hazmat.backends.openssl",
    "lz4",
    "lz4.block",
    # Native Windows GUI dialogs
    "tkinter",
    "tkinter.filedialog",
]
hiddenimports += collect_submodules("anyio")
hiddenimports += collect_submodules("cryptography")

excludes = [
    "pytest",
    "playwright",
    "pyee",
    "capstone",
    "reportlab",
    "pypdf",
    "huggingface_hub",
    "hf_xet",
    "uvicorn.workers",
    "uvicorn.loops.uvloop",
    "watchfiles",
    "uvloop",
    "trio",
    "matplotlib",
    "numpy",
    "PyQt5",
    "PyQt6",
    "PySide6",
]

a = Analysis(
    [os.path.join(STUDIO_DIR, "app.py")],
    pathex=[STUDIO_DIR, BACKEND_DIR],
    binaries=[],
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=excludes,
    noarchive=False,
    optimize=0,
)

pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name="TotoroxModStudio",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=True,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)

coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=False,
    upx_exclude=[],
    name="TotoroxModStudio",
)
