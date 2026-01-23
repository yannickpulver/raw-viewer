"""Persistent disk cache for thumbnails."""

from pathlib import Path
from typing import Optional
import hashlib
import os


class ThumbnailCache:
    """File-based thumbnail cache with mtime validation."""

    def __init__(self, cache_dir: Optional[str] = None):
        if cache_dir is None:
            cache_dir = os.path.expanduser("~/.cache/raw-viewer/thumbs")
        self.cache_dir = Path(cache_dir)
        self.cache_dir.mkdir(parents=True, exist_ok=True)

    def _cache_key(self, image_path: Path, size: int) -> str:
        """Generate cache key from path and size."""
        key_str = f"{image_path}:{size}"
        return hashlib.md5(key_str.encode()).hexdigest()

    def _cache_path(self, image_path: Path, size: int) -> Path:
        """Get cache file path."""
        key = self._cache_key(image_path, size)
        return self.cache_dir / f"{key}.jpg"

    def _mtime_path(self, image_path: Path, size: int) -> Path:
        """Get mtime file path."""
        key = self._cache_key(image_path, size)
        return self.cache_dir / f"{key}.mtime"

    def get(self, image_path: Path, size: int) -> Optional[bytes]:
        """Get cached thumbnail bytes, or None if not cached/stale."""
        cache_file = self._cache_path(image_path, size)
        mtime_file = self._mtime_path(image_path, size)

        if not cache_file.exists() or not mtime_file.exists():
            return None

        # Check mtime
        try:
            cached_mtime = float(mtime_file.read_text())
            current_mtime = image_path.stat().st_mtime
            if cached_mtime != current_mtime:
                return None

            return cache_file.read_bytes()
        except (ValueError, OSError):
            return None

    def set(self, image_path: Path, size: int, data: bytes) -> None:
        """Store thumbnail bytes in cache."""
        cache_file = self._cache_path(image_path, size)
        mtime_file = self._mtime_path(image_path, size)

        try:
            current_mtime = image_path.stat().st_mtime
            cache_file.write_bytes(data)
            mtime_file.write_text(str(current_mtime))
        except OSError:
            pass  # Silently fail on write errors

    def invalidate(self, image_path: Path, size: int) -> None:
        """Remove cached thumbnail."""
        cache_file = self._cache_path(image_path, size)
        mtime_file = self._mtime_path(image_path, size)

        try:
            cache_file.unlink(missing_ok=True)
            mtime_file.unlink(missing_ok=True)
        except OSError:
            pass
