# 05 — Ratings, XMP Sidecars, Rejection and Shoot Stats

Source modules: `rating.py`, `move_rejected.py`, `shoot_stats.py`, plus rating
handling in `viewer.py`.

---

## 1. Rating scale

| Value | Meaning | UI |
|---|---|---|
| `-1` | rejected | red `✕` badge, info line reads `"✕ rejected"` |
| `0` | unrated | five hollow stars `☆☆☆☆☆`, no badge |
| `1`–`5` | stars | that many yellow dots, info line `★★★☆☆` etc. |

`0` and "no sidecar at all" are indistinguishable in the UI. `read_rating`
returns `None` when there is no sidecar or no rating attribute, and every caller
converts that to `0` (`viewer.py:1096`, `:1223`, `:1345`, `:1383`, `:1476`).

Writing is clamped to `[-1, 5]` (`rating.py:44`). Test: `tests/test_rating.py:33`
asserts `write_rating(-5)` reads back as `-1` and `write_rating(9)` as `5`.

---

## 2. Sidecar file naming

`get_xmp_path(raw_path)` returns `raw_path.with_suffix('.xmp')`
(`rating.py:19`).

This **replaces** the extension, it does not append. So:

| Source file | Sidecar |
|---|---|
| `IMG_0001.CR3` | `IMG_0001.xmp` |
| `DSCF0002.RAF` | `DSCF0002.xmp` |
| `photo.jpg` | `photo.xmp` |
| `clip.MOV` | `clip.xmp` |
| `a.b.cr2` | `a.b.xmp` (only the last suffix is replaced) |

This matches Lightroom Classic's convention for RAW files. It does **not** match
Lightroom's convention for JPEGs (Lightroom writes JPEG metadata into the file,
not a sidecar), but the app writes sidecars for JPEGs and videos anyway so the
Resolve export has a consistent source.

Consequence to be aware of: a RAW file and a JPEG with the same stem in the same
directory share one sidecar file and will overwrite each other's rating. Note:
likely unintended, and a real risk since shoot-in-RAW+JPEG is common. The
move-rejected code explicitly treats those two as a pair
(`move_rejected.py:11`), so the situation is known to occur.

---

## 3. The XMP template, byte for byte

`rating.py:9`. This is the exact string written when no sidecar exists, with
`{rating}` substituted. No trailing newline is added.

```
<?xml version="1.0" encoding="UTF-8"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
  <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    <rdf:Description rdf:about=""
      xmlns:xmp="http://ns.adobe.com/xap/1.0/"
      xmp:Rating="{rating}"/>
  </rdf:RDF>
</x:xmpmeta>
```

Encoding: UTF-8, written with `Path.write_text(..., encoding='utf-8')`
(`rating.py:74`). Line endings are `\n`. Indentation is two spaces per level as
shown. The `rdf:Description` element is self-closing with the attributes on
three lines, the continuation lines indented six spaces.

A rating of 3 produces exactly:

```
<?xml version="1.0" encoding="UTF-8"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
  <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    <rdf:Description rdf:about=""
      xmlns:xmp="http://ns.adobe.com/xap/1.0/"
      xmp:Rating="3"/>
  </rdf:RDF>
</x:xmpmeta>
```

Note what is deliberately absent: no `<?xpacket?>` wrapper, no `x:xmptk`
toolkit attribute, no padding whitespace, no `xmp:Label`, no `dc:` block, no
`crs:` develop settings. This is the minimum Lightroom will accept.

---

## 4. Reading a rating (`read_rating`, `rating.py:24`)

1. If the sidecar does not exist, return `None`.
2. Read the whole file as UTF-8 text.
3. Regex search for `xmp:Rating=["'](-?\d)["']`.
4. Return the captured group as an int, or `None` if there is no match.
5. Any exception returns `None`.

Note: the pattern matches exactly **one** digit. A rating of `10` would parse as
`1`. Harmless given the clamp, but a sidecar written by another tool using
`xmp:Rating="5.0"` would parse as `5` and leave `.0` behind on a rewrite
(see below).

