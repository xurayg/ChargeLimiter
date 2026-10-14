#!/usr/bin/env python3
from pathlib import Path
import subprocess
import tempfile
repo = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='chargelimiter-diagnostics-') as tmp:
    root = Path(tmp)
    binary = root / 'diagnostics-tests'
    subprocess.run([
        'xcrun','--sdk','macosx','clang++','-std=c++11','-fobjc-arc','-framework','Foundation',
        '-I',str(repo/'ChargeLimiter'),
        f'-DCL_DATA_DIRECTORY="{root / "device"}"',f'-DCL_LEGACY_DIRECTORY="{root / "legacy"}"',
        str(repo/'ChargeLimiter/storage.mm'),str(repo/'ChargeLimiter/diagnostics.mm'),
        str(repo/'Tests/diagnostics_tests.mm'),'-o',str(binary),
    ],check=True)
    subprocess.run([str(binary)],check=True)
