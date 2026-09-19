# 09 — Architecture Notes

Background on how the current app is put together. This is context, not a
blueprint. The Swift app should not mirror this structure.

---

## 1. Module map

| Module | Lines | Role |
|---|---|---|
| `main.py` | 52 | Entry point. Sets `QT_MEDIA_BACKEND=darwin` before Qt loads, optionally scans a folder passed on the command line, creates the window, and tags the `NSWindow` colour space as sRGB through PyObjC. |
| `viewer.py` | 2612 | Everything else. Contains `PreloadSignals`, `ZoomableImageView`, `FilmstripContent`, `FilmstripWidget` and the 2150-line `ImageViewer` main window. Owns all state, all threading, all keyboard handling and all layout. |
| `grid_view.py` | 316 | The grid view, extracted to stop `viewer.py` growing further. Pure layout functions plus `GridContent` (custom painting) and `GridWidget` (scroll container). |
| `scanner.py` | 240 | Recursive file discovery, extension predicates, EXIF date extraction including the RAF and CR3 blob parsers, the on-disk date cache, and subfolder grouping. |
| `preview.py` | 406 | All image decoding: RAW embedded previews via rawpy, RAW full develop, JPEG via Pillow, video thumbnails via `qlmanage`, orientation transforms, and ICC→sRGB conversion. |
| `rating.py` | 133 | XMP sidecar read and write, plus macOS Finder tag read and write via `xattr` subprocesses. |
| `pixmap_cache.py` | 37 | `LruByteCache`, a byte-budgeted LRU over an `OrderedDict`. |
| `thumbnail_cache.py` | 73 | Disk thumbnail cache keyed by `md5(path:size)` with a sibling `.mtime` validity file. |
| `recent_folders.py` | 48 | The five-entry recent folder list in JSON. |
| `shoot_stats.py` | 50 | Per-folder culling timer statistics in JSON. |
| `move_rejected.py` | 49 | Sibling discovery and the move into `_rejected/`. Also owns the `REJECTED_DIR_NAME` constant that the scanner prunes on. |
| `resolve_export.py` | 198 | DaVinci Resolve discovery, connection, project creation, media import and metadata writing. |
| `version.py` | 12 | Reads the bundled `VERSION` file. |

`viewer.py` holding 62% of the code is the central piece of tech debt. Two
extractions have happened (`grid_view.py`, `move_rejected.py`) and both were
clean, which suggests the rest would extract cleanly too.

---

## 2. Threading model

| Thread / pool | Workers | Work | Source |
|---|---|---|---|
| Qt main thread | 1 | all UI, all painting, all key handling, plus the blocking `_load_all_ratings` sweep | — |
| `current_executor` | 1 | decode the image the user is looking at | `viewer.py:493` |
| `executor` | 6 | decode the 6 previews ahead and 6 behind | `viewer.py:494` |
| `thumb_executor` | 4 | both 80 px and 200 px thumbnails, shared queue | `viewer.py:495` |
| `render_executor` | 1 | full RAW renders — **never used** | `viewer.py:496` |
| `rating_executor` | 1 | XMP sidecar writes and Finder tag writes | `viewer.py:497` |
| Ad-hoc daemon threads | — | folder scanning (`viewer.py:1587`), Resolve export (`viewer.py:2129`), the update check (`viewer.py:986`) | |

Worker threads never touch Qt widgets. They communicate results back through
`PreloadSignals` (`viewer.py:35`), a `QObject` holding nine `pyqtSignal`s, which
Qt marshals onto the main thread automatically.

Synchronisation is a single `threading.Lock` (`viewer.py:502`) guarding the
`loading`, `thumb_loading` and `grid_thumb_loading` sets and the preview cache.
Notably it does **not** guard `self.ratings`, `self.files` or `self.path_index`,
all of which worker threads read and in the case of `ratings` also write.
CPython's GIL makes the individual operations atomic so nothing corrupts, but a
worker can observe a `self.files` list that has been swapped out from under it.
The `_preload_grid_thumb` and `_preload_thumb` functions defend against this
with bounds checks and `path_index.get(...) is None` tests
(`viewer.py:1088`, `:1219`), which is a workaround, not a design.

Timers on the main thread:

