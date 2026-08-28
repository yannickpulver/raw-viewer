"""Scan directories for RAW files, sorted by creation date."""

import io
import json
import os
import struct
from collections import Counter
from datetime import datetime
from pathlib import Path
from typing import BinaryIO, Iterator, List, Callable, Optional, Dict, Tuple

import exifread

from move_rejected import REJECTED_DIR_NAME

# Date cache: path -> (mtime, timestamp)
_date_cache: Dict[str, Tuple[float, float]] = {}
_cache_file = Path.home() / ".cache" / "raw-viewer" / "dates_v2.json"


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

JPEG_EXTENSIONS = {'.jpg', '.jpeg'}

VIDEO_EXTENSIONS = {'.mov', '.mp4', '.m4v'}


def is_raw_file(path: Path) -> bool:
    # Skip macOS metadata files (._*)
    if path.name.startswith('._'):
        return False
    return path.suffix.lower() in RAW_EXTENSIONS


def is_jpeg_file(path: Path) -> bool:
    if path.name.startswith('._'):
        return False
    return path.suffix.lower() in JPEG_EXTENSIONS


def is_video_file(path: Path) -> bool:
    if path.name.startswith('._'):
        return False
    return path.suffix.lower() in VIDEO_EXTENSIONS


RAF_MAGIC = b'FUJIFILMCCD-RAW '
CR3_CANON_UUID = bytes.fromhex('85c0b687820f11e08111f4ce462b6a48')
_DATE_KEYS = ('EXIF DateTimeOriginal', 'Image DateTimeOriginal')


def _iter_boxes(f: BinaryIO, start: int, end: int) -> Iterator[Tuple[int, int, bytes]]:
    """Yield (payload_offset, payload_end, type) for ISO-BMFF boxes in [start, end)."""
    pos = start
    while pos + 8 <= end:
        f.seek(pos)
        size, box_type = struct.unpack('>I4s', f.read(8))
        header = 8
        if size == 1:
            size = struct.unpack('>Q', f.read(8))[0]
            header = 16
        elif size == 0:
            size = end - pos
        if size < header:
            return
        yield pos + header, pos + size, box_type
        pos += size


def _find_box(f: BinaryIO, start: int, end: int, wanted: bytes) -> Optional[Tuple[int, int]]:
    for payload, box_end, box_type in _iter_boxes(f, start, end):
        if box_type == wanted:
            return payload, box_end
    return None


def _raf_exif_blob(f: BinaryIO) -> Optional[bytes]:
    """RAF header stores embedded JPEG offset/length at bytes 84-92 (big-endian)."""
    f.seek(0)
    if f.read(16) != RAF_MAGIC:
        return None
    f.seek(84)
    jpeg_offset, jpeg_length = struct.unpack('>II', f.read(8))
    f.seek(jpeg_offset)
    return f.read(jpeg_length)


def _cr3_exif_blob(f: BinaryIO) -> Optional[bytes]:
    """CR3 keeps the ExifIFD as a TIFF blob in moov > uuid(Canon) > CMT2."""
    f.seek(0, os.SEEK_END)
    moov = _find_box(f, 0, f.tell(), b'moov')
    if not moov:
        return None
    for payload, box_end, box_type in _iter_boxes(f, *moov):
        f.seek(payload)
        if box_type != b'uuid' or f.read(16) != CR3_CANON_UUID:
            continue
        cmt2 = _find_box(f, payload + 16, box_end, b'CMT2')
        if not cmt2:
            return None
        f.seek(cmt2[0])
        return f.read(cmt2[1] - cmt2[0])
    return None


_EXIF_BLOB_EXTRACTORS = {'.raf': _raf_exif_blob, '.cr3': _cr3_exif_blob}


def _read_exif_timestamp(path: Path) -> Optional[float]:
    """Return DateTimeOriginal as a POSIX timestamp, or None if unavailable."""
    try:
        with open(path, 'rb') as f:
            extractor = _EXIF_BLOB_EXTRACTORS.get(path.suffix.lower())
            source: BinaryIO = f
            if extractor:
                blob = extractor(f)
                if blob is None:
                    return None
                source = io.BytesIO(blob)
            tags = exifread.process_file(source, stop_tag='DateTimeOriginal', details=False)
            for key in _DATE_KEYS:
                if key in tags:
                    return datetime.strptime(str(tags[key]), '%Y:%m:%d %H:%M:%S').timestamp()
    except Exception:
        pass
    return None


def subfolder_name(path: Path, root: Path) -> str:
    """First-level subfolder of root containing path; root-level files map to root's own name."""
    try:
        rel_parts = path.parent.relative_to(root).parts
    except ValueError:
        rel_parts = (path.parent.name,)
    return rel_parts[0] if rel_parts else root.name


def subfolder_counts(files: List[Path], root: Path) -> List[Tuple[str, int]]:
    """Count files per first-level subfolder of root, sorted by name."""
    return sorted(Counter(subfolder_name(f, root) for f in files).items())


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

    timestamp = _read_exif_timestamp(path)

    # Fallback to file system date
    if timestamp is None:
        timestamp = getattr(stat, 'st_birthtime', mtime)

    # Update cache
    if use_cache:
        _date_cache[path_str] = (mtime, timestamp)

    return timestamp


def _scan_and_sort(
    folder: str | Path,
    file_predicate: Callable[[Path], bool],
    progress_callback: Optional[Callable[[int, int], None]] = None
) -> List[Path]:
    """Recursively scan folder for files matching predicate, sorted by creation date."""
    folder = Path(folder)
    if not folder.is_dir():
        raise ValueError(f"Not a directory: {folder}")

    matched = []
    for root, dirs, files in os.walk(folder):
        dirs[:] = [d for d in dirs if d != REJECTED_DIR_NAME]
        for f in files:
            path = Path(root) / f
            if file_predicate(path):
                matched.append(path)

    if not matched:
        return matched

    total = len(matched)
    dates = []
    for i, path in enumerate(matched):
        dates.append(get_creation_time(path))
        if progress_callback and (i % 5 == 0 or i == total - 1):
            progress_callback(i + 1, total)

    _save_date_cache()
    return [f for _, f in sorted(zip(dates, matched))]


def scan_folder(folder: str | Path, progress_callback: Optional[Callable[[int, int], None]] = None) -> List[Path]:
    """Recursively scan folder for RAW files, sorted by creation date."""
    return _scan_and_sort(folder, is_raw_file, progress_callback)


def scan_folder_jpeg(folder: str | Path, progress_callback: Optional[Callable[[int, int], None]] = None) -> List[Path]:
    """Recursively scan folder for JPEG files, sorted by creation date."""
    return _scan_and_sort(folder, is_jpeg_file, progress_callback)


def scan_folder_video(folder: str | Path, progress_callback: Optional[Callable[[int, int], None]] = None) -> List[Path]:
    """Recursively scan folder for video files, sorted by creation date."""
    return _scan_and_sort(folder, is_video_file, progress_callback)
