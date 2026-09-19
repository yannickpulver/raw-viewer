# 04 — Preview and Thumbnail Pipelines

Source modules: `preview.py`, `pixmap_cache.py`, `thumbnail_cache.py`, and the
preload machinery in `viewer.py`.

---

## 1. Constants at a glance

| Constant | Value | Where | Source |
|---|---|---|---|
| RAW preview long-edge cap | 2560 px | `extract_preview` | `preview.py:114` |
| JPEG preview long-edge cap | 2560 px | `load_jpeg_preview` default | `preview.py:322` |
| Filmstrip thumbnail size | 80 px | `FilmstripContent.THUMB_SIZE` | `viewer.py:222` |
| Grid thumbnail size | 200 px | `grid_view.CELL` | `grid_view.py:9` |
| Thumbnail JPEG quality | 85 | all `*_thumbnail_bytes` | `preview.py:240`, `:357`, `:396` |
| ICC re-encode JPEG quality | 95 | `_convert_icc_to_srgb` | `preview.py:280` |
| Small-preview threshold | 640 px width | `MIN_PREVIEW_WIDTH`, **unused** | `preview.py:128` |
| Quick Look render size | `2 * requested size` | `load_video_thumbnail` | `preview.py:378` |
| Quick Look timeout | 10 s | `load_video_thumbnail` | `preview.py:379` |
| Memory preview cache budget | 1,500,000,000 bytes per mode | `ImageViewer.CACHE_MAX_BYTES` | `viewer.py:461` |
| Preview cost estimate | `width * height * 4` bytes | `_on_preloaded` | `viewer.py:1051` |

---

## 2. RAW preview — `extract_preview` (`preview.py:49`)

Step by step:

1. Open the file with rawpy (LibRaw).
2. Read `raw.sizes.flip` and map it to an EXIF-style orientation with this exact
   table (`preview.py:62`):

   | rawpy flip | EXIF orientation | Meaning |
   |---|---|---|
   | 0 | 1 | no transform |
   | 3 | 3 | rotate 180 |
   | 5 | 8 | rotate 90 counter-clockwise |
   | 6 | 6 | rotate 90 clockwise |
   | anything else | 1 | treated as no transform |

3. Try `raw.extract_thumb()`:
   - If the embedded preview is JPEG: run it through the ICC→sRGB converter
     (section 6), decode it, tag the image sRGB, make a pixmap.
   - If it is a bitmap: wrap the raw RGB888 buffer, copy it, tag sRGB, make a
     pixmap.
   - If LibRaw reports no thumbnail (`LibRawNoThumbnailError`), leave the pixmap
     unset.
4. Only if no embedded preview existed at all, do a full RAW develop
   (`preview.py:92`):
   `half_size=True`, `use_camera_wb=True`, `no_auto_bright=True`,
   `output_bps=8`, `output_color=sRGB`.
5. Apply the orientation transform if it is not 1 (section 3).
6. If the long edge exceeds 2560 px, scale down to fit 2560 x 2560 preserving
   aspect, with smooth transformation (`preview.py:114`).
7. On any exception, print `Error loading {path}: {e}` and return `None`.

The `thumbnail: bool = False` parameter is declared but never read
(`preview.py:49`). Note: dead parameter.

### The DJI DNG small-preview path is not wired

`preview.py` defines `MIN_PREVIEW_WIDTH = 640`, `needs_full_render(pixmap)`
(true when the preview is narrower than 640 px) and `render_full_preview(path)`
(a full postprocess with the same settings as step 4).
`viewer.py` imports both (`viewer.py:22`) and defines `_render_full`
(`viewer.py:1208`) plus a dedicated single-worker `render_executor`
(`viewer.py:496`).

**None of it is ever called.** There is no call site for `needs_full_render`,
`render_full_preview`, `_render_full` or `render_executor` anywhere in the
codebase. The consequence is that a DNG whose embedded preview is a small
thumbnail (some DJI drones ship a 256 px preview) displays at that size,
upscaled and soft, with no full render ever kicking in.

The approved design document lists "wiring `render_full_preview`" as explicitly
out of scope for that round
(`docs/superpowers/specs/2026-07-03-perf-culling-round1-design.md`, Scope).

For the rewrite: decide deliberately. The intended behaviour is clearly "if the
embedded preview is under 640 px wide, kick off a full decode on a low-priority
queue and swap it in when ready". The shipped behaviour is "never".

---

## 3. Orientation transform (`preview.py:23`)

Maps an EXIF orientation value to a 2D transform. Applied by
`QPixmap.transformed()`.

