# Perf + Core Culling Round 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove felt latency during rapid keyboard culling and make a cull executable end-to-end (reject → filter → move rejected).

**Architecture:** PyQt6 single-window app. `viewer.py` holds `ImageViewer(QMainWindow)`. New pure-Python modules (`pixmap_cache.py`, `move_rejected.py`) carry the unit-testable logic; viewer changes are wired manually and verified by running the app.

**Tech Stack:** Python 3, PyQt6, rawpy, Pillow, pytest (new dev dep).

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-03-perf-culling-round1-design.md`
- Commit messages: actual change description only. NEVER add Claude attribution or Co-Authored-By lines.
- macOS-only app; run manually with `python main.py "/path/to/photos"`.
- No type-annotation regressions; keep existing code style (double quotes/single quotes as found nearby).
- Rating range is now **−1..5** everywhere (−1 = rejected, Lightroom-compatible `xmp:Rating="-1"`).
- Preview long-edge cap: **2560 px**. Memory cache cap: **1.5 GB** (`1_500_000_000` bytes).
- Rejected folder name: `_rejected` (constant `REJECTED_DIR_NAME`).

---

### Task 1: Reject support in rating.py (−1)

**Files:**
- Modify: `rating.py:24-79`
- Create: `requirements-dev.txt`
- Test: `tests/test_rating.py`

**Interfaces:**
- Produces: `read_rating(path) -> Optional[int]` now returns −1..5. `write_rating(path, rating) -> bool` clamps to −1..5 and serializes `xmp:Rating="-1"`.

- [ ] **Step 1: Create dev requirements and tests dir**

Create `requirements-dev.txt`:
```
pytest
```

Run: `pip install -r requirements-dev.txt && mkdir -p tests && touch tests/__init__.py`

- [ ] **Step 2: Write the failing tests**

Create `tests/test_rating.py`:
```python
from pathlib import Path

from rating import read_rating, write_rating


def test_write_read_roundtrip_stars(tmp_path: Path):
    raw = tmp_path / "IMG_0001.cr3"
    raw.touch()
    for r in range(0, 6):
        assert write_rating(raw, r)
        assert read_rating(raw) == r


def test_write_read_reject(tmp_path: Path):
    raw = tmp_path / "IMG_0002.cr3"
    raw.touch()
    assert write_rating(raw, -1)
    assert read_rating(raw) == -1
    content = (tmp_path / "IMG_0002.xmp").read_text()
    assert 'xmp:Rating="-1"' in content


def test_update_existing_sidecar_star_to_reject_and_back(tmp_path: Path):
    raw = tmp_path / "IMG_0003.cr3"
    raw.touch()
    write_rating(raw, 3)
    write_rating(raw, -1)
    assert read_rating(raw) == -1
    write_rating(raw, 4)
    assert read_rating(raw) == 4


def test_clamping(tmp_path: Path):
    raw = tmp_path / "IMG_0004.cr3"
    raw.touch()
    write_rating(raw, -5)
    assert read_rating(raw) == -1
    write_rating(raw, 9)
    assert read_rating(raw) == 5
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `python -m pytest tests/test_rating.py -v`
Expected: FAIL — `test_write_read_reject`, `test_update_existing_sidecar_star_to_reject_and_back`, `test_clamping` fail (reject reads as None / clamp to 0).

- [ ] **Step 4: Implement −1 support in rating.py**

In `read_rating` (rating.py:33), change the regex:
```python
        match = re.search(r'xmp:Rating=["\'](-?\d)["\']', content)
```

In `write_rating`:
- Line 44: `rating = max(-1, min(5, rating))  # Clamp to -1..5 (-1 = rejected)`
- Line 52: `if re.search(r'xmp:Rating=["\']?-?\d["\']?', content):`
- Lines 54-58:
```python
                content = re.sub(
                    r'(xmp:Rating=["\']?)-?\d(["\']?)',
                    f'\\g<1>{rating}\\g<2>',
                    content
                )
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `python -m pytest tests/test_rating.py -v`
Expected: 4 PASS

- [ ] **Step 6: Commit**

```bash
git add rating.py tests/ requirements-dev.txt
git commit -m "Support -1 (reject) rating in XMP sidecars"
```

---

### Task 2: Byte-capped LRU cache module

**Files:**
- Create: `pixmap_cache.py`
- Test: `tests/test_pixmap_cache.py`

**Interfaces:**
- Produces: `LruByteCache(max_bytes: int)` with `get(key) -> Optional[Any]`, `put(key, value, cost: int)`, `key in cache`, `clear()`. Qt-free (cost is passed in by the caller).

- [ ] **Step 1: Write the failing tests**

Create `tests/test_pixmap_cache.py`:
```python
from pixmap_cache import LruByteCache


