"""Recent folders persistence."""

import json
import os
from pathlib import Path
from typing import List


CACHE_FILE = os.path.expanduser("~/.cache/raw-viewer/recent_folders.json")
MAX_RECENT = 5


def load_recent_folders() -> List[str]:
    """Load recent folders from cache."""
    try:
        if os.path.exists(CACHE_FILE):
            with open(CACHE_FILE, "r") as f:
                folders = json.load(f)
                # Filter out non-existent folders
                return [f for f in folders if os.path.isdir(f)][:MAX_RECENT]
    except (json.JSONDecodeError, IOError):
        pass
    return []


def add_recent_folder(folder: str) -> List[str]:
    """Add folder to recent list and save."""
    folders = load_recent_folders()

    # Remove if already exists (will re-add at top)
    if folder in folders:
        folders.remove(folder)

    # Add to front
    folders.insert(0, folder)

    # Trim to max
    folders = folders[:MAX_RECENT]

    # Save
    try:
        os.makedirs(os.path.dirname(CACHE_FILE), exist_ok=True)
        with open(CACHE_FILE, "w") as f:
            json.dump(folders, f)
    except IOError:
        pass

    return folders