| Timer | Interval | Purpose | Source |
|---|---|---|---|
| Loading progress | 200 ms, repeating, started at launch, never stopped | update the "Loading: N%" label | `viewer.py:508` |
| Background thumbnail sweep | 100 ms, repeating while active | submit 5 thumbnail jobs per tick | `viewer.py:1299` |
| Filmstrip scroll debounce | 50 ms, single shot | emit the visible range after scrolling stops | `viewer.py:398` |
| Filmstrip repaint batch | 50 ms, single shot | coalesce thumbnail-arrival repaints | `viewer.py:245` |
| Grid scroll debounce | 50 ms, single shot | same, for the grid | `grid_view.py:247` |
| Grid repaint batch | 50 ms, single shot | same, for the grid | `grid_view.py:96` |
| Stats refresh | 1000 ms, repeating while the overlay is visible | tick the elapsed time | `viewer.py:800` |
| Snackbar | single shot, 2000–5000 ms | hide the snackbar | `viewer.py:815` |

---

## 3. Signal flow: open folder → display

```
user picks / drops a folder
  └─ _load_folder (viewer.py:1564)
       ├─ set _current_folder, hide the empty state, show "Scanning folder..."
       └─ daemon thread:
            ├─ scan_folder(RAW, progress) ──► scan_progress signal ──► label text
            ├─ scan_folder_jpeg
            ├─ scan_folder_video
            ├─ stash jpeg and video results into _mode_state  (from the thread!)
            └─ folder_scanned(files, folder) signal
                 └─ _on_folder_scanned (viewer.py:1596)   [main thread]
                      ├─ empty in all three modes → back to the empty state, stop
                      ├─ add_recent_folder + rebuild the recent buttons
                      ├─ stop the background thumbnail sweep
                      ├─ force view_mode back to "raw"
                      ├─ clear cache, ratings, loading sets, all thumbnails
                      ├─ install files, rebuild path_index, reset index and filters
                      ├─ resume or start the shoot timer
                      ├─ filmstrip.set_total, update filter buttons, update empty state
                      ├─ no RAW but JPEG/video → _switch_view_mode(...) and stop
                      ├─ _load_current
                      │    ├─ cache hit → _display
                      │    └─ miss → show the filmstrip thumb as a placeholder,
                      │              submit to current_executor
                      │                 └─ loaded(idx, path, pixmap) signal
                      │                      └─ _on_preloaded: cache it, display it
                      │                         if it is still current, derive an
                      │                         80 px filmstrip thumb
                      ├─ _preload_nearby  → 12 jobs on executor
                      ├─ _preload_all_thumbnails → 100 ms timer, 5 jobs/tick
                      └─ _update_overlay
```

`_mode_state` being written from the scan thread (`viewer.py:1583`) is the one
genuine race in the app. The main thread reads those entries in
`_on_folder_scanned`, which is guaranteed to run after, so in practice it is
safe. Note: fragile by construction.

## 4. Signal flow: rate → write → advance

```
key 0-5 or X
  └─ _set_rating (viewer.py:2479)
       ├─ compare active and left pane focused?
       │    └─ rate the pinned file, update its filmstrip badge, STOP (no advance)
       ├─ orig_idx = path_index[files[index]]
       ├─ ratings[orig_idx] = rating                 [immediate, in memory]
       ├─ rating_executor.submit(_write_rating_task) [async]
       │    └─ write_rating → XMP sidecar
       │       if jpeg/video: set_green_tag(path, rating > 0)
       │       on failure → rating_write_failed signal → snackbar for 4 s
       ├─ filmstrip.set_rating + grid.set_rating     [batched 50 ms repaint]
       ├─ _update_overlay
       ├─ shoot stats: adjust rated_count if the >0 status flipped,
       │               stamp last_rating_elapsed, persist, refresh the overlay
       └─ index < last?  → _navigate(1)
                            ├─ _load_current
                            ├─ (grid mode → stop here)
                            ├─ _preload_nearby
                            └─ _preload_thumbnails (index ±10)
```

The UI never waits on disk. A failed write leaves the memory state optimistic
and shows a snackbar, deliberately (see the design document, section 2).

---

## 5. Pitfalls the code documents or works around

These are all real bugs that were found and fixed. A rewrite will hit the same
ones.

