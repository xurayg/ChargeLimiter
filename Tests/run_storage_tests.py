#!/usr/bin/env python3
"""Run the production storage code against isolated temporary device/legacy roots."""
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="chargelimiter-storage-") as tmp:
    root = Path(tmp)
    binary = root / "storage-tests"
    subprocess.run([
        "xcrun", "--sdk", "macosx", "clang++", "-std=c++11", "-fobjc-arc",
        "-framework", "Foundation", "-I", str(repo / "ChargeLimiter"),
        f'-DCL_DATA_DIRECTORY="{root / "device"}"',
        f'-DCL_LEGACY_DIRECTORY="{root / "legacy"}"',
        str(repo / "ChargeLimiter/storage.mm"), str(repo / "Tests/storage_tests.mm"),
        "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True)