def test_put_get_and_contains():
    c = LruByteCache(max_bytes=100)
    c.put("a", "va", 10)
    assert c.get("a") == "va"
    assert "a" in c
    assert c.get("missing") is None
    assert "missing" not in c


def test_evicts_least_recently_used_when_over_cap():
    c = LruByteCache(max_bytes=100)
    c.put("a", "va", 40)
    c.put("b", "vb", 40)
    c.put("c", "vc", 40)  # total 120 > 100 -> evict "a"
    assert "a" not in c
    assert "b" in c and "c" in c


def test_get_refreshes_recency():
    c = LruByteCache(max_bytes=100)
    c.put("a", "va", 40)
    c.put("b", "vb", 40)
    c.get("a")            # a becomes most recent
    c.put("c", "vc", 40)  # evicts "b", not "a"
    assert "a" in c
    assert "b" not in c


def test_reput_updates_cost():
    c = LruByteCache(max_bytes=100)
    c.put("a", "va", 90)
    c.put("a", "va2", 10)
    c.put("b", "vb", 80)  # fits: 10 + 80 <= 100
    assert c.get("a") == "va2"
    assert "b" in c


def test_never_evicts_last_item():
    c = LruByteCache(max_bytes=100)
    c.put("huge", "v", 500)  # over cap but only item stays
    assert "huge" in c


def test_clear():
    c = LruByteCache(max_bytes=100)
    c.put("a", "va", 10)
    c.clear()
    assert "a" not in c
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python -m pytest tests/test_pixmap_cache.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'pixmap_cache'`

- [ ] **Step 3: Implement**

Create `pixmap_cache.py`:
```python
"""Byte-capped LRU cache for preview pixmaps."""

from collections import OrderedDict
from typing import Any, Hashable, Optional, Tuple


class LruByteCache:
    """LRU cache bounded by total cost in bytes. Keeps at least one entry."""

    def __init__(self, max_bytes: int):
        self.max_bytes = max_bytes
        self._items: "OrderedDict[Hashable, Tuple[Any, int]]" = OrderedDict()
        self._total = 0

    def get(self, key: Hashable) -> Optional[Any]:
        item = self._items.get(key)
        if item is None:
            return None
        self._items.move_to_end(key)
        return item[0]

    def put(self, key: Hashable, value: Any, cost: int):
        if key in self._items:
            self._total -= self._items[key][1]
            del self._items[key]
        self._items[key] = (value, cost)
        self._total += cost
        while self._total > self.max_bytes and len(self._items) > 1:
            _, (_, evicted_cost) = self._items.popitem(last=False)
            self._total -= evicted_cost

    def __contains__(self, key: Hashable) -> bool:
        return key in self._items

    def clear(self):
        self._items.clear()
        self._total = 0
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python -m pytest tests/test_pixmap_cache.py -v`
Expected: 6 PASS

- [ ] **Step 5: Commit**

```bash
git add pixmap_cache.py tests/test_pixmap_cache.py
git commit -m "Add byte-capped LRU cache module"
```

---

### Task 3: move_rejected module + scanner skips _rejected

**Files:**
- Create: `move_rejected.py`
- Modify: `scanner.py:116`
- Test: `tests/test_move_rejected.py`

**Interfaces:**
- Produces: `REJECTED_DIR_NAME = "_rejected"`; `collect_move_set(rejected: List[Path]) -> List[Path]` (rejected files + same-stem siblings, deduped); `move_to_rejected(files: List[Path], root: Path) -> Tuple[int, str]` (moved count, error message or "" — stops on first error).

- [ ] **Step 1: Write the failing tests**

Create `tests/test_move_rejected.py`:
```python
from pathlib import Path

from move_rejected import collect_move_set, find_siblings, move_to_rejected
from scanner import scan_folder


def make(p: Path):
    p.parent.mkdir(parents=True, exist_ok=True)
    p.touch()
    return p


