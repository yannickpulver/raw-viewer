"""Persistent per-folder shoot selection timer stats."""

import json
import os
from typing import Dict, Optional


STATS_FILE = os.path.expanduser("~/.cache/raw-viewer/shoot_stats.json")


def _load_all() -> Dict[str, dict]:
    try:
        if os.path.exists(STATS_FILE):
            with open(STATS_FILE, "r") as f:
                data = json.load(f)
                if isinstance(data, dict):
                    return data
    except (json.JSONDecodeError, IOError):
        pass
    return {}


def load_stats(folder: str) -> Optional[dict]:
    """Load persisted stats for a folder, or None."""
    data = _load_all()
    entry = data.get(folder)
    if not isinstance(entry, dict):
        return None
    return {
        "elapsed": float(entry.get("elapsed", 0.0)),
        "rated_count": int(entry.get("rated_count", 0)),
        "last_rating_elapsed": entry.get("last_rating_elapsed"),
    }


def save_stats(folder: str, elapsed: float, rated_count: int,
               last_rating_elapsed: Optional[float]) -> None:
    """Persist stats for a folder."""
    data = _load_all()
    data[folder] = {
        "elapsed": float(elapsed),
        "rated_count": int(rated_count),
        "last_rating_elapsed": last_rating_elapsed,
    }
    try:
        os.makedirs(os.path.dirname(STATS_FILE), exist_ok=True)
        with open(STATS_FILE, "w") as f:
            json.dump(data, f)
    except IOError:
        pass