| Pitfall | Fix in the current code | Commit |
|---|---|---|
| 60 fps and slow-motion clips play too fast with Qt's default FFmpeg media backend | force `QT_MEDIA_BACKEND=darwin` before Qt is imported | `05e35a6` |
| Colours oversaturated on wide-gamut (P3) displays | tag every decoded image sRGB **and** tag the `NSWindow` colour space sRGB | `82668cd` |
| Embedded previews carry non-sRGB ICC profiles | convert to sRGB with Pillow before decoding, skipping profiles already described as sRGB | `c7ab137` |
| Update banner always showed | the GitHub tag is `v0.3.1` but the local version is `0.3.1`; strip the `v` | `89161ae` |
| `zip` lost symlinks, breaking notarization | use `ditto -c -k --keepParent` | `18dd692` |
| Stapling invalidated the already-built zip | delete and rebuild the zip after stapling | `e9135be` |
| `all_files.index(path)` was O(n) and ran on every navigation | a `path_index` dict, rebuilt whenever `all_files` is reassigned | `5a99095` |
| Synchronous XMP writes stalled rapid culling | a single-worker executor, flushed on close | `fbba221` |
| The preview cache grew without bound | byte-capped LRU, 1.5 GB, plus a 2560 px cap on decoded previews | `02a137b` |
| Filmstrip scrolling stalled on thumbnail loads | 50 ms debounce, disk cache, prioritise from the current selection | `618a7ab`, `48b1d0e` |
| Rescanning while in JPEG or video mode left the wrong list installed | force `view_mode` back to `"raw"` on rescan | `635cd0e` |
| A stale `path` captured in a preload closure displayed the wrong image | pass the path through the signal and compare it before displaying | `635cd0e` |
| Rejected files could be moved before their sidecar write landed | flush the rating executor before collecting the move set | `635cd0e` |
| `X` in compare mode rated the wrong pane | read the focused pane | `c3e274b` |
| Grid thumbnails at 200 px blew up memory on large folders | evict anything more than 100 indices outside the visible range, and never background-sweep at 200 px | `514fbd5` |
| Grid cells left a ragged right margin | stretch cells to fill the width, with the base cell as a floor | `f2cc714` |
| The recent folder list overlapped the open button | recompute positions after building the buttons | `4b180ef` |
| Filmstrip scrollbar was too small to grab | 18 px high with bottom padding | `b9e8af9` |

### Additional gotchas visible in the code

- `QImage` constructed over a Python `bytes` buffer must be `.copy()`d before
  the buffer goes out of scope, or the image shows garbage. Every construction
  site does this (`preview.py:84`, `:105`, `:157`, `:199`, `:217`, `:305`).
- The `_display` guard `self.files[self.index] == path` prevents a slow decode
  that finishes after the user has moved on from overwriting the current image
  (`viewer.py:1054`).
- Filmstrip and grid thumbnail dictionaries are keyed by filtered-list index, so
  every filter change and mode switch must clear them or thumbnails appear under
  the wrong images (`viewer.py:1492`).
- The `thumb_failed` set exists solely so the loading percentage can reach 100%
  when some files cannot produce a thumbnail (`viewer.py:1457`).
- `_preload_thumb` and `_preload_grid_thumb` both use `try/finally` to always
  discard their index from the loading set, otherwise a failed decode
  permanently blocks retries (`viewer.py:1252`).

---

## 6. Known limitations and tech debt

1. `viewer.py` is a 2600-line god object.
2. Dead code: `render_full_preview`, `needs_full_render`, `MIN_PREVIEW_WIDTH`,
   `_render_full`, `render_executor`, `_load_thumb_sync`, `has_green_tag`,
   `_get_jpeg_orientation`, `ThumbnailCache.invalidate`, the `thumbnail`
   parameter of `extract_preview`, `root_folder` in the Resolve export, and the
   `QNativeGestureEvent`, `QFont` and `QSize` imports.
3. The DJI DNG small-preview path is specified but never wired up (`04`).
4. No preview caching to disk. Only 80 px and 200 px thumbnails are cached;
   every 2560 px preview is re-decoded on every folder open.
5. Neither the disk thumbnail cache nor the date cache nor the shoot stats file
   is ever pruned.
6. `_load_all_ratings` blocks the UI thread with a whole-folder disk sweep.
7. Ratings are keyed by index into `all_files` rather than by path, which makes
   every list rebuild a correctness hazard.
8. A RAW file and a JPEG with the same stem share one `.xmp` sidecar and
   overwrite each other (`05`).
9. Resolve clip matching is by filename, which breaks with duplicate names
   across subfolders (`06`).
10. No cancellation of in-flight decodes.
11. `_mode_state` is mutated from a background thread (section 3).
12. No window state, filmstrip state or last-folder persistence (`07`).
13. The Homebrew `zap` stanza cleans up paths the app never writes (`08`).
14. Errors are reported by `print()` to a console that a bundled app does not
    have. The only user-visible error channels are the snackbar and the Resolve
    status label.