def test_find_siblings_same_stem(tmp_path: Path):
    raw = make(tmp_path / "IMG_0001.CR3")
    jpg = make(tmp_path / "IMG_0001.jpg")
    xmp = make(tmp_path / "IMG_0001.xmp")
    make(tmp_path / "IMG_0002.CR3")  # different stem, excluded
    siblings = find_siblings(raw)
    assert set(siblings) == {jpg, xmp}


def test_collect_move_set_dedupes_pairs(tmp_path: Path):
    raw = make(tmp_path / "a.cr3")
    jpg = make(tmp_path / "a.jpg")
    result = collect_move_set([raw, jpg])
    assert sorted(result, key=str) == sorted([raw, jpg], key=str)


def test_move_preserves_subpath(tmp_path: Path):
    f = make(tmp_path / "day1" / "IMG_0001.cr3")
    moved, error = move_to_rejected([f], tmp_path)
    assert moved == 1 and error == ""
    assert not f.exists()
    assert (tmp_path / "_rejected" / "day1" / "IMG_0001.cr3").exists()


def test_move_stops_on_missing_file(tmp_path: Path):
    a = make(tmp_path / "a.cr3")
    ghost = tmp_path / "ghost.cr3"  # never created
    b = make(tmp_path / "b.cr3")
    moved, error = move_to_rejected([a, ghost, b], tmp_path)
    assert moved == 1
    assert "ghost.cr3" in error
    assert b.exists()  # untouched after error


def test_scanner_skips_rejected_dir(tmp_path: Path):
    make(tmp_path / "keep.cr3")
    make(tmp_path / "_rejected" / "gone.cr3")
    files = scan_folder(tmp_path)
    assert [f.name for f in files] == ["keep.cr3"]
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python -m pytest tests/test_move_rejected.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'move_rejected'`

- [ ] **Step 3: Implement move_rejected.py**

```python
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
```

- [ ] **Step 4: Make scanner skip _rejected**

In `scanner.py`, `_scan_and_sort` (line 116), change the walk loop to prune:
```python
    for root, dirs, files in os.walk(folder):
        dirs[:] = [d for d in dirs if d != "_rejected"]
        for f in files:
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `python -m pytest tests/ -v`
Expected: all PASS (note: `test_move_stops_on_missing_file` relies on `shutil.move` raising `FileNotFoundError`, a subclass of `OSError`)

- [ ] **Step 6: Commit**

```bash
git add move_rejected.py scanner.py tests/test_move_rejected.py
git commit -m "Add move-rejected module, skip _rejected dir when scanning"
```

---

### Task 4: path_index dict — kill O(n) lookups

**Files:**
- Modify: `viewer.py` (init ~L432, `_on_thumb_loaded` L945, `_preload_thumb` L986, `_load_current` L1139, `_update_overlay` L1178, R-key handler L1942, `_set_rating` L1998, `_load_mode_state` L1456, `_on_folder_scanned` L1353, `_close_folder` L1421)
- Modify: `resolve_export.py:154-160`

**Interfaces:**
- Produces: `self.path_index: Dict[Path, int]` mapping file → index in `self.all_files`; `self._rebuild_path_index()`.

- [ ] **Step 1: Add path_index and rebuild helper**

In `ImageViewer.__init__` after `self.all_files = self.files` (L432):
```python
        self.path_index: Dict[Path, int] = {f: i for i, f in enumerate(self.all_files)}
```

Add method (place near `_load_mode_state`):
```python
    def _rebuild_path_index(self):
        self.path_index = {f: i for i, f in enumerate(self.all_files)}
```

Call `self._rebuild_path_index()`:
- in `_on_folder_scanned` right after `self.all_files = files` (L1353)
- at the end of `_load_mode_state` (after L1464)
- in `_close_folder` after `self.all_files = []` (L1421)

- [ ] **Step 2: Replace the six lookup sites**

Replace `self.all_files.index(X)` with `self.path_index[X]` at:
- `_on_thumb_loaded` L945: `orig_idx = self.path_index[self.files[idx]]`
- `_preload_thumb` L986: `orig_idx = self.path_index[self.files[idx]]`
- `_load_current` L1139: `orig_idx = self.path_index[self.files[self.index]]`
- `_update_overlay` L1178: `orig_idx = self.path_index[current_file]`
- R-key handler L1942: `orig_idx = self.path_index[self.files[i]]`
- `_set_rating` L1998: `orig_idx = self.path_index[self.files[self.index]]`

