"""App version - read from VERSION file."""

from pathlib import Path

_version_file = Path(__file__).parent / "VERSION"
VERSION = _version_file.read_text().strip() if _version_file.exists() else "dev"
