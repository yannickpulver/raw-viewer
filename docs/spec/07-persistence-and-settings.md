# 07 — Persistence and Settings

---

## 1. Summary: there is no preferences system

The app uses **no** `QSettings`, no `NSUserDefaults`, no plist, and no
preferences window. A grep of the whole codebase for `QSettings` returns
nothing. Everything persistent is a hand-rolled JSON file or a cache directory
under `~/.cache/raw-viewer/`.

Consequence: window size and position, filmstrip visibility, the info overlay
toggle, the last folder and the last view mode are all **not** remembered across
launches. Every launch starts at 1400 x 900 with the filmstrip on, the info
overlay on, no folder open.

A Swift rewrite should move these to `UserDefaults` / `NSWindow` frame
autosave. That is new behaviour and worth doing, but note it as a deliberate
addition rather than a port.

---

## 2. Everything written to disk

| # | Path | Format | Written by | Read by |
|---|---|---|---|---|
| 1 | `~/.cache/raw-viewer/dates_v2.json` | JSON object | `scanner._save_date_cache` (`scanner.py:31`) | `scanner._load_date_cache` at import (`scanner.py:21`) |
| 2 | `~/.cache/raw-viewer/recent_folders.json` | JSON array | `recent_folders.add_recent_folder` (`recent_folders.py:41`) | `recent_folders.load_recent_folders` (`recent_folders.py:13`) |
| 3 | `~/.cache/raw-viewer/shoot_stats.json` | JSON object | `shoot_stats.save_stats` (`shoot_stats.py:36`) | `shoot_stats.load_stats` (`shoot_stats.py:23`) |
| 4 | `~/.cache/raw-viewer/thumbs/<md5>.jpg` | JPEG q85 | `ThumbnailCache.set` (`thumbnail_cache.py:52`) | `ThumbnailCache.get` (`thumbnail_cache.py:33`) |
| 5 | `~/.cache/raw-viewer/thumbs/<md5>.mtime` | plain text float | same | same |
| 6 | `<image>.xmp` next to each rated file | XMP (see `05`) | `rating.write_rating` (`rating.py:41`) | `rating.read_rating` (`rating.py:24`) |
| 7 | `com.apple.metadata:_kMDItemUserTags` xattr on JPEG/video files | binary plist | `rating.set_green_tag` (`rating.py:106`) | `rating.read_finder_tags` (`rating.py:86`) |
| 8 | `<folder>/_rejected/<relative path>` | moved files | `move_rejected.move_to_rejected` (`move_rejected.py:31`) | — |

The Homebrew cask's `zap` stanza lists
`~/Library/Preferences/com.yannickpulver.raw-viewer.plist` and
`~/Library/Application Support/RAW Viewer` for removal
(`.github/workflows/update-homebrew-tap.yml`). Neither of those is ever created
by the app, and the actual cache directory `~/.cache/raw-viewer` is **not** in
the zap list. Note: the uninstaller cleans up the wrong paths and leaves the real
ones behind. Note: likely unintended. A rewrite that moves to
`~/Library/Application Support/RAW Viewer` and
`~/Library/Caches/dev.yannickpulver.rawviewer` would align with both macOS
convention and the existing cask.

---

## 3. Date cache — `dates_v2.json`

```json
{
  "/Users/x/Shoot/DSCF0001.RAF": [1747989524.0, 1747989524.0],
  "/Users/x/Shoot/DSCF0002.RAF": [1747989530.0, 1747989530.0]
}
```

Key: absolute path as written by `str(Path)`. Value: a two-element array
`[source mtime, capture timestamp]`, both floats.

| Behaviour | Detail |
|---|---|
| Loaded | once at module import time, into a module-level global |
| Saved | at the end of every non-empty scan, whole file rewritten |
| Validity | the entry is used only if the stored mtime exactly equals the file's current mtime |
| Default | empty dict, including when the file is corrupt |
| Eviction | none |
| Concurrency | the global dict is mutated from the scan thread with no lock |