In `_preload_thumb` and `_on_thumb_loaded` (worker-signal paths where files may have been swapped mid-flight), use `.get()` and bail:
```python
            orig_idx = self.path_index.get(self.files[idx])
            if orig_idx is None:
                return
```
(In `_preload_thumb` the `return` is inside the try; the `finally` block still clears `thumb_loading`.)

- [ ] **Step 3: Fix resolve_export O(n²)**

In `resolve_export.py` replace lines 154-160:
```python
    file_ratings: Dict[str, int] = {}
    index_of = {p: i for i, p in enumerate(all_files)}
    for f in files:
        idx = index_of.get(f, -1)
```
(rest of the block unchanged)

- [ ] **Step 4: Manual verification**

Run: `python main.py "/path/to/large/shoot"` (1,000+ files if available).
Check: navigation with arrow keys is instant; ratings apply; R jumps to last rated; filmstrip badges correct; ⌘D Resolve export still builds ratings (if Resolve installed, else skip).

Run: `python -m pytest tests/ -v` → all PASS.

- [ ] **Step 5: Commit**

```bash
git add viewer.py resolve_export.py
git commit -m "Replace O(n) all_files.index scans with path->index dict"
```

---

### Task 5: Async rating writes

**Files:**
- Modify: `viewer.py` (`PreloadSignals` L32, `__init__` executors L457-460, `_set_rating` L1994-2004, `closeEvent` L2076)

**Interfaces:**
- Produces: `self.rating_executor: ThreadPoolExecutor` (1 worker); `self._write_rating_task(path: Path, rating: int, mode: str)`; signal `PreloadSignals.rating_write_failed = pyqtSignal(str)`.

- [ ] **Step 1: Add signal and executor**

In `PreloadSignals` (viewer.py:32), add:
```python
    rating_write_failed = pyqtSignal(str)  # filename
```

In `__init__` next to the other executors (L460):
```python
        self.rating_executor = ThreadPoolExecutor(max_workers=1)  # XMP sidecar writes
```

Connect next to the other signal connections (L452-456):
```python
        self.preload_signals.rating_write_failed.connect(
            lambda name: self._show_snackbar(f"Failed to save rating for {name}", 4000))
```

- [ ] **Step 2: Move writes off the UI thread**

In `_set_rating`, replace lines 2002-2004:
```python
        write_rating(current_file, rating)
        if self.view_mode in ("jpeg", "video"):
            set_green_tag(current_file, rating > 0)
```
with:
```python
        self.rating_executor.submit(self._write_rating_task, current_file, rating, self.view_mode)
```

Add method:
```python
    def _write_rating_task(self, path: Path, rating: int, mode: str):
        """Runs on rating_executor. Single worker keeps writes ordered per path."""
        ok = write_rating(path, rating)
        if mode in ("jpeg", "video"):
            set_green_tag(path, rating > 0)
        if not ok:
            self.preload_signals.rating_write_failed.emit(path.name)
```

- [ ] **Step 3: Flush on close**

In `closeEvent` (L2083), before the other shutdowns:
```python
        self.rating_executor.shutdown(wait=True)
```

- [ ] **Step 4: Manual verification**

Run: `python main.py "/path/to/shoot"`.
Check: hold `3` with key autorepeat across 30+ images — no stutter, no beachball. Quit immediately after rating; reopen — last rating persisted (sidecar flushed). Rate a JPG in JPG mode — green Finder tag appears.

- [ ] **Step 5: Commit**

```bash
git add viewer.py
git commit -m "Write XMP ratings asynchronously off the UI thread"
```

---

### Task 6: LRU cache integration + RAW preview size cap

**Files:**
- Modify: `viewer.py` (`__init__` L427-448, `_on_preloaded` L931, `_preload_nearby` L1025-1034, `_trim_cache` L1103 (delete), `_load_current` L1122, `_load_folder` L1311-1312, `_close_folder` L1414/1426)
- Modify: `preview.py:109-114` (`extract_preview`)

**Interfaces:**
- Consumes: `LruByteCache` from Task 2.
- Produces: `self.cache: LruByteCache` keyed by `Path` (was `Dict[int, QPixmap]` keyed by filtered index — Path keys also fix stale-index display after filter changes); `self._empty_mode_state() -> dict`; `ImageViewer.CACHE_MAX_BYTES = 1_500_000_000`.

- [ ] **Step 1: Swap the cache type**

