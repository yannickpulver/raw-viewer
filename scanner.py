"""Scan directories for RAW files, sorted by creation date."""

import os
from pathlib import Path
from typing import List

RAW_EXTENSIONS = {
    '.cr2', '.cr3', '.nef', '.arw', '.raf', '.orf',
    '.rw2', '.dng', '.pef', '.srw', '.3fr', '.ari',
    '.bay', '.crw', '.dcr', '.erf', '.fff', '.mef',
    '.mrw', '.nrw', '.ptx', '.pxn', '.r3d', '.rwl',
    '.rwz', '.sr2', '.srf', '.x3f'
}


def is_raw_file(path: Path) -> bool:
    # Skip macOS metadata files (._*)
    if path.name.startswith('._'):
        return False
    return path.suffix.lower() in RAW_EXTENSIONS


def get_creation_time(path: Path) -> float:
    """Get file creation time (or modification time as fallback)."""
    stat = path.stat()
    # macOS: st_birthtime, Linux: st_mtime fallback
    return getattr(stat, 'st_birthtime', stat.st_mtime)


def scan_folder(folder: str | Path) -> List[Path]:
    """Recursively scan folder for RAW files, sorted by creation date."""
    folder = Path(folder)
    if not folder.is_dir():
        raise ValueError(f"Not a directory: {folder}")

    raw_files = []
    for root, _, files in os.walk(folder):
        for f in files:
            path = Path(root) / f
            if is_raw_file(path):
                raw_files.append(path)

    # Sort by creation time (oldest first)
    raw_files.sort(key=get_creation_time)
    return raw_files
