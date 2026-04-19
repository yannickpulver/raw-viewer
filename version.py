"""App version - read from VERSION file."""

import sys
from pathlib import Path

if getattr(sys, "frozen", False):
    _base = Path(getattr(sys, "_MEIPASS", Path(sys.executable).parent))
else:
    _base = Path(__file__).parent

_version_file = _base / "VERSION"
VERSION = _version_file.read_text().strip() if _version_file.exists() else "dev"