Note: this is a regex over raw text, not an XML parse. A sidecar with
`xmp:Rating` inside an XML comment, or a `crs:Rating` attribute, could produce a
wrong read. In practice Lightroom sidecars are matched correctly.

---

## 5. Writing a rating (`write_rating`, `rating.py:41`)

Clamp to `[-1, 5]`, then:

**If the sidecar does not exist**: write the template.

**If it exists**, read it and take the first matching branch:

1. If `xmp:Rating=["']?-?\d["']?` matches anywhere, substitute the digit in
   place, preserving whatever quoting was there (`rating.py:52`). The regex
   captures the prefix including the opening quote and the closing quote
   separately, so `xmp:Rating="3"` becomes `xmp:Rating="4"` and an unquoted
   `xmp:Rating=3` becomes `xmp:Rating=4`. Every occurrence in the file is
   replaced, not just the first.
2. Otherwise, if the text contains `rdf:Description`, insert a new attribute
   after the first `<rdf:Description` opening tag prefix, as a newline plus six
   spaces plus `xmp:Rating="{rating}"` (`rating.py:59`). Only the first
   occurrence is modified.
3. Otherwise the file is considered malformed and is **overwritten** with the
   template, discarding all existing content (`rating.py:68`).

Returns `True` on success. On exception, prints
`Error writing XMP for {path}: {e}` and returns `False` (`rating.py:77`).

