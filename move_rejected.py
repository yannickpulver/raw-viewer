"""Move rejected files (rating -1) and their same-stem siblings to a _rejected folder."""

import shutil
from pathlib import Path
from typing import List, Tuple

REJECTED_DIR_NAME = "_rejected"


def find_siblings(file: Path) -> List[Path]:
    """Same-stem files in the same directory (RAW/JPG pairs, .xmp sidecars)."""
    stem = file.stem.lower()
    return [
        c for c in file.parent.iterdir()
        if c.is_file() and c != file and c.stem.lower() == stem
    ]


def collect_move_set(rejected: List[Path]) -> List[Path]:
    """Rejected files plus their siblings, deduplicated, order-preserving."""
    seen = set()
    result = []
    for f in rejected:
        for path in [f, *find_siblings(f)]:
            if path not in seen:
                seen.add(path)
                result.append(path)
    return result


def move_to_rejected(files: List[Path], root: Path) -> Tuple[int, str]:
    """Move files into root/_rejected/, preserving relative subpaths.

    Returns (moved_count, error). Stops on the first error; error is "" on success.
    """
    moved = 0
    for f in files:
        try:
            rel = f.relative_to(root)
        except ValueError:
            rel = Path(f.name)
        dest = root / REJECTED_DIR_NAME / rel
        try:
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(f), str(dest))
            moved += 1
        except OSError as e:
            return moved, f"{f.name}: {e}"
    return moved, ""