| Orientation | Transform |
|---|---|
| 1 | identity |
| 2 | scale(-1, 1) — horizontal flip |
| 3 | rotate 180 |
| 4 | scale(1, -1) — vertical flip |
| 5 | rotate 90, then scale(-1, 1) |
| 6 | rotate 90 |
| 7 | rotate -90, then scale(-1, 1) |
| 8 | rotate -90 |

In practice only 1, 3, 6 and 8 are ever produced for RAW files, because the
rawpy flip table only emits those. Values 2, 4, 5 and 7 are reachable only
through the JPEG path, which uses Pillow's `ImageOps.exif_transpose` instead and
never calls this function. Note: orientations 2, 4, 5, 7 are effectively dead
code.

`_get_jpeg_orientation` (`preview.py:310`) reads `Image Orientation` from a JPEG
via exifread and is also never called. Note: dead code.

---

## 4. JPEG preview — `load_jpeg_preview` (`preview.py:322`)

1. Open with Pillow and convert any embedded ICC profile to sRGB
   (`_load_jpeg_with_icc`, `preview.py:286`).
2. Apply EXIF orientation with `ImageOps.exif_transpose`.
3. If the long edge exceeds 2560 px, resize with LANCZOS to fit.
4. Convert to RGB, wrap as an RGB888 `QImage`, copy, tag sRGB, make a pixmap.
5. On failure, print an error and return `None`.

---

## 5. Thumbnail pipelines

### RAW thumbnails — `extract_thumbnail(path, size)` (`preview.py:171`)

Same orientation handling as the preview. Tries the embedded thumb first; on
`LibRawNoThumbnailError` falls back to the same half-size postprocess. Applies
orientation, then scales to fit `size x size` with **fast** transformation
(`preview.py:228`).

Note: this fallback is inside the `except` clause only. If `extract_thumb()`
succeeds but returns a format that is neither JPEG nor BITMAP, the pixmap stays
`None` and the function returns `None` without any fallback
(`preview.py:221`). The preview function has the same shape but does have an
outer `if pixmap is None` fallback. Note: likely unintended asymmetry.

### JPEG thumbnails — `load_jpeg_thumbnail(path, size)` (`preview.py:342`)

ICC→sRGB, `exif_transpose`, `PIL.thumbnail((size, size))` with LANCZOS, convert
to pixmap.

### Video thumbnails — `load_video_thumbnail(path, size)` (`preview.py:370`)

1. Create a temporary directory.
2. Run `qlmanage -t -s {size*2} -o {tmpdir} {path}` with output captured and a
   10 second timeout.
3. Scan the temp dir for the first `.png` file and load it.
4. Scale it to fit `size x size` with smooth transformation.
5. Return `None` if nothing was produced, or on any exception.

This is a subprocess per thumbnail. It is the slowest path in the app and the
first thing a Swift rewrite should replace with `QLThumbnailGenerator` or
`AVAssetImageGenerator`.

### Byte-producing variants

`extract_thumbnail_bytes`, `load_jpeg_thumbnail_bytes` and
`load_video_thumbnail_bytes` (`preview.py:240`, `:357`, `:396`) each call the
matching pixmap function and re-encode the result as JPEG at quality 85 for the
disk cache.

Note: RAW and JPEG thumbnails therefore go through JPEG decode → resize → JPEG
encode → (disk) → JPEG decode. The generation-loss is invisible at 80 px but the
round trip is wasteful.

### Decoding a cached thumbnail

`pixmap_from_jpeg_srgb(bytes)` (`preview.py:255`) decodes the JPEG, tags it
sRGB, and returns `None` on any failure.

---

## 6. Colour management

This is the most Python-specific part of the app and also the part whose
*outcome* matters most.

### The problem being solved

Commit `82668cd` "Fix oversaturated colors on wide-gamut displays". Qt hands
untagged 8-bit RGB to macOS, which then treats it as Display P3 on a wide-gamut
screen, oversaturating everything. Two fixes were applied together:

1. Every decoded image is explicitly tagged with the sRGB colour space before
   becoming a pixmap (`_tag_srgb`, `preview.py:18`).
2. The `NSWindow` backing store is tagged sRGB through PyObjC so AppKit
   colour-manages it to the display (`main.py:18`).

### ICC conversion (`_convert_icc_to_srgb`, `preview.py:266`)

Applied only to embedded JPEG previews pulled out of RAW files.

1. Open the JPEG bytes with Pillow, read `icc_profile` from `info`.
2. If there is no profile, return the original bytes untouched.
3. Build the source profile and read its description string.
4. If the lowercased description contains `"srgb"`, return the original bytes —
   no conversion (`preview.py:275`).