Note: three scans run per folder open (RAW, JPEG, video), each of which
rewrites the whole file at the end. Note: wasteful.

---

## 4. Recent folders — `recent_folders.json`

```json
["/Users/x/Shoots/2026-05-23 Wedding", "/Users/x/Shoots/2026-05-10 Studio"]
```

A JSON array of absolute path strings, most recent first.

| Property | Value | Source |
|---|---|---|
| Maximum entries | 5 (`MAX_RECENT`) | `recent_folders.py:10` |
| Ordering | newest first | `recent_folders.py:35` |
| Deduplication | an existing entry is removed before being re-inserted at the front | `recent_folders.py:32` |
| Pruning | on load, entries that are no longer directories are dropped | `recent_folders.py:20` |
| Trim on load | the filtered list is also truncated to 5 | `recent_folders.py:20` |
| Added when | a folder scan completes and found at least one RAW, JPEG or video file | `viewer.py:1609` |
| Default | `[]` on any read error | `recent_folders.py:23` |
| Errors | silently ignored on both read and write | `recent_folders.py:21`, `:45` |

`add_recent_folder` reloads the list from disk before mutating, so the on-disk
list is always the source of truth (`recent_folders.py:28`).

The folder picker's starting directory is `recent[0]` if there is one, otherwise
the home directory (`viewer.py:1551`).

The UI shows only the folder's basename with the full path as a tooltip
(`viewer.py:2192`).

---

## 5. Shoot stats — `shoot_stats.json`

```json
{
  "/Users/x/Shoots/2026-05-23 Wedding": {
    "elapsed": 1842.3,
    "rated_count": 63,
    "last_rating_elapsed": 1790.1
  }
}
```

| Field | Type | Default on read |
|---|---|---|
| `elapsed` | float, total seconds | `0.0` |
| `rated_count` | int | `0` |
| `last_rating_elapsed` | float or `null` | `None` |

Key: absolute folder path. Loading a key whose value is not a dict returns
`None` and starts a fresh shoot (`shoot_stats.py:27`).

Written on every change to the rated count, on folder close and on window close.
The whole file is rewritten each time. No eviction, no size limit.

Semantics are described in `05` section 11.

---

## 6. Thumbnail cache directory

`~/.cache/raw-viewer/thumbs/`, created with `parents=True, exist_ok=True` on
first construction of `ThumbnailCache` (`thumbnail_cache.py:16`), which happens
in the `ImageViewer` constructor (`viewer.py:505`) — so the directory exists
from launch even if no folder is opened.

Two flat files per cached entry:

| File | Content |
|---|---|
| `<md5 of "{absolute path}:{size}">.jpg` | the thumbnail, JPEG quality 85 |
| `<md5 of "{absolute path}:{size}">.mtime` | `str(float)` of the source file's mtime, e.g. `1747989524.123456` |

Sizes in use: 80 (filmstrip) and 200 (grid). Both coexist because the size is
part of the key.

No eviction, no maximum, no cleanup. The `invalidate` method exists but is never
called.

---

## 7. What is stored only in memory

These reset on every launch, and most also reset on every folder change.

| State | Reset when | Source |
|---|---|---|
| Window size 1400 x 900 and position | every launch | `viewer.py:978` |
| `show_info = True` | every launch | `viewer.py:471` |
| `filmstrip_visible = True` | every launch | `viewer.py:472` |
| `view_mode = "raw"` | every launch, every folder load, every folder close | `viewer.py:478`, `:1620`, `:1735` |
| `display_mode = "single"` | every launch, every folder close | `viewer.py:593`, `:1717` |
| `min_rating_filter = 0` | every launch, every folder load and close | `viewer.py:473`, `:1640` |
| `folder_filter = None` | same | `viewer.py:474`, `:1641` |
| `excluded_folders = set()` | same | `viewer.py:475`, `:1642` |
| Selected index | every folder load and close | `viewer.py:1639` |
| Preview cache | every folder load and close | `viewer.py:1626`, `:1708` |
| Ratings map | every folder load and close | `viewer.py:1627`, `:1709` |
| Last opened folder | never persisted | — |