In `viewer.py` imports, add:
```python
from pixmap_cache import LruByteCache
```

Replace class constant (L427): `CACHE_SIZE = 15` → `CACHE_MAX_BYTES = 1_500_000_000  # ~1.5 GB of decoded previews`

In `__init__` (L434): `self.cache: Dict[int, QPixmap] = {}` →
```python
        self.cache = LruByteCache(self.CACHE_MAX_BYTES)
```

Add helper and use it for the three mode-state templates:
```python
    def _empty_mode_state(self) -> dict:
        return {"files": [], "all_files": [], "index": 0,
                "cache": LruByteCache(self.CACHE_MAX_BYTES),
                "ratings": {}, "min_rating_filter": 0}
```
- `__init__` L444-448: `self._mode_state = {m: self._empty_mode_state() for m in ("raw", "jpeg", "video")}`
- `_load_folder` scan() L1311-1312:
```python
            self._mode_state["jpeg"] = {**self._empty_mode_state(), "files": jpeg_files, "all_files": jpeg_files}
            self._mode_state["video"] = {**self._empty_mode_state(), "files": video_files, "all_files": video_files}
```
(NB: `_empty_mode_state` builds a fresh `LruByteCache`; safe to call from the scan thread.)
- `_close_folder` L1426: `self._mode_state[mode] = self._empty_mode_state()`

- [ ] **Step 2: Re-key cache accesses by Path**

- `_on_preloaded` (L931-940) — keep the display and thumbnail-generation logic, only re-key the cache:
```python
    def _on_preloaded(self, idx: int, pixmap: QPixmap):
        with self.lock:
            if 0 <= idx < len(self.files) and pixmap:
                cost = pixmap.width() * pixmap.height() * 4
                self.cache.put(self.files[idx], pixmap, cost)
            self.loading.discard(idx)
        if idx == self.index and pixmap:
            self._display(pixmap)
        # Also create thumbnail
        if pixmap and idx not in self.filmstrip.thumbnails:
            thumb = pixmap.scaled(80, 80, Qt.AspectRatioMode.KeepAspectRatio, Qt.TransformationMode.FastTransformation)
            self.filmstrip.set_thumbnail(idx, thumb)
```
- `_preload_nearby` (L1031): `if 0 <= idx < len(self.files) and self.files[idx] not in self.cache and idx not in self.loading:`
- Delete `_trim_cache` (L1103-1107) and its call in `_preload_nearby` (L1034).
- `_load_current` (L1122-1123):
```python
            with self.lock:
                cached = self.cache.get(self.files[self.index])
```
- `self.cache.clear()` calls in `_on_folder_scanned` (L1344) and `_close_folder` (L1414) keep working unchanged.

- [ ] **Step 3: Cap RAW preview size**

In `preview.py`, `extract_preview`, after the orientation block (L110-112) and before `return pixmap`:
```python
            if pixmap and max(pixmap.width(), pixmap.height()) > 2560:
                pixmap = pixmap.scaled(
                    2560, 2560,
                    Qt.AspectRatioMode.KeepAspectRatio,
                    Qt.TransformationMode.SmoothTransformation,
                )
```

- [ ] **Step 4: Run tests + manual verification**

Run: `python -m pytest tests/ -v` → all PASS.

Run: `python main.py "/path/to/shoot"`.
Check: navigate forward 30 images, then back 30 — backward navigation is instant (no re-decode flash of the 80px placeholder). Apply a ≥3★ filter, navigate — correct images shown (Path keys). Watch memory in Activity Monitor — plateaus instead of monotonic growth; zoom to 100% still acceptably sharp (2560px cap).

- [ ] **Step 5: Commit**

```bash
git add viewer.py preview.py
git commit -m "Byte-capped LRU preview cache keyed by path, cap RAW previews at 2560px"
```

---

### Task 7: Reject flag (X key, badge, filter bucket)

**Files:**
- Modify: `viewer.py` (`FilmstripContent.paintEvent` L295-303, filter buttons L811, `_on_filter_button` L1267, `_update_filter_buttons` L1271, `_apply_filter` L1227, `_update_overlay` L1166/1180/1187, `keyPressEvent` L1897, `_set_rating` shoot-stats block L2009-2016, help text ~L632)

**Interfaces:**
- Consumes: rating −1 from Task 1, `path_index` from Task 4.
- Produces: `min_rating_filter == -1` means "rejected only"; filter button index 6 ↔ filter value −1.

