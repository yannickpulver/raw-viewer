# Perf + Core Culling — Round 1

Date: 2026-07-03
Status: Approved

## Goal

Remove felt latency during rapid keyboard culling and add the minimum feature set to make a cull executable end-to-end: reject, compare, move rejected.

## Scope

In: path→index dict, async XMP writes, LRU byte-capped memory cache, RAW preview size cap, reject flag (X), compare mode (C), move-rejected action.

Out (later rounds): burst grouping, focus-point zoom, AVFoundation video thumbnails, ICC-converted preview disk cache, wiring `render_full_preview`.

## 1. Path→index dict

- Add `self.path_index: Dict[str, int]` built wherever `all_files` is (re)assigned: folder scan completion, mode switch (`_save_mode_state`/`_load_mode_state`), post-move rescan.
- Replace all `self.all_files.index(...)` call sites: `_load_current` (viewer.py:1139), `_preload_thumb` (:986), `_on_thumb_loaded` (:945), `_set_rating` (:1998), and the lookup feeding `resolve_export.py:156`.
- `all_files` is never mutated mid-session; rebuild dict only when the list is rebuilt.

## 2. Async XMP writes

- One single-worker `ThreadPoolExecutor` (`rating_executor`) dedicated to rating I/O.
- `_set_rating`: update in-memory rating, filmstrip, overlay, stats, and `_navigate(1)` immediately; submit `write_rating` (and `set_green_tag` for jpeg/video) to the executor.
- Single worker + submissions in order per path ⇒ writes serialize; each write is a full value, so last-write-wins is correct.
- On `closeEvent`: `rating_executor.shutdown(wait=True)` so pending sidecars flush.
- Write errors: log, show a one-line status message; do not roll back memory state.

## 3. LRU byte-capped memory cache

- Replace `self.cache: Dict[int, QPixmap]` + `_trim_cache` distance eviction with an `OrderedDict` LRU.
- Cap by estimated bytes (`pixmap.width() * pixmap.height() * 4`), limit ~1.5 GB.
- `move_to_end` on every hit; evict from the front until under cap on insert.
- Keep per-mode cache in `_mode_state` as today.

## 4. RAW preview size cap

- In `extract_preview` (preview.py), downscale the decoded embedded preview to max 2560 px long edge (matching `load_jpeg_preview`) before returning the QImage.
- Use smooth transformation; keep orientation handling unchanged.
- Disk thumbnail cache (80 px) unaffected.

## 5. Reject flag (X)

- Key `X`: set rating to −1, write `xmp:Rating>-1<` in sidecar (Lightroom-compatible reject), auto-advance like stars.
- `rating.py`: extend clamp to −1..5.
- UI: red ✕ badge on filmstrip thumb and rating overlay (instead of stars).
- Filter row: add a "✕" bucket showing only rejected. Filters ≥1 star exclude rejected naturally (−1 < 1). The "0"/All filter includes rejected.
- Pressing any star 0–5 on a rejected image overwrites the reject. `X` on a rejected image clears back to 0.
- jpeg/video modes: reject also removes the green Finder tag (no tag = not picked); still writes XMP sidecar for Resolve consistency.

## 6. Compare mode (C)

- RAW and JPG modes only; ignored in video mode.
- Press `C`: current image pins to the LEFT pane; a second pane on the right shows the current cursor image. Layout: two `ZoomableImageView`s in a `QSplitter` (equal split).
- Navigation (arrows, filmstrip clicks) changes the RIGHT pane only. Left stays pinned.
- Focus: right pane focused by default; clicking a pane focuses it. Rating keys (0–5, X) apply to the focused pane's image.
- `C` again or `Esc` exits compare, returning to single view at the cursor position.
- Zoom/pan per-pane and independent (sync toggle deferred).
- Preload/caching unchanged — both panes read through the same LRU cache.

## 7. Move rejected

- Action in menu + shortcut (⌘⌫): move every file with rating −1 in the current mode's folder into `<folder>/_rejected/`, preserving relative subpaths.
- Moves together: the file, its `.xmp` sidecar, and same-stem siblings across formats (RAW↔JPG pairs) so pairs stay together.
- Confirmation dialog first: "Move N files (+ M sidecars/pairs) to _rejected/?".
- Move, not delete — reversible by hand.
- After the move: rescan folder (existing scan path), which rebuilds `all_files`, `path_index`, filmstrip. Scanner must skip `_rejected/` directories during recursive walk.

## Error handling

- Rating write failures: non-blocking status message, memory state kept.
- Move failures (permissions, cross-device): stop on first error, report which file, leave already-moved files in place (rescan reflects reality).

## Testing

- Manual: 1,000+ image folder — navigation latency, rapid rating (hold key with autorepeat), back-and-forth compare without re-decode stalls, reject→filter→move round trip, Lightroom reads reject/star sidecars correctly.
- Unit-testable pieces: rating.py clamp/−1 serialization, LRU eviction math, sibling-file discovery for move.

## Success criteria

- No visible stall when rating with key autorepeat on a large shoot.
- Revisiting the previous ~50 images produces no re-decode.
- Full cull workflow possible without leaving the app: rate → reject → filter → move rejected → export to Resolve.