---

## 8. Environment variables

| Variable | Set where | Value | Purpose |
|---|---|---|---|
| `QT_MEDIA_BACKEND` | `main.py:10`, via `setdefault` before Qt is imported | `"darwin"` | forces the native AVFoundation media backend; the default FFmpeg backend plays 60 fps and slow-motion clips at the wrong speed (commit `05e35a6`) |
| `RESOLVE_SCRIPT_API` | `resolve_export.py:64` | the Resolve `Developer/Scripting` directory | required by `DaVinciResolveScript` |
| `RESOLVE_SCRIPT_LIB` | `resolve_export.py:65` | path to `fusionscript.so` | required by `DaVinciResolveScript` |

The two Resolve variables are set into the app's own process environment at
export time and are never unset.

No environment variables are read for configuration. There are no hidden
defaults or debug flags.

---

## 9. Subprocesses launched

Full inventory, for sandboxing and entitlements planning.

| Command | Where | Purpose |
|---|---|---|
| `open -R <file>` | `viewer.py:2396` | reveal the current file in Finder |
| `open -a "Adobe Lightroom Classic" <files...>` | `viewer.py:2365` | open the visible list in Lightroom |
| `open <url>` | `viewer.py:2249` | open the GitHub release page |
| `open -a "DaVinci Resolve"` | `resolve_export.py:81` | launch Resolve |
| `xattr -px com.apple.metadata:_kMDItemUserTags <file>` | `rating.py:89` | read Finder tags |
| `xattr -wx com.apple.metadata:_kMDItemUserTags <hex> <file>` | `rating.py:121` | write Finder tags |
| `xattr -d com.apple.metadata:_kMDItemUserTags <file>` | `rating.py:126` | remove all Finder tags |
| `qlmanage -t -s <px> -o <tmpdir> <file>` | `preview.py:377` | render a video thumbnail, 10 s timeout |

All of these have native Swift equivalents: `NSWorkspace.activateFileViewerSelecting`,
`NSWorkspace.open(_:withApplicationAt:)`, `URLResourceValues.tagNames`, and
`QLThumbnailGenerator`.

---

## 10. Network access

Exactly one outbound request in the entire app.

| Property | Value | Source |
|---|---|---|
| URL | `https://api.github.com/repos/yannickpulver/raw-viewer/releases/latest` | `viewer.py:2595` |
| Method | GET via `urllib.request` | `viewer.py:2597` |
| Header | `User-Agent: RAW-Viewer` | `viewer.py:2596` |
| Timeout | 5 seconds | `viewer.py:2597` |
| When | once, on a daemon thread, at construction | `viewer.py:986` |
| Skipped | when `VERSION == "dev"` | `viewer.py:2592` |
| Failure | silent | `viewer.py:2603` |

No analytics, no crash reporting, no telemetry of any kind.

---

## 11. File system paths derived from the user's home

Complete list, for auditing:

| Expression | Resolves to | Source |
|---|---|---|
| `Path.home() / ".cache" / "raw-viewer" / "dates_v2.json"` | date cache | `scanner.py:18` |
| `os.path.expanduser("~/.cache/raw-viewer/recent_folders.json")` | recent folders | `recent_folders.py:9` |
| `os.path.expanduser("~/.cache/raw-viewer/shoot_stats.json")` | shoot stats | `shoot_stats.py:8` |
| `os.path.expanduser("~/.cache/raw-viewer/thumbs")` | thumbnail cache dir | `thumbnail_cache.py:14` |
| `str(Path.home())` | folder picker fallback directory | `viewer.py:1552` |

`ThumbnailCache.__init__` accepts a `cache_dir` override argument, which is
never passed by the app (`thumbnail_cache.py:12`). It exists for testing.