Note: branch 3 destroys metadata. A sidecar written by another tool that uses a
different structure (no `rdf:Description`, e.g. an `rdf:li` list form) loses
everything. Note: likely unintended but deliberate-looking ("Malformed XMP,
create new").

Note: branch 1 substitutes a single digit, so updating a sidecar containing
`xmp:Rating="5.0"` yields `xmp:Rating="4.0"` — the trailing `.0` survives.

Test coverage: round-tripping 0 through 5 (`tests/test_rating.py:6`), writing
and reading `-1` including asserting the literal string `xmp:Rating="-1"`
appears in the file (`tests/test_rating.py:14`), and updating an existing
sidecar from a star to a reject and back (`tests/test_rating.py:23`).

---

## 6. Lightroom compatibility

- `xmp:Rating` in the `http://ns.adobe.com/xap/1.0/` namespace is the standard
  star-rating field. Lightroom Classic reads it from a sidecar on
  "Metadata > Read Metadata from File" and on import.
- `xmp:Rating="-1"` is Adobe's convention for a rejected photo. Lightroom shows
  it as the reject flag.
- The sidecar must sit next to the RAW file with the same stem, which it does.
- Lightroom will **not** pick up a change automatically; the user has to read
  metadata from file, or import the folder fresh.
- The app never writes `xmp:Label` (colour labels) or `dc:subject` (keywords).

---

## 7. Where the rating lives in memory

`self.ratings: Dict[int, int]` maps an index into `all_files` to the rating
(`viewer.py:470`). Not into `files` — into the **unfiltered** list. Every read
goes through `self.path_index[path]` to get that index
(`viewer.py:1380`).

Population happens lazily, from four places:

| Trigger | Scope | Source |
|---|---|---|
| Loading the current image | that one file | `viewer.py:1381` |
| Loading a filmstrip thumbnail | that one file, on a worker thread | `viewer.py:1221` |
| Loading a grid thumbnail | that one file, on a worker thread | `viewer.py:1094` |
| `_load_all_ratings()` | every file in `all_files` | `viewer.py:1471` |

`_load_all_ratings` is a synchronous, blocking, whole-folder disk sweep. It is
called before applying a non-zero rating filter (`viewer.py:1531`), on `Shift+R`
(`viewer.py:2384`), before a Resolve export (`viewer.py:2114`) and before
move-rejected (`viewer.py:2446`). On a large folder over a network share this
will visibly freeze the UI. Note: known tech debt.

Ratings are cleared on folder load (`viewer.py:1627`) and folder close
(`viewer.py:1709`), and are carried per mode in the mode state bundle
(`viewer.py:1759`).

---

## 8. Writing asynchronously

`_set_rating` updates memory and UI immediately, then submits the disk write to
the single-worker `rating_executor` (`viewer.py:2497`).

`_write_rating_task` (`viewer.py:2519`) runs on that worker:

1. `write_rating(path, rating)`.
2. If the mode is `"jpeg"` or `"video"`, also `set_green_tag(path, rating > 0)`.
3. If the write failed, emit a signal that shows a snackbar.

One worker means writes to the same path serialise in submission order, and each
write is a complete value, so last-write-wins is correct.

The executor is shut down with `wait=True` in `closeEvent` (`viewer.py:2585`) so
pending sidecars flush before the app exits, and is flushed before
move-rejected by submitting a no-op and blocking on its result
(`viewer.py:2447`).

---

## 9. macOS Finder tags (JPEG and video modes only)

`rating.py:82`. Attribute key: `com.apple.metadata:_kMDItemUserTags`.

| Operation | Mechanism | Source |
|---|---|---|
| Read | `xattr -px com.apple.metadata:_kMDItemUserTags <path>`, strip spaces and newlines, hex-decode, parse as a plist | `rating.py:86` |
| Has green | any tag string containing the substring `"Green"` | `rating.py:101` |
| Add green | append the literal string `"Green\n2"` to the tag list | `rating.py:83`, `:113` |
| Remove green | drop every tag containing `"Green"` | `rating.py:115` |
| Persist non-empty | `xattr -wx <key> <binary-plist-as-hex> <path>` | `rating.py:120` |
| Persist empty | `xattr -d <key> <path>` — removes the attribute entirely | `rating.py:126` |
| No change needed | returns early without touching the file | `rating.py:117` |
| Errors | printed, returns `False` | `rating.py:131` |

The `"Green\n2"` form is Apple's tag encoding: tag name, newline, colour index
(2 = green).

Note: `has_green_tag` is defined but never called. Note: dead code.

Note: in RAW mode no Finder tag is written. The green tag exists so that a JPEG
or video cull is visible in Finder, where XMP sidecars are invisible.

---

## 10. Reject and move-rejected

### Rejecting

`X` toggles the focused image between `-1` and `0` (`viewer.py:2343`). It writes
the same sidecar as a star rating, with value `-1`. It auto-advances like a
star. In JPEG and video modes it also clears the green Finder tag, since
`rating > 0` is false.

Pressing any star key on a rejected image overwrites the reject.

### The move operation — `move_rejected.py`

Directory name: the constant `REJECTED_DIR_NAME = "_rejected"`
(`move_rejected.py:7`). The same constant is what the scanner prunes
(`scanner.py:208`).

**`find_siblings(file)`** (`move_rejected.py:10`): every other file in the same
directory whose `stem.lower()` equals this file's `stem.lower()`. Directories
are excluded. This is what keeps `IMG_0001.CR3`, `IMG_0001.jpg` and
`IMG_0001.xmp` together. Test: `tests/test_move_rejected.py:13`.

**`collect_move_set(rejected)`** (`move_rejected.py:19`): for each rejected file,
emit the file then its siblings, deduplicated, preserving first-seen order. A
RAW/JPEG pair that are both rejected appears once each, not twice. Test:
`tests/test_move_rejected.py:22`.

**`move_to_rejected(files, root)`** (`move_rejected.py:31`):

- For each file, compute its path relative to `root`; if it is not under `root`,
  fall back to just the filename.
- Destination is `root/_rejected/<relative path>`, so subfolder structure is
  preserved. Test: `tests/test_move_rejected.py:29` asserts
  `day1/IMG_0001.cr3` lands at `_rejected/day1/IMG_0001.cr3`.
- Create the destination's parent directory tree as needed.
- `shutil.move` the file.
- On the first `OSError`, stop immediately and return `(moved_so_far, "name: error")`.
  Later files are untouched. Test: `tests/test_move_rejected.py:37`.
- Returns `(count, "")` on full success.

**Conflicts**: `shutil.move` onto an existing destination file overwrites it
silently on the same filesystem. There is no unique-name generation, no
`" copy"` suffix, no prompt. A second move-rejected run that hits the same
destination name replaces the earlier file. Note: likely unintended — a rewrite
should disambiguate.

**Reversibility**: files are moved, never deleted. Restoring is a manual Finder
drag.

### The UI flow

See `01` section 23. Key detail: after a successful move the app rescans the
folder from scratch, which rebuilds `all_files`, `path_index`, ratings and the
filmstrip (`viewer.py:2467`).

### Mac app addition: move shown files to a folder

No Python-app equivalent. "Move Shown Files to Folder…" (File menu,
`Shift+Cmd+M`) moves every file of the current filtered timeline (`files` for
the active mode, which may span several subfolders) into one folder the user
picks, flat — no subfolder structure is recreated.

- The user picks a destination via an open panel (folders only, can create a
  new one).
- Pending sidecar writes are flushed first, then the move runs off the main
  thread and the folder is rescanned afterwards, the same as move-rejected.
- Only the file itself and its XMP sidecar (`<stem>.xmp`, same directory) move.
  A JPEG/RAW sibling that is not itself part of the filtered list is left
  behind.
- A destination-name collision gets a ` 2`, ` 3`… suffix, same as
  move-rejected. When the file has a sidecar, the sidecar is renamed to the
  same numbered stem so the rating stays attached to the right file.
- A RAW and JPEG that share one sidecar move it once, with whichever of the
  two is processed first.
- A file already sitting in the destination folder is skipped.
- Stops at the first OS error, same convention as move-rejected.
- An empty filtered list is a no-op with a snackbar, same as "No rejected
  files".

---

## 11. Shoot selection timer and stats

`shoot_stats.py` plus timer state in `viewer.py:515`.

### The model

| Field | Meaning | Source |
|---|---|---|
| `_shoot_persisted_elapsed` | seconds accumulated in previous sessions on this folder | `viewer.py:516` |
| `_shoot_session_start` | wall-clock time this session began, or `None` when no folder is open | `viewer.py:515` |
| `_shoot_rated_count` | how many files currently have `rating > 0` | `viewer.py:518` |
| `_shoot_last_rating_elapsed` | total elapsed at the moment the rated count last changed | `viewer.py:517` |

Total elapsed = `_shoot_persisted_elapsed + (now - _shoot_session_start)`
(`viewer.py:2057`).

### When the counters move (`viewer.py:2502`)

On every rating change, if a shoot is active:

- previous rating `<= 0` and new rating `> 0` → `rated_count += 1`
- previous rating `> 0` and new rating `<= 0` → `rated_count -= 1`, floored at 0
- otherwise no change

Rejecting (`-1`) counts as unrating. Changing 3 stars to 4 stars does not move
the counter and does not update `last_rating_elapsed`.

When the counter changes, `last_rating_elapsed` is set to the current total
elapsed, stats are written to disk, and the overlay refreshes.

### Displayed values

See `01` section 6. `Avg/rate` is `last_rating_elapsed / rated_count`, printed
with one decimal and an `s` suffix (`viewer.py:2095`). So it is the average
seconds per rated image measured from folder open to the last rating, not a
rolling average.

### Persistence

| Property | Value | Source |
|---|---|---|
| File | `~/.cache/raw-viewer/shoot_stats.json` | `shoot_stats.py:8` |
| Shape | `{ "<absolute folder path>": {"elapsed": float, "rated_count": int, "last_rating_elapsed": float or null} }` | `shoot_stats.py:40` |
| Written | on every rated-count change, on folder close, on window close | `viewer.py:2513`, `:1729`, `:2580` |
| Read | on folder load; missing or malformed entries start a fresh shoot | `viewer.py:1645`, `shoot_stats.py:23` |
| Eviction | none | — |
| Errors | swallowed | `shoot_stats.py:18`, `:49` |

The whole file is rewritten on every save. Folders are keyed by absolute path,
so renaming or moving a shoot folder loses its timer.

Note: the timer keeps running while the app is idle or in the background. It
measures wall-clock time from opening the folder, not active culling time.
That is the intended design — it answers "how long did this shoot take me".

Note: `_shoot_rated_count` is only ever adjusted by deltas from ratings made in
this session. It is seeded from the persisted value, not recomputed from the
actual sidecars. If sidecars change outside the app, the count drifts. Note:
likely unintended.