- [ ] **Step 1: X key with toggle**

In `keyPressEvent`, after the digit-rating branch (L1912):
```python
        elif key == Qt.Key.Key_X and event.modifiers() == Qt.KeyboardModifier.NoModifier:
            if self.files:
                orig_idx = self.path_index[self.files[self.index]]
                current = self.ratings.get(orig_idx, 0)
                self._set_rating(0 if current == -1 else -1)
```

- [ ] **Step 2: Fix shoot-stats counting for −1**

In `_set_rating` (L2011-2015), change conditions so reject counts as unrated:
```python
            if prev_rating <= 0 and rating > 0:
                self._shoot_rated_count += 1
                changed = True
            elif prev_rating > 0 and rating <= 0:
                self._shoot_rated_count = max(0, self._shoot_rated_count - 1)
                changed = True
```

- [ ] **Step 3: Overlay shows reject**

In `_update_overlay` (L1180), replace the stars line:
```python
        if rating == -1:
            stars = "✕ rejected"
        else:
            stars = "★" * rating + "☆" * (5 - rating) if rating > 0 else "☆☆☆☆☆"
```

- [ ] **Step 4: Filmstrip badge**

In `FilmstripContent.paintEvent` (L296-303), replace the rating-dots block:
```python
            rating = self.ratings.get(idx, 0)
            if rating > 0:
                painter.setPen(Qt.PenStyle.NoPen)
                painter.setBrush(QColor(255, 200, 50))
                dot_y = y + self.THUMB_SIZE + 5
                dot_start_x = x + (self.THUMB_SIZE - rating * 8) // 2
                for r in range(rating):
                    painter.drawEllipse(dot_start_x + r * 8, dot_y, 5, 5)
            elif rating == -1:
                painter.setPen(QPen(QColor(230, 70, 70), 2))
                font = painter.font()
                font.setPixelSize(12)
                font.setBold(True)
                painter.setFont(font)
                painter.drawText(x, y + self.THUMB_SIZE + 2, self.THUMB_SIZE, 14,
                                 Qt.AlignmentFlag.AlignCenter, "✕")
```

- [ ] **Step 5: Rejected filter bucket**

Filter button labels (L811): `labels = ["All", "1+", "2+", "3+", "4+", "5", "✕"]`

`_on_filter_button` (L1267-1269):
```python
    def _on_filter_button(self, idx: int):
        """Handle filter button click. Button 6 = rejected-only bucket."""
        self._apply_filter(-1 if idx == 6 else idx)
```

`_update_filter_buttons` (L1271-1274):
```python
    def _update_filter_buttons(self):
        """Update filter button states."""
        active_idx = 6 if self.min_rating_filter == -1 else self.min_rating_filter
        for i, btn in enumerate(self.filter_buttons):
            btn.setChecked(i == active_idx)
```

`_apply_filter` (L1238-1244):
```python
        if min_rating == 0:
            self.files = self.all_files
        elif min_rating == -1:
            self._load_all_ratings()
            self.files = [f for i, f in enumerate(self.all_files) if self.ratings.get(i, 0) == -1]
        else:
            self._load_all_ratings()
            self.files = [f for i, f in enumerate(self.all_files) if self.ratings.get(i, 0) >= min_rating]
```

Overlay filter text — `_update_overlay` L1166-1167:
```python
        if self.min_rating_filter > 0:
            position += f"  (≥{self.min_rating_filter}★)"
        elif self.min_rating_filter == -1:
            position += "  (✕)"
```
and L1187: `if self.min_rating_filter > 0:` → `if self.min_rating_filter != 0:`, with the label text:
```python
            filter_desc = "✕" if self.min_rating_filter == -1 else f"≥{self.min_rating_filter}★"
            self.filter_label.setText(f"Filter: {filter_desc}  ({total_filtered}/{total_all})")
```

- [ ] **Step 6: Help text**

In the help overlay string (~L632), add a line next to the rating shortcuts:
```
  X           Reject (toggle)
```

- [ ] **Step 7: Manual verification**

Run: `python main.py "/path/to/shoot"`.
Check: `X` rejects + auto-advances; red ✕ under the thumb; overlay shows "✕ rejected"; `X` again on the same image clears to 0; ✕ filter bucket shows only rejected; ≥1★ filters exclude them; All includes them; open a rejected file's `.xmp` — contains `xmp:Rating="-1"`; Lightroom (if handy) shows it as rejected.

