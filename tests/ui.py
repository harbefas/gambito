#!/usr/bin/env python3
"""Headless smoke test for the standalone Qt Quick host."""

import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
HOST = Path(os.environ.get("GAMBITO_QT_BIN", ROOT / "target/qt-build/gambito-qt"))
if not HOST.is_file():
    raise SystemExit(f"Qt host not found: {HOST}; build it with CMake first")

env = dict(os.environ)
env["QT_QPA_PLATFORM"] = "offscreen"
env.setdefault("QT_QUICK_BACKEND", "software")
result = subprocess.run(
    ["timeout", "4s", str(HOST)], cwd=ROOT, env=env, text=True, capture_output=True
)
output = result.stdout + result.stderr
if result.returncode not in (0, 124):
    raise AssertionError(output)
for marker in ("TypeError", "ReferenceError", "Failed to load", "QML Error"):
    if marker in output:
        raise AssertionError(output)
print("PASS Qt host: standalone window starts without QML errors")
