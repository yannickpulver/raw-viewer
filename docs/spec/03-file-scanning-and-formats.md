# 03 — File Scanning, Formats and Sorting

Source module: `scanner.py`.

---

## 1. Supported extensions

Matching is case-insensitive: the file's suffix is lowercased before the set
lookup (`scanner.py:60`).

### RAW — 28 extensions (`scanner.py:43`)

```
.cr2  .cr3  .nef  .arw  .raf  .orf
.rw2  .dng  .pef  .srw  .3fr  .ari
.bay  .crw  .dcr  .erf  .fff  .mef
.mrw  .nrw  .ptx  .pxn  .r3d  .rwl
.rwz  .sr2  .srf  .x3f
```

### JPEG — 2 extensions (`scanner.py:51`)

```
.jpg  .jpeg
```

Note: `.heic`, `.png`, `.tif` and `.tiff` are not supported in any mode.

### Video — 3 extensions (`scanner.py:53`)

```
.mov  .mp4  .m4v
```

---

## 2. What is skipped

| Rule | Detail | Source |
|---|---|---|
| macOS resource forks | any filename starting with `._` is rejected in all three predicates | `scanner.py:58`, `:65`, `:71` |
| Rejected bin | any directory named exactly `_rejected` is pruned from the walk, at every depth | `scanner.py:208`, `move_rejected.py:7` |

There is no hidden-file filter beyond `._`, no `.DS_Store` special case (it has
no matching extension), no depth limit, and no symlink handling beyond whatever
`os.walk` does by default (it does not follow directory symlinks).

Test coverage: `tests/test_move_rejected.py:47` asserts that a file inside
`_rejected/` is not returned by `scan_folder`.

---

## 3. Recursive scan

`_scan_and_sort` (`scanner.py:196`):

1. Raise `ValueError("Not a directory: {folder}")` if the path is not a
   directory.
2. Walk the tree with `os.walk`, pruning `_rejected` directories in place.
3. Collect every file whose path satisfies the type predicate.
4. If nothing matched, return the empty list immediately — no date work, no
   cache write.
5. Otherwise compute a capture timestamp for every matched file, reporting
   progress every 5 files and on the last one (`scanner.py:221`).
6. Persist the date cache to disk.
7. Return the files sorted ascending by `(timestamp, path)`.

The three public entry points are `scan_folder`, `scan_folder_jpeg` and
`scan_folder_video` (`scanner.py:228`–`:239`). They differ only in the
predicate. Only the RAW scan is given a progress callback by the viewer
(`viewer.py:1580`).

Each scan walks the tree independently, so opening a folder walks it three
times.

---

## 4. Sort order

`sorted(zip(dates, matched))` (`scanner.py:225`).

Primary key: capture timestamp, ascending — oldest first.

Tie-break: the `Path` object itself. `pathlib.PurePath` compares by its
case-folded string parts on macOS, so files with identical timestamps end up in
path order. This is deterministic but is an implementation artefact rather than
a deliberate rule; a rewrite should sort by `(timestamp, path string)`
explicitly.

---

## 5. How the capture date is determined

`get_creation_time(path, use_cache=True)` (`scanner.py:171`):

1. `stat()` the file, take `st_mtime`.
2. If caching is on and the path is in the in-memory date cache with a matching
   mtime, return the cached timestamp.
3. Otherwise read EXIF `DateTimeOriginal`.
4. If that fails, fall back to `st_birthtime`, and if that attribute is absent,
   to `st_mtime`.
5. Store `(mtime, timestamp)` in the cache under the absolute path string.

### EXIF reading

`_read_exif_timestamp` (`scanner.py:137`):

- For `.raf` and `.cr3`, first extract an embedded blob (below) and parse EXIF
  out of that blob instead of the file itself.
- For everything else, parse the file directly.
- Parsing stops at the `DateTimeOriginal` tag and skips maker-note details
  (`scanner.py:148`).
- The first of `EXIF DateTimeOriginal` then `Image DateTimeOriginal` wins
  (`scanner.py:77`).
- The value is parsed with the format `%Y:%m:%d %H:%M:%S` and converted to a
  POSIX timestamp in the **local** time zone (`scanner.py:151`).
- Any exception at any point returns `None`.

Note: the EXIF timestamp carries no time zone. Interpreting it as local time
means the sort order can shift if the machine's time zone changes. This matters
only for sorting and for the displayed date string.

### RAF embedded blob (`scanner.py:105`)

Fujifilm RAF files do not expose a top-level TIFF header that exifread can
parse. The code:

1. Reads the first 16 bytes and requires them to equal `FUJIFILMCCD-RAW `
   (note the trailing space) (`scanner.py:75`).
2. Seeks to offset 84 and reads two big-endian `uint32`s: the embedded JPEG's
   offset and length.
3. Reads that many bytes from that offset and parses them as a JPEG.

Test: `tests/test_scanner.py:50` builds a synthetic RAF with a JPEG at offset
148 and asserts the date comes out.

### CR3 embedded blob (`scanner.py:116`)

Canon CR3 is an ISO base media file. The ExifIFD lives as a raw TIFF blob at
`moov > uuid(Canon) > CMT2`. The code:

1. Walks top-level boxes to find `moov` (`scanner.py:80`, `:98`).
2. Inside `moov`, walks boxes looking for a `uuid` box whose first 16 payload
   bytes equal `85c0b687820f11e08111f4ce462b6a48` (`scanner.py:76`).
3. Inside that uuid box, past the 16 UUID bytes, finds the `CMT2` box.
4. Returns its payload, which is parsed as a TIFF/EXIF blob.

The box walker handles 64-bit sizes (`size == 1`, size in the next 8 bytes) and
extend-to-end boxes (`size == 0`), and bails out on a size smaller than the
header (`scanner.py:92`).

Test: `tests/test_scanner.py:56`.

### Fallback test

`tests/test_scanner.py:68` asserts that a file that cannot be parsed falls back
to `st_birthtime`, or `st_mtime` when birthtime is unavailable.

### Rewrite note

Both blob extractors exist only because `exifread` cannot read RAF or CR3.
ImageIO on macOS reads `kCGImagePropertyExifDateTimeOriginal` from both formats
directly. The *rule* (prefer `DateTimeOriginal`, fall back to birthtime, then
mtime) must be reproduced. The parsing mechanism must not.

---

## 6. Date cache

| Property | Value | Source |
|---|---|---|
| Location | `~/.cache/raw-viewer/dates_v2.json` | `scanner.py:18` |
| Format | JSON object, `{absolute path string: [mtime, timestamp]}` | `scanner.py:17` |
| Loaded | once at module import | `scanner.py:41` |
| Saved | at the end of every non-empty scan | `scanner.py:224` |
| Invalidation | an entry is used only when the stored mtime equals the file's current mtime | `scanner.py:180` |
| Eviction | none; the file grows without bound | — |
| Errors | load and save failures are swallowed; a corrupt file resets the cache to empty | `scanner.py:27`, `:36` |

Note: entries for deleted files are never removed, and the whole file is
rewritten on every scan. For a user who culls many large shoots this file grows
indefinitely. Note: known tech debt.

The `_v2` suffix implies a prior format existed; `dates.json` is not read or
cleaned up.

---

## 7. Subfolder derivation

`subfolder_name(path, root)` (`scanner.py:157`):

- Take the file's parent directory relative to the scan root.
- If it has at least one path component, return the **first** one.
- If the file sits directly in the root (the relative path is empty), return the
  root directory's own basename.
- If the file is not under the root at all (`ValueError`), return the parent
  directory's basename.

So a file at `<root>/DJI/DCIM/100MEDIA/x.dng` belongs to the chip `DJI`, and a
file at `<root>/x.raf` belongs to a chip named after the root folder itself.

`subfolder_counts(files, root)` (`scanner.py:166`) returns
`[(name, count), ...]` sorted by name.

Test: `tests/test_scanner.py:75` pins the root-level case for `subfolder_counts`,
`tests/test_scanner.py:89` pins the empty-input case returning `[]`, and
`tests/test_scanner.py:94` pins the same root-level behaviour directly on
`subfolder_name`.

Chips render only when there is more than one distinct name
(`viewer.py:1905`).

---

## 8. Excluded folders

`excluded_folders` is a `Set[str]` of first-level subfolder names
(`viewer.py:475`). A file is hidden from the `All` view when its subfolder name
is in that set and no explicit `folder_filter` is active (`viewer.py:1520`).

| Property | Behaviour | Source |
|---|---|---|
| Scope | per view mode; stored in that mode's state bundle | `viewer.py:1750` |
| Reset on folder load | yes, cleared to empty | `viewer.py:1642` |
| Reset on folder close | yes | `viewer.py:1724` |
| Persisted to disk | **no** | — |

So exclusions last only until the folder is reopened. If the rewrite is meant to
remember exclusions per folder, that is new behaviour and must be decided
explicitly.

---

## 9. File identity

Files are identified by their `pathlib.Path` object, which compares and hashes
by its string form.

| Structure | Key | Source |
|---|---|---|
| `path_index` | `Path` → index in `all_files` | `viewer.py:467`, `:1778` |
| `ratings` | index in `all_files` → int | `viewer.py:470` |
| preview `cache` | `Path` → `QPixmap` | `viewer.py:1052` |
| filmstrip / grid thumbnails | index in the **filtered** list → `QPixmap` | `viewer.py:1059` |
| disk thumbnail cache | `md5("{path}:{size}")` | `thumbnail_cache.py:18` |
| date cache | absolute path string | `scanner.py:191` |

Two things to carry over carefully:

1. Ratings are keyed by position in `all_files`, not by path. Any operation that
   rebuilds `all_files` must rebuild `path_index` and clear `ratings`
   (`viewer.py:1627`, `:1638`).
2. Thumbnail dictionaries are keyed by position in the **filtered** list, which
   is why every filter change and mode switch clears them
   (`viewer.py:1492`, `:1801`).

A rewrite would be considerably safer keying everything by file URL.

---

## 10. No RAW + JPEG pairing

The scanner does **not** group a RAW file with its same-stem JPEG. RAW and JPEG
are two entirely separate lists, browsed in two separate modes.

The only place same-stem grouping exists is the move-rejected operation, which
collects all same-stem siblings in the same directory so that RAW/JPEG pairs and
`.xmp` sidecars move together (`move_rejected.py:10`). Matching there is on
`stem.lower()`. See `05`.