- [ ] **Step 8: Commit**

```bash
git add viewer.py
git commit -m "Add reject flag (X) with filmstrip badge and rejected filter bucket"
```

---

### Task 8: Compare mode (C)

**Files:**
- Modify: `viewer.py` (imports; `__init__` content stack L489-492; `keyPressEvent` Escape L1952 + new C branch; `_set_rating` L1994; `_close_folder` L1403; `_on_mode_button` L1466; `_switch_view_mode` L1523; `_on_folder_scanned` L1324; help text ~L632)

**Interfaces:**
- Consumes: `path_index` (Task 4), `LruByteCache.get` by Path (Task 6), `rating_executor`/`_write_rating_task` (Task 5).
- Produces: `self.compare_pinned: Optional[Path]`, `self.compare_focus: str` ("left"/"right"), `self.compare_view: ZoomableImageView`, `self.image_splitter: QSplitter`, `_toggle_compare()`, `_exit_compare()`, `_update_compare_borders()`.

- [ ] **Step 1: Splitter layout**

Add `QSplitter` to the `QtWidgets` import and `QEvent` to the `QtCore` import at the top of viewer.py.

In `__init__`, replace (L491-492):
```python
        self.image_view = ZoomableImageView()
        self.content_stack.addWidget(self.image_view)
```
with:
```python
        self.image_view = ZoomableImageView()
        self.compare_view = ZoomableImageView()
        self.compare_view.setVisible(False)
        self.image_splitter = QSplitter(Qt.Orientation.Horizontal)
        self.image_splitter.addWidget(self.compare_view)   # pinned (left)
        self.image_splitter.addWidget(self.image_view)     # cursor (right)
        self.content_stack.addWidget(self.image_splitter)

        self.compare_pinned: Optional[Path] = None
        self.compare_focus = "right"
        self.image_view.viewport().installEventFilter(self)
        self.compare_view.viewport().installEventFilter(self)
```
(`content_stack` index 0 is now the splitter; existing `setCurrentIndex(0)` calls keep working.)

- [ ] **Step 2: Toggle / exit / borders**

Add methods:
```python
    def _toggle_compare(self):
        """Pin current image left; navigation moves the right pane only."""
        if self.view_mode == "video" or not self.files:
            return
        if self.compare_pinned is not None:
            self._exit_compare()
            return
        path = self.files[self.index]
        pixmap = self.cache.get(path) or self._load_sync(self.index)
        if not pixmap:
            return
        self.compare_pinned = path
        self.compare_view.set_pixmap(pixmap)
        self.compare_view.setVisible(True)
        half = max(1, self.image_splitter.width() // 2)
        self.image_splitter.setSizes([half, half])
        self.compare_focus = "right"
        self._update_compare_borders()

    def _exit_compare(self):
        if self.compare_pinned is None:
            return
        self.compare_pinned = None
        self.compare_view.setVisible(False)
        self.compare_view.set_pixmap(QPixmap())
        self._update_compare_borders()

    def _update_compare_borders(self):
        if self.compare_pinned is None:
            self.compare_view.setStyleSheet("")
            self.image_view.setStyleSheet("")
            return
        focused = "border: 2px solid #ffb400;"
        unfocused = "border: 2px solid transparent;"
        self.compare_view.setStyleSheet(focused if self.compare_focus == "left" else unfocused)
        self.image_view.setStyleSheet(focused if self.compare_focus == "right" else unfocused)
```

- [ ] **Step 3: Click-to-focus event filter**

Add to `ImageViewer`:
```python
    def eventFilter(self, obj, event):
        if event.type() == QEvent.Type.MouseButtonPress and self.compare_pinned is not None:
            if obj is self.compare_view.viewport():
                self.compare_focus = "left"
                self._update_compare_borders()
            elif obj is self.image_view.viewport():
                self.compare_focus = "right"
                self._update_compare_borders()
        return super().eventFilter(obj, event)
```

- [ ] **Step 4: Keys**

In `keyPressEvent` add:
```python
        elif key == Qt.Key.Key_C and event.modifiers() == Qt.KeyboardModifier.NoModifier:
            self._toggle_compare()
```
Change the Escape branch (L1952-1953):
```python
        elif key == Qt.Key.Key_Escape:
            if self.compare_pinned is not None:
                self._exit_compare()
            else:
                self._close_folder()
```