5. Otherwise convert to sRGB with `ImageCms.profileToProfile`, output mode RGB.
6. Re-encode as JPEG at **quality 95** with an sRGB ICC profile embedded.
7. Any exception returns the original bytes.

`_load_jpeg_with_icc` (`preview.py:286`) does the same for standalone JPEG files
but works on the `PIL.Image` object rather than bytes, so there is no re-encode.

### Colour space assumptions

- Everything downstream of `preview.py` assumes sRGB.
- Profiles whose description merely *contains* "srgb" are trusted as already
  sRGB. A profile named e.g. "sRGB IEC61966-2.1 (modified)" would be skipped.
  Note: likely fragile.
- There is no rendering intent choice; `profileToProfile` uses its default
  (perceptual).
- Wide-gamut source files (Adobe RGB, Display P3, ProPhoto) are all clipped into
  sRGB. The app deliberately does not display wide gamut.

### Rewrite note

A Swift app gets all of this from ColorSync automatically. Load the image with
ImageIO, keep the tagged colour space, hand it to a colour-managed view. Do not
re-encode. The *behaviour* to preserve is "colours look correct, not
oversaturated, on a P3 display". The mechanism is entirely replaceable.

---

## 7. Preloading strategy

### Executors (`viewer.py:493`)

| Executor | Workers | Purpose | Notes |
|---|---|---|---|
| `current_executor` | 1 | the image the user is looking at | highest priority, bypasses the preload queue |
| `executor` | 6 | nearby previews | |
| `thumb_executor` | 4 | both filmstrip (80 px) and grid (200 px) thumbnails | shared queue |
| `render_executor` | 1 | full RAW renders | **never used** |
| `rating_executor` | 1 | XMP sidecar writes | single worker guarantees write ordering |

All are plain `ThreadPoolExecutor`s with unbounded queues. There is no
cancellation anywhere — submitted work always runs to completion, even if the
user has navigated away. The only guard is the `loading` / `thumb_loading` /
`grid_thumb_loading` sets, which prevent duplicate submissions for the same
index (`viewer.py:498`).

Note: the absence of cancellation means that scrolling fast through a large
folder queues up hundreds of decodes that all still execute. In a Swift rewrite
this should be a cancellable operation queue keyed by index.

### Nearby preview preload (`_preload_nearby`, `viewer.py:1259`)

Submitted in this exact offset order, so the next image wins over the previous:

```
+1, -1, +2, -2, +3, -3, +4, -4, +5, -5, +6, -6
```

So 6 ahead and 6 behind. Skipped entirely in video mode. An index is submitted
only if it is in range, not already in the preview cache, and not already being
loaded.

### Current image load (`_load_current`, `viewer.py:1336`)

1. If the preview cache already holds this path, display it immediately.
2. Otherwise, if an 80 px filmstrip thumbnail exists, display that as an instant
   low-resolution placeholder.
3. Submit the real decode to `current_executor`.

### Filmstrip thumbnail loading

Three triggers:

| Trigger | Range | Source |
|---|---|---|
| Navigation (`_preload_thumbnails`) | current index ±10 | `viewer.py:1269` |
| Filmstrip scrolled (visible range changed) | visible range ±5 | `viewer.py:1273` |
| Background sweep (`_preload_all_thumbnails`) | the whole list | `viewer.py:1288` |

The background sweep starts at the current index, walks forward, wraps to 0 at
the end, and stops when it comes back round to where it started
(`viewer.py:1301`). It processes **5 indices per 100 ms tick**. It is restarted
from the new position on filmstrip clicks, after a filter change, after a mode
switch and after a folder load; it is stopped on folder close and on window
close.

Note: the wrap-around check is `self._bg_preload_wrapped and idx >= self._bg_preload_start`.
If the user navigates while the sweep is running, `_bg_preload_start` is reset
but `_bg_preload_idx` also restarts, so the sweep simply begins again. Work is
duplicated but not lost.

### Grid thumbnail loading (`_on_grid_visible_range`, `viewer.py:1070`)

| Property | Value |
|---|---|
| Load range | visible first-10 through visible last+10 |
| Eviction | any cached grid thumbnail whose index is more than 100 outside the load range is dropped |
| Background sweep | none — grid thumbnails are only ever loaded for what is near the viewport |

This is what keeps a 200 px grid over a 3000-image folder bounded in memory.

### Secondary thumbnail production

When a full preview finishes loading, if the filmstrip does not already have a
thumbnail for that index, an 80 px thumbnail is derived from the preview with
fast transformation and pushed into the filmstrip (`viewer.py:1057`). This
bypasses the disk cache entirely — that thumbnail is never written to disk.
Note: minor inconsistency, harmless.

