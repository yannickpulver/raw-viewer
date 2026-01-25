"""Scan directories for RAW files, sorted by creation date."""

import json
import os
from datetime import datetime
from pathlib import Path
from typing import List, Callable, Optional, Dict, Tuple

import exifread

# Date cache: path -> (mtime, timestamp)
_date_cache: Dict[str, Tuple[float, float]] = {}
_cache_file = Path.home() / ".cache" / "raw-viewer" / "dates.json"


def _load_date_cache():
    """Load date cache from disk."""
    global _date_cache
    try:
        if _cache_file.exists():
            _date_cache = json.loads(_cache_file.read_text())
    except Exception:
        _date_cache = {}


def _save_date_cache():
    """Save date cache to disk."""
    try:
        _cache_file.parent.mkdir(parents=True, exist_ok=True)
        _cache_file.write_text(json.dumps(_date_cache))
    except Exception:
        pass


# Load cache on import
_load_date_cache()

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


def get_creation_time(path: Path, use_cache: bool = True) -> float:
    """Get image creation time from EXIF metadata, with file system fallback."""
    path_str = str(path)
    stat = path.stat()
    mtime = stat.st_mtime

    # Check cache
    if use_cache and path_str in _date_cache:
        cached_mtime, cached_ts = _date_cache[path_str]
        if cached_mtime == mtime:
            return cached_ts

    # Read EXIF
    timestamp = None
    try:
        with open(path, 'rb') as f:
            tags = exifread.process_file(f, stop_tag='DateTimeOriginal', details=False)
            if 'EXIF DateTimeOriginal' in tags:
                dt_str = str(tags['EXIF DateTimeOriginal'])
                dt = datetime.strptime(dt_str, '%Y:%m:%d %H:%M:%S')
                timestamp = dt.timestamp()
    except Exception:
        pass

    # Fallback to file system date
    if timestamp is None:
        timestamp = getattr(stat, 'st_birthtime', mtime)

    # Update cache
    if use_cache:
        _date_cache[path_str] = (mtime, timestamp)

    return timestamp


def scan_folder(folder: str | Path, progress_callback: Optional[Callable[[int, int], None]] = None) -> List[Path]:
    """Recursively scan folder for RAW files, sorted by creation date.

    Args:
        folder: Path to scan
        progress_callback: Optional callback(current, total) for progress updates
    """
    folder = Path(folder)
    if not folder.is_dir():
        raise ValueError(f"Not a directory: {folder}")

    # Phase 1: Find all RAW files (fast)
    raw_files = []
    for root, _, files in os.walk(folder):
        for f in files:
            path = Path(root) / f
            if is_raw_file(path):
                raw_files.append(path)

    if not raw_files:
        return raw_files

    # Phase 2: Read EXIF dates with progress (slow if not cached)
    total = len(raw_files)
    dates = []
    for i, path in enumerate(raw_files):
        dates.append(get_creation_time(path))
        if progress_callback and (i % 5 == 0 or i == total - 1):
            progress_callback(i + 1, total)

    # Save cache
    _save_date_cache()

    # Sort by creation time (oldest first)
    sorted_files = [f for _, f in sorted(zip(dates, raw_files))]
    return sorted_files