- [ ] **Step 5: Rating routes to the focused pane**

At the top of `_set_rating` (after the `if not self.files: return`, L1996):
```python
        if self.compare_pinned is not None and self.compare_focus == "left":
            orig_idx = self.path_index.get(self.compare_pinned)
            if orig_idx is None:
                return
            self.ratings[orig_idx] = rating
            self.rating_executor.submit(self._write_rating_task, self.compare_pinned, rating, self.view_mode)
            if self.compare_pinned in self.files:
                self.filmstrip.set_rating(self.files.index(self.compare_pinned), rating)
            return  # pinned side never auto-advances
```

- [ ] **Step 6: Exit compare on context changes**

Call `self._exit_compare()` at the start of: `_close_folder` (L1403, after the `has_any` guard), `_on_mode_button` (L1466, before saving state), `_switch_view_mode` (L1523, after the `_current_folder` guard), and `_on_folder_scanned` (L1324, first line).

- [ ] **Step 7: Help text**

Add to help overlay:
```
  C           Compare with pinned image
```

- [ ] **Step 8: Manual verification**

Run: `python main.py "/path/to/shoot"`.
Check: `C` splits view with current image pinned left (amber border on right pane); arrows change only the right pane; click left pane → border moves, `4` rates the pinned image (check its filmstrip dots) without advancing; click right, rating advances as usual; independent pinch-zoom per pane; `Esc` exits compare (second `Esc` closes folder); `C` in video mode does nothing; switching modes exits compare.

- [ ] **Step 9: Commit**

```bash
git add viewer.py
git commit -m "Add compare mode: pin image left, cull against it on the right"
```

---

### Task 9: Move-rejected action (⌘⌫)

**Files:**
- Modify: `viewer.py` (imports; `keyPressEvent`; new `_move_rejected` method; help text ~L632)

**Interfaces:**
- Consumes: `collect_move_set`, `move_to_rejected`, `REJECTED_DIR_NAME` (Task 3); `_load_all_ratings`; `_load_folder` rescan; `_exit_compare` (Task 8).

- [ ] **Step 1: Wire imports and shortcut**

Add to viewer.py imports:
```python
from move_rejected import collect_move_set, move_to_rejected, REJECTED_DIR_NAME
```
Add `QMessageBox` to the `QtWidgets` import line.

In `keyPressEvent`:
```python
        elif key == Qt.Key.Key_Backspace and event.modifiers() in (
                Qt.KeyboardModifier.ControlModifier, Qt.KeyboardModifier.MetaModifier):
            self._move_rejected()
```

- [ ] **Step 2: Implement the action**

```python
    def _move_rejected(self):
        """Move all rejected files (+ sidecars/pairs) into _rejected/ and rescan."""
        if not self._current_folder or not self.all_files:
            return
        self._load_all_ratings()
        rejected = [f for i, f in enumerate(self.all_files) if self.ratings.get(i, 0) == -1]
        if not rejected:
            self._show_snackbar("No rejected files")
            return
        move_set = collect_move_set(rejected)
        extras = len(move_set) - len(rejected)
        reply = QMessageBox.question(
            self, "Move rejected",
            f"Move {len(rejected)} rejected files (+{extras} sidecars/pairs) to {REJECTED_DIR_NAME}/?",
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
        )
        if reply != QMessageBox.StandardButton.Yes:
            return
        moved, error = move_to_rejected(move_set, self._current_folder)
        if error:
            self._show_snackbar(f"Moved {moved}, then failed at {error}", 5000)
        else:
            self._show_snackbar(f"Moved {moved} files to {REJECTED_DIR_NAME}/")
        self._exit_compare()
        self._load_folder(self._current_folder)
```

- [ ] **Step 3: Help text**

Add to help overlay:
```
  ⌘⌫          Move rejected to _rejected/
```

- [ ] **Step 4: Manual verification**

On a **copy** of a test folder: reject 3 RAWs (one with a same-stem JPG next to it), press ⌘⌫ — dialog shows counts; confirm — files + `.xmp` + JPG pair land in `_rejected/` preserving subfolders; app rescans and the rejected files are gone from all modes; ⌘⌫ again → "No rejected files". Run `python -m pytest tests/ -v` one last time → all PASS.

- [ ] **Step 5: Commit**

```bash
git add viewer.py
git commit -m "Add move-rejected action (cmd+backspace) with confirmation and rescan"
```