15. No tests cover `viewer.py`, `preview.py` or `resolve_export.py`.
16. Command-line launch bypasses `_current_folder`, disabling subfolder chips,
    mode switching, Resolve export and move-rejected (`01` section 10).

---

## 7. Suggested Swift mapping

Suggestions, not requirements. The team doing the rewrite should decide.

| Current | Suggested Apple framework | Notes |
|---|---|---|
| PyQt6 widgets, manual absolute positioning | SwiftUI, with AppKit interop where needed | The overlay-heavy layout maps well to `ZStack` with `.overlay(alignment:)`. |
| `QMainWindow`, transparent title bar via PyObjC | `WindowGroup` with `.windowStyle(.hiddenTitleBar)` | Removes the `NSApplication.windows()` title-matching hack entirely. |
| `QGraphicsView` zoom and pan | `ScrollView` with `.magnificationGesture`, or an `NSScrollView` wrapper | Keep the exact zoom rules from `01` section 16. |
| `rawpy` / LibRaw `extract_thumb()` | `CGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceCreateThumbnailFromImageAlways` and `kCGImageSourceThumbnailMaxPixelSize: 2560` | Gives the embedded preview directly, already oriented. |
| `rawpy.postprocess()` full develop | `CIRAWFilter` | For the small-embedded-preview fallback that is currently unwired. |
| `rawpy.sizes.flip` orientation table | `kCGImagePropertyOrientation` from ImageIO, or `CGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceCreateThumbnailWithTransform: true` | The mapping table becomes unnecessary. |
| `exifread` + hand-written RAF/CR3 blob parsers | `CGImageSourceCopyPropertiesAtIndex` → `kCGImagePropertyExifDateTimeOriginal` | Native support for RAF and CR3 removes ~60 lines of binary parsing. |
| Pillow `ImageCms` ICC→sRGB | ColorSync, implicit in CoreGraphics | Do not re-encode. Keep the source colour space and let the display pipeline convert. |
| `qlmanage -t` subprocess | `QLThumbnailGenerator` | Async, no subprocess, no temp directory, no 10 s timeout. |
| `QMediaPlayer` + `QVideoWidget` + `QT_MEDIA_BACKEND=darwin` | `AVPlayer` + `VideoPlayer` (SwiftUI) or `AVPlayerView` | The frame-timing bug disappears. |
| `LruByteCache` | `NSCache` with `totalCostLimit` | Same semantics. Note `NSCache` may evict under memory pressure, which `LruByteCache` never does. |
| `ThumbnailCache` (md5 + `.mtime` pairs) | A cache directory under `~/Library/Caches/dev.yannickpulver.rawviewer/`, one file per entry, mtime stored as an extended attribute or embedded in the filename | Add a size cap. |
| `recent_folders.json` | `UserDefaults` plus security-scoped bookmarks | Bookmarks are required if the app is ever sandboxed. |
| `shoot_stats.json` | `UserDefaults` or a small file in Application Support | Keyed by folder bookmark rather than path, so renames survive. |
| `dates_v2.json` | Either keep a cache file, or drop it — ImageIO date reads are fast enough that the cache may be unnecessary | Measure first. |
| `rating.py` regex XMP editing | `XMLDocument` for reads, string template for writes | Keep the template byte-identical (`05` section 3). |
| `xattr` subprocesses for Finder tags | `URLResourceValues.tagNames` | One line instead of three subprocesses. |
| `subprocess.run(['open', '-R', ...])` | `NSWorkspace.shared.activateFileViewerSelecting(_:)` | |
| `subprocess.run(['open', '-a', 'Adobe Lightroom Classic', ...])` | `NSWorkspace.shared.open(_:withApplicationAt:configuration:)` | Also lets you detect that Lightroom is missing, which the current code cannot. |
| `ThreadPoolExecutor` pools | Swift structured concurrency, with a bounded `TaskGroup` per priority band, or `OperationQueue` with `maxConcurrentOperationCount` | Take the chance to add cancellation. |
| `PreloadSignals` / `pyqtSignal` | `@MainActor` isolation and `async` returns | Signals exist only to hop threads; `@MainActor` does it declaratively. |
| `urllib` GitHub release poll | `URLSession`, or Sparkle | Keeping the current endpoint is the lower-risk choice (`08` section 7). |
| `resolve_export.py` | See `06` section 1 — there is no Swift binding | The one part that cannot be ported cleanly. |
| PyInstaller + hardened-runtime entitlement workarounds | A normal Xcode app target | Drop `entitlements.plist` entirely. |