### Rating side effect in the thumbnail loaders

Both `_preload_thumb` (`viewer.py:1214`) and `_preload_grid_thumb`
(`viewer.py:1086`) read the XMP rating from disk for their index if it is not
already in memory, and write it into `self.ratings` from the worker thread.
This is the main way ratings get populated during normal browsing.

Note: `self.ratings` is a plain dict mutated from four worker threads plus the
UI thread without holding `self.lock`. CPython's GIL makes individual dict
assignments atomic so this does not corrupt, but it is not a pattern to port.

---

## 8. In-memory preview cache — `LruByteCache` (`pixmap_cache.py`)

An `OrderedDict`-backed LRU bounded by total cost in bytes.

| Operation | Semantics | Source |
|---|---|---|
| `get(key)` | returns the value and moves it to the most-recent end; `None` if absent | `pixmap_cache.py:15` |
| `put(key, value, cost)` | replacing an existing key first subtracts its old cost; then inserts at the most-recent end | `pixmap_cache.py:22` |
| Eviction | while total cost exceeds the budget **and** more than one entry remains, pop the least recent | `pixmap_cache.py:28` |
| Never empty | a single entry is kept even if it alone exceeds the budget | `pixmap_cache.py:28` |
| `in` | membership test, does **not** refresh recency | `pixmap_cache.py:32` |
| `clear()` | drops everything and resets the total | `pixmap_cache.py:35` |

Keys are `Path` objects. Cost is estimated as `width * height * 4`
(`viewer.py:1051`), i.e. 32-bit RGBA, which is an upper bound for the actual Qt
pixmap.

Budget: 1,500,000,000 bytes (`viewer.py:461`). At 2560 x 1707 x 4 = ~17.5 MB per
preview, that is roughly 85 cached previews per mode.

Test coverage in `tests/test_pixmap_cache.py` pins: LRU eviction order
(`:13`), that `get` refreshes recency (`:22`), that re-putting a key updates its
cost rather than double-counting (`:32`), and that the last item is never
evicted (`:41`).

### Cache invalidation

The cache is cleared on folder load (`viewer.py:1626`) and folder close
(`viewer.py:1708`). It is **not** cleared on filter change or mode switch —
each mode carries its own cache instance, and filtering does not change paths.

---

## 9. Disk thumbnail cache — `ThumbnailCache` (`thumbnail_cache.py`)

| Property | Value | Source |
|---|---|---|
| Directory | `~/.cache/raw-viewer/thumbs`, created on init | `thumbnail_cache.py:14` |
| Key | `md5("{absolute path}:{size}")` as lowercase hex | `thumbnail_cache.py:18` |
| Image file | `{key}.jpg` | `thumbnail_cache.py:23` |
| Validity file | `{key}.mtime`, containing the source file's mtime as a decimal string | `thumbnail_cache.py:28` |
| Read | both files must exist; the stored mtime must equal the source's current mtime exactly; otherwise treated as a miss | `thumbnail_cache.py:33` |
| Write | writes the JPEG then the mtime file; `OSError` is silently swallowed | `thumbnail_cache.py:52` |
| Format / quality | JPEG at quality 85 | `preview.py:240` |
| Eviction | none. Nothing ever deletes entries | — |
| `invalidate` | exists, deletes both files, **never called** | `thumbnail_cache.py:64` |

Because the size is part of the key, 80 px and 200 px thumbnails coexist with no
collision — this is what let grid view reuse the cache with no schema change.

Note: the cache grows forever. Two files per image per size, so a user who has
culled 50,000 images in both filmstrip and grid has 200,000 files in one flat
directory. Note: known tech debt. A rewrite should add a size cap or an age
policy, and use a single file per entry with the mtime as an extended attribute
or in the filename.

Note: the write is not atomic. A crash between the JPEG write and the mtime
write leaves an orphan `.jpg` that will never be read (the `.mtime` is missing,
so `get` returns `None`) and never cleaned up.

---

## 10. Size limits summary

| Limit | Value | Enforced where |
|---|---|---|
| Preview long edge | 2560 px | `preview.py:114`, `:333` |
| Filmstrip thumb | 80 px long edge | `viewer.py:1226` |
| Grid thumb | 200 px long edge; also re-scaled down on arrival if larger | `viewer.py:1098`, `:1121` |
| Memory cache | 1.5 GB per mode | `viewer.py:461` |
| Grid thumbnails held | load range ±100 indices | `viewer.py:1075` |
| Disk thumbnail cache | unbounded | — |
| Date cache | unbounded | — |
