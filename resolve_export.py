"""Export media with ratings to DaVinci Resolve via scripting API."""

import sys
import os
import subprocess
import time
from pathlib import Path
from typing import List, Dict, Optional, Callable

from rating import read_rating

# Rating -> clip color mapping
RATING_COLORS = {
    1: "Blue",
    2: "Teal",
    3: "Yellow",
    4: "Orange",
    5: "Green",
}

RATING_KEYWORDS = {
    1: "1star",
    2: "2stars",
    3: "3stars",
    4: "4stars",
    5: "5stars,keeper",
}


def _get_resolve_api_paths() -> Optional[str]:
    """Return the Resolve scripting modules path if it exists."""
    candidates = [
        "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting/Modules/",
    ]
    for p in candidates:
        if os.path.isdir(p):
            return p
    return None


def _get_resolve_lib_path() -> Optional[str]:
    """Return the Resolve native library path."""
    candidates = [
        "/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Libraries/Fusion/fusionscript.so",
    ]
    for p in candidates:
        if os.path.isfile(p):
            return p
    return None


def is_resolve_installed() -> bool:
    """Check if DaVinci Resolve is installed."""
    return _get_resolve_api_paths() is not None and _get_resolve_lib_path() is not None


def _connect_to_resolve():
    """Connect to running Resolve instance. Returns resolve object or None."""
    modules_path = _get_resolve_api_paths()
    lib_path = _get_resolve_lib_path()
    if not modules_path or not lib_path:
        return None

    os.environ["RESOLVE_SCRIPT_API"] = str(Path(modules_path).parent.parent)
    os.environ["RESOLVE_SCRIPT_LIB"] = lib_path
    if modules_path not in sys.path:
        sys.path.insert(0, modules_path)

    try:
        import DaVinciResolveScript as dvr_script
        return dvr_script.scriptapp("Resolve")
    except Exception:
        return None


def _launch_resolve() -> bool:
    """Launch DaVinci Resolve if not running."""
    app_path = "/Applications/DaVinci Resolve/DaVinci Resolve.app"
    if not os.path.isdir(app_path):
        return False
    subprocess.Popen(["open", "-a", "DaVinci Resolve"])
    return True


def export_to_resolve(
    files: List[Path],
    ratings: Dict[int, int],
    all_files: List[Path],
    folder_name: str,
    on_status: Optional[Callable[[str], None]] = None,
) -> tuple[bool, str]:
    """
    Export files with ratings to DaVinci Resolve.

    Returns (success, message).
    """
    def status(msg: str):
        if on_status:
            on_status(msg)

    if not is_resolve_installed():
        return False, "DaVinci Resolve not found.\nRequires Resolve Studio (paid) for scripting."

    # Try to connect
    status("Connecting to DaVinci Resolve...")
    resolve = _connect_to_resolve()

    if not resolve:
        # Try launching Resolve
        status("Launching DaVinci Resolve...")
        if not _launch_resolve():
            return False, "Could not launch DaVinci Resolve."

        # Wait for Resolve to start (up to 30s)
        for i in range(30):
            time.sleep(1)
            status(f"Waiting for Resolve to start... ({i + 1}s)")
            resolve = _connect_to_resolve()
            if resolve:
                break

        if not resolve:
            return False, "Could not connect to DaVinci Resolve.\nMake sure Resolve Studio is running."

    # Create project
    status("Creating project...")
    pm = resolve.GetProjectManager()
    if not pm:
        return False, "Could not access Project Manager."

    project_name = f"RV - {folder_name}"
    project = pm.CreateProject(project_name)
    if not project:
        # Project might already exist — try loading it
        project = pm.LoadProject(project_name)
        if not project:
            return False, f"Could not create or load project '{project_name}'."

    # Get media pool
    media_pool = project.GetMediaPool()
    root_folder = media_pool.GetRootFolder()

    # Import all files
    file_paths = [str(f) for f in files]
    status(f"Importing {len(file_paths)} files...")
    clips = media_pool.ImportMedia(file_paths)

    if not clips:
        return False, "No files were imported. Check file formats."

    status(f"Setting metadata on {len(clips)} clips...")

    # Build filename -> rating lookup
    file_ratings: Dict[str, int] = {}
    for f in files:
        idx = all_files.index(f) if f in all_files else -1
        if idx >= 0:
            rating = ratings.get(idx, 0)
        else:
            rating = read_rating(f) or 0
        if rating > 0:
            file_ratings[f.name] = rating

    # Set metadata on each clip
    rated_count = 0
    for clip in clips:
        clip_name = clip.GetName()
        # Match by filename
        rating = file_ratings.get(clip_name, 0)

        if rating > 0:
            rated_count += 1
            # Set clip color based on rating
            color = RATING_COLORS.get(rating, "")
            if color:
                clip.SetClipColor(color)

            # Set keywords and description
            keywords = RATING_KEYWORDS.get(rating, "")
            clip.SetMetadata({
                "Keywords": keywords,
                "Comments": f"Rating: {rating}/5",
                "Description": f"{'★' * rating}{'☆' * (5 - rating)}",
            })

            # Set "Good Take" for 4+ stars
            if rating >= 4:
                clip.SetMetadata("Good Take", "true")

    # Save
    pm.SaveProject()
    status("")

    return True, (
        f"Exported to Resolve project '{project_name}'\n"
        f"{len(clips)} clips imported, {rated_count} with ratings"
    )
