# 01 — Features and UX

All line citations are against the repo at version `0.4.5`.

---

## 1. Window

| Property | Value | Source |
|---|---|---|
| Class | single `QMainWindow`, no document windows, no tabs | `viewer.py:460` |
| Initial size | 1400 x 900 | `viewer.py:978` |
| Window title (OS level) | `"RAW Viewer"`, never changed | `viewer.py:976` |
| Background | solid black | `viewer.py:977` |
| Title bar | transparent, full-size content view, system title hidden | `viewer.py:2534` |
| Accepts file drops | yes | `viewer.py:980` |

The title bar is made transparent on macOS by setting the
`NSWindowStyleMaskFullSizeContentView` bit (`1 << 15`),
`titlebarAppearsTransparent = true` and `titleVisibility = NSWindowTitleHidden`
(`viewer.py:2543`). It is configured once, on the first `showEvent`, via a
zero-delay timer (`viewer.py:2527`).

Because the system title is hidden, the app draws its own centred title label.

### Custom title label

| Property | Value | Source |
|---|---|---|
| Text | `"RAW Viewer"` / `"JPEG Viewer"` / `"Video Viewer"` by view mode | `viewer.py:1805` |
| Colour | `rgba(255,255,255,120)` | `viewer.py:824` |
| Font | SF Pro Text / Helvetica Neue, 13 px, weight 500 | `viewer.py:826` |
| Padding | `0px 12px` | `viewer.py:825` |
| Position | horizontally centred, `y = 6` | `viewer.py:2214` |

The title reverts to `"RAW Viewer"` when the folder is closed (`viewer.py:1738`)
and when a rescan completes while a non-RAW mode was active (`viewer.py:1622`).

### Window dragging

Because the title bar is transparent and content extends into it, the app
implements its own drag: a left mouse press anywhere with `y < 40` starts a
window drag; mouse move relocates the window; release ends it
(`viewer.py:2243`, `:2258`, `:2266`).

---

## 2. Two orthogonal mode axes

There are two independent mode variables. Understanding this is essential.

### `view_mode` — which file type is being culled

`"raw"` | `"jpeg"` | `"video"`. Default `"raw"` (`viewer.py:478`).

Each of the three has its own complete, independent state bundle
(`viewer.py:1746`):

| Key | Meaning |
|---|---|
| `files` | currently visible (filtered) list |
| `all_files` | unfiltered scan result for that mode |
| `index` | selected position within `files` |
| `cache` | its own `LruByteCache`, 1.5 GB budget |
| `ratings` | original-index → rating map |
| `min_rating_filter` | 0 = all, 1..5 = minimum, -1 = rejected only |
| `folder_filter` | subfolder name or `None` |
| `excluded_folders` | set of subfolder names excluded from "All" |

Switching modes saves the active bundle and loads the target's
(`viewer.py:1752`, `:1765`). Selection, filter and rating state therefore
survive a round trip between RAW and JPG.

Note: each mode owning a separate 1.5 GB cache means the app's preview cache
budget is effectively 4.5 GB across all three modes. Note: likely unintended.

### `display_mode` — how the current list is presented

`"single"` | `"grid"`. Default `"single"` (`viewer.py:593`). Toggled with `G`.

---

## 3. Layout

The central widget is a vertical stack with zero margins and zero spacing
(`viewer.py:522`):

```
+--------------------------------------------------+
|  content_stack  (stretch 1)                      |
|    page 0: image_splitter [compare | image]      |
|    page 1: video_container [video | timeline]    |
|    page 2: grid                                  |
+--------------------------------------------------+
|  filmstrip  (fixed height 124)                   |
+--------------------------------------------------+
```

Everything else (overlays, buttons, labels) is a child of the main window
positioned absolutely, floating above the stack.

### Page 0 — image view

A horizontal `QSplitter` holding two `ZoomableImageView`s
(`viewer.py:532`). The left one (`compare_view`) is hidden unless compare mode
is active. The right one (`image_view`) is the normal viewer.

Each `ZoomableImageView` is a `QGraphicsView` with a black background, no
border, no scrollbars, smooth pixmap transform, and transformation anchored
under the mouse (`viewer.py:71`–`:76`).

### Page 1 — video

A black container with the video surface on top (stretch 1) and a timeline row
below (`viewer.py:543`).

| Element | Value | Source |
|---|---|---|
| Timeline row background | `rgba(20,20,20,220)` | `viewer.py:555` |
| Timeline row margins | 10 / 4 / 10 / 4 | `viewer.py:557` |
| Slider groove | 4 px high, `#333`, radius 2 | `viewer.py:560` |
| Slider handle | 12 x 12, white, radius 6, margin `-4px 0` | `viewer.py:561` |
| Slider filled portion | `#888` | `viewer.py:562` |
| Time label | `"M:SS / M:SS"`, `#aaa`, Menlo 11 px, padding `0 8px`, fixed width 100 | `viewer.py:564` |

### Page 2 — grid

See section 8.

### Filmstrip

| Property | Value | Source |
|---|---|---|
| Thumbnail cell | 80 x 80 | `viewer.py:222` |
| Spacing between cells | 4 | `viewer.py:223` |
| Item stride | 84 | derived |
| Content widget height | 100 (`THUMB_SIZE + 20`) | `viewer.py:270` |
| Scroll area fixed height | 124 (`THUMB_SIZE + 44`) | `viewer.py:376` |
| Background | `rgba(0,0,0,200)` | `viewer.py:382` |
| Cell background (unloaded) | `rgb(40,40,40)` | `viewer.py:311` |
| Strip background behind cells | `rgb(20,20,20)` | `viewer.py:298` |
| Top padding before thumbs | `y = 4` | `viewer.py:302` |
| Horizontal scrollbar | always on, 18 px high, margin `0 8px 8px 8px` | `viewer.py:383` |
| Scrollbar handle | `#777`, radius 5, min width 40; `#999` on hover | `viewer.py:384` |
| Scrollbar track | `#222`, radius 5 | `viewer.py:387` |

Thumbnails are centred in their cell both horizontally and vertically
(`viewer.py:307`).

**Selection marker**: a 3 px white (`rgb(255,255,255)`) rectangle drawn at
`(x-2, y-2, 84, 84)` around the current cell (`viewer.py:315`).

**Rating dots**: for rating 1..5, that many filled 5 x 5 ellipses in
`rgb(255,200,50)`, spaced 8 px apart, drawn at `y = 4 + 80 + 5 = 89`, centred
horizontally as `x + (80 - rating*8) / 2` (`viewer.py:320`).

**Reject badge**: for rating `-1`, a bold 12 px `✕` in `rgb(230,70,70)` drawn
centred in a 80 x 14 box at `y = 86` (`viewer.py:328`).

Only the visible index range is painted (`viewer.py:294`). Repaints triggered
by thumbnail arrival or rating change are batched behind a 50 ms single-shot
timer; selection changes repaint immediately (`viewer.py:242`, `:276`).

---

## 4. Overlays and floating chrome

All positions are relative to the window. Listed roughly top to bottom.

### Mode switcher (top-left)

Three checkable buttons, `RAW` / `JPG` / `MOV` (`viewer.py:892`).

| Property | Value | Source |
|---|---|---|
| Position | `(80, 8)` | `viewer.py:1844` |
| Spacing | 4 | `viewer.py:890` |
| Label when files exist | `"RAW (137)"` — label plus count | `viewer.py:1839` |
| Label when empty | bare `"RAW"`, button hidden | `viewer.py:1837` |
| Whole widget visible | only if at least one mode has files | `viewer.py:1843` |

The count for the active mode is `len(self.files)` (i.e. filtered), for the
others `len(mode_state[mode]["files"])` (i.e. that mode's own filtered list)
(`viewer.py:1832`).

Clicking a mode button switches directly to it. Unlike the `J` / `M` keys it
never toggles back to RAW, and it does nothing if that mode has no files
(`viewer.py:1781`).

### Subfolder chips (below the mode switcher)

| Property | Value | Source |
|---|---|---|
| Position | `(80, 8 + mode_switcher.height + 4)` | `viewer.py:1909` |
| Spacing | 4 | `viewer.py:908` |
| Visible when | more than one first-level subfolder **and** mode switcher visible | `viewer.py:1905` |

Chips are `All (N)` followed by one chip per first-level subfolder, sorted by
name, each labelled `name (count)` (`viewer.py:1898`). The `All` count is
`len(all_files)` minus the files in excluded subfolders (`viewer.py:1896`).

Note: the per-folder counts are raw scan counts and ignore the active rating
filter, while the position counter in the top right reflects the filter. They
can disagree. Note: likely unintended.

Left-click selects that subfolder as the only visible one (or `All`)
(`viewer.py:1911`). Right-click on a named chip (not `All`) opens a one-item
context menu reading `Exclude from All` or `Include in All`
(`viewer.py:1872`). An excluded chip renders with strike-through text and
colour `#666` (`viewer.py:1859`). Tooltip reflects the available action
(`viewer.py:1865`).

Excluding a folder removes its files from the `All` view but the chip itself
stays clickable, so you can still select that folder directly.

Tooltip text, verbatim: `"Right-click to exclude from All"` on an included
chip, `"Right-click to include in All"` on an excluded one (`viewer.py:1865`).

### Filter banner (top-left, `(10, 10)`)

Shown only when a rating filter is active (`viewer.py:1437`).

| Property | Value | Source |
|---|---|---|
| Text | `Filter: ≥3★  (42/137)` or `Filter: ✕  (5/137)` | `viewer.py:1440` |
| Background | `rgba(255,180,0,200)` | `viewer.py:642` |
| Text colour | black, bold, Menlo 12 px | `viewer.py:643` |
| Padding | `4px 10px` | `viewer.py:644` |

Note: this sits at `(10, 10)` and the mode switcher at `(80, 8)`; a wide filter
banner will overlap the mode buttons. Note: likely unintended.

### Update banner (`(10, 40)`)

| Property | Value | Source |
|---|---|---|
| Text | `Update available: 0.4.6` | `viewer.py:2608` |
| Background | `rgba(80,180,80,220)` | `viewer.py:656` |
| Text | white, Menlo 11 px, padding `4px 10px` | `viewer.py:657` |
| Cursor | pointing hand | `viewer.py:664` |

Clicking it runs `open <html_url>` on the release page (`viewer.py:2249`).
Note: the banner is positioned once and is never repositioned on resize
(`resizeEvent` does not touch it). Note: likely unintended, though `(10,40)` is
resize-independent so it is harmless.

### Position counter (top-right, `(width - w - 10, 10)`)

| Property | Value | Source |
|---|---|---|
| Base text | `"7/137"` | `viewer.py:1406` |
| Rating filter suffix | `"  (≥3★)"` or `"  (✕)"` | `viewer.py:1408` |
| Folder filter suffix | `"  [X100VI]"` | `viewer.py:1412` |
| Exclusion suffix (only when no folder filter) | `"  [excl. DJI, R5]"`, names sorted | `viewer.py:1414` |
| Style | transparent bg, white, Menlo 14 px, padding `6px 12px` | `viewer.py:617` |

Hidden when `show_info` is false, and entirely hidden when no files are loaded
(`viewer.py:1399`).

### Info line (below the counter, `(width - w - 10, 10 + pos_label.height)`)

Text is `"{filename}  |  {YYYY-MM-DD HH:MM}  |  {stars}"` (`viewer.py:1431`).

| Rating | Stars rendering | Source |
|---|---|---|
| `-1` | `"✕ rejected"` | `viewer.py:1428` |
| `0` | `"☆☆☆☆☆"` | `viewer.py:1430` |
| `1..5` | `"★" * r + "☆" * (5-r)` | `viewer.py:1430` |

The date comes from the same capture-time function used for sorting
(`viewer.py:1423`, see `03`). Style: transparent, white, Menlo 12 px, padding
`6px 12px` (`viewer.py:606`).

Toggled together with the position counter by `I`.

### Thumbnail loading progress (below the info line)

| Property | Value | Source |
|---|---|---|
| Text | `"Loading: 63%"` | `viewer.py:1464` |
| Percent | `(loaded_thumbs + failed_thumbs) / total_files` | `viewer.py:1457` |
| Hidden at | 100% or when no files | `viewer.py:1461` |
| Position | right-aligned, `y = 10 + pos_label.h + info_label.h` | `viewer.py:1467` |
| Style | `rgba(0,0,0,150)` bg, `#aaa`, Menlo 11 px, padding `4px 10px` | `viewer.py:630` |
| Refresh | a repeating 200 ms timer, started at launch and never stopped | `viewer.py:508` |

Note: this label is not gated on `show_info`, so it stays visible when the info
overlay is toggled off. Note: likely unintended.

### Bottom-right filter toolbar

A row at `(width - w - 10, height - filmstrip_h - h - 10)` (`viewer.py:2217`).
Visible only when files are loaded (`viewer.py:1683`).

Contents left to right (`viewer.py:864`, `:873`):

1. `📂` — opens the folder picker.
2. 10 px spacer.
3. Checkable buttons `All`, `1+`, `2+`, `3+`, `4+`, `5`, `✕`.

Button index 0..5 maps to `min_rating_filter = index`; index 6 maps to `-1`
(rejected only) (`viewer.py:1538`). Exactly one is checked at a time
(`viewer.py:1542`).

Mac app addition: the native toolbar has an 8th segment, `0`, between `All`
and `1+`, mapping to `min_rating_filter = -2` (unrated only, see §13). No
Python-app equivalent.

Shared button style (`viewer.py:844`):

| State | Values |
|---|---|
| Normal | bg `rgba(60,60,60,200)`, text `#ccc`, 1 px border `#555`, padding `2px 4px`, Menlo 10 px, min-width 14 |
| Hover | bg `rgba(80,80,80,220)` |
| Checked | bg `rgba(255,180,0,200)`, text black, border `#ffb400` |

This same style is reused for the mode switcher, the subfolder chips, the help
button and the stats button.

### Bottom-left buttons

| Button | Position | Action | Source |
|---|---|---|---|
| `?` | `(10, btn_y)` | toggle help overlay | `viewer.py:912`, `:2221` |
| `⏱` | `(10 + help_btn.width + 6, btn_y)` | toggle shoot stats overlay | `viewer.py:918`, `:2223` |

`btn_y` is the same y as the filter toolbar. Both are always visible, including
on the empty state.

### Snackbar (bottom centre)

| Property | Value | Source |
|---|---|---|
| Background | `rgba(50,50,50,220)`, radius 4 | `viewer.py:805` |
| Text | `#ddd`, SF Pro Text / Helvetica Neue, 12 px | `viewer.py:808` |
| Padding | `8px 16px` | `viewer.py:807` |
| Position | centred, `y = height - filmstrip_h - snackbar_h - 20` | `viewer.py:2156` |
| Default duration | 2000 ms | `viewer.py:2150` |

Messages and their durations:

| Message | Duration | Source |
|---|---|---|
| `"Failed to save rating for {filename}"` | 4000 | `viewer.py:492` |
| `"No JPEG files found in this folder"` | 2000 | `viewer.py:1924` |
| `"No files to export"` | 2000 | `viewer.py:2107` |
| `"Export already in progress"` | 2000 | `viewer.py:2110` |
| Resolve result message | 4000 on success, 5000 on failure | `viewer.py:2148` |
| `"No rejected files"` | 2000 | `viewer.py:2450` |
| `"Moved N files to _rejected/"` | 2000 | `viewer.py:2465` |
| `"Moved N, then failed at {file}: {err}"` | 5000 | `viewer.py:2463` |

### Resolve status label (screen centre)

Shown while an export runs; hidden when the status string is empty
(`viewer.py:2131`). Background `rgba(40,40,40,220)`, text `#ddd`, Menlo 12 px,
padding `8px 16px` (`viewer.py:670`).

---

## 5. Help overlay

Toggled by `H` or the `?` button (`viewer.py:2023`). Centred on screen, raised
above everything. Background `rgba(0,0,0,200)`, content margins 20/15/20/20,
spacing 8 (`viewer.py:715`).

Header row: bold `"Keyboard Shortcuts"` in `#ddd`, Menlo 13 px, plus a 24 x 24
`✕` close button (`#999`, white on hover) which toggles the overlay
(`viewer.py:729`).

Body (`#ddd`, Menlo 13 px, line-height 1.6). The exact text, verbatim
(`viewer.py:687`–`:712`):

```
  ←/→         Navigate images
  0-5          Rate current image
  X            Reject (toggle)
  ⌘0-5        Filter by rating
  ⌘⌫          Move rejected to _rejected/

  S            Go to start
  E            Go to end
  ⇧R          Go to last rated
  R            Rotate 90°

  J            Toggle RAW/JPEG mode
  M            Toggle Video mode
  Space        Play/Pause video
  I            Toggle info overlay
  ⌘S          Toggle filmstrip
  G            Toggle grid view
  H            Toggle this help
  T            Toggle shoot stats

  C            Compare with pinned image
  O            Show in Finder
  ⌘L          Open all in Lightroom
  ⌘D          Export to DaVinci Resolve
  Esc          Close folder
  ⌘Q          Quit
```

The list omits `Cmd+W` (quit) and the fact that `Space` doubles as a 2x zoom
toggle outside video mode.

---

## 6. Shoot stats overlay

Toggled by `T` or the `⏱` button (`viewer.py:2036`). Centred, same visual style
as the help overlay, title `"Shoot Stats"`, content minimum width 280
(`viewer.py:794`). While visible it refreshes on a 1000 ms timer
(`viewer.py:798`).

With no folder open (`viewer.py:2077`):

```
No shoot active.
Open a folder to start tracking.
```

With a folder open (`viewer.py:2086`):

```
Folder:      {folder name}
Elapsed:     {H:MM:SS or M:SS}
Rated:       {rated} / {len(all_files)}
To last rate: {duration}        # or "-" when nothing rated yet
Avg/rate:    {seconds:.1f}s     # only when rated > 0; otherwise "-"
```

Duration formatting: `H:MM:SS` when there is at least one hour, otherwise
`M:SS`, seconds truncated to int (`viewer.py:2048`).

Semantics of the timer are defined in `05`.

---

## 7. Empty state

When `len(files) == 0` (`viewer.py:1679`):

- Filter toolbar hidden.
- Filmstrip hidden.
- A centred `📂 Open Folder` button at
  `((width - w)/2, (height - h)/2 - 40)` (`viewer.py:1995`). Style: bg
  `rgba(60,60,60,220)`, white text, 1 px `#666` border, padding `15px 30px`,
  Menlo 16 px; hover `rgba(80,80,80,240)` (`viewer.py:925`).
- Below it, a vertical list of recent-folder buttons starting at
  `open_btn.bottom + 15`, container top margin 10, spacing 5
  (`viewer.py:958`, `:2002`). Each button reads `📁 {folder basename}` with the
  full path as tooltip (`viewer.py:2193`). Style: bg `rgba(40,40,40,200)`,
  `#aaa`, 1 px `#444`, padding `8px 15px`, Menlo 12 px, left-aligned; hover bg
  `rgba(60,60,60,220)` and white text (`viewer.py:2174`).
- A version label `v0.4.5` at bottom centre, `y = height - h - 10`, `#666`,
  Menlo 11 px (`viewer.py:964`, `:2005`).
- The `?` and `⏱` buttons remain visible.

---

## 8. Grid view

Toggled by `G` (`viewer.py:1002`). Entering it (`viewer.py:1008`):

1. Does nothing if there are no files.
2. Exits compare mode.
3. Pauses video playback if in video mode.
4. Hides the filmstrip.
5. Switches `content_stack` to page 2.
6. Scrolls so the current selection is visible, on the next event loop turn.

Exiting (`viewer.py:1026`) restores the filmstrip (subject to the user's
filmstrip visibility preference) and reloads the current image.

| Property | Value | Source |
|---|---|---|
| Base cell size | 200 | `grid_view.py:9` |
| Spacing | 6 | `grid_view.py:10` |
| Columns | `max(1, (width - 6) // 206)` | `grid_view.py:13` |
| Actual cell size | `max(200, (width - (cols+1)*6) // cols)` — cells stretch to fill the width, never shrink | `grid_view.py:17` |
| Cell origin | `(6 + col*(cell+6), 6 + row*(cell+6))` | `grid_view.py:22` |
| Content height | `6 + rows*(cell+6)`, or 0 when empty | `grid_view.py:27` |
| Background | `rgb(20,20,20)` | `grid_view.py:143` |
| Unloaded cell | `rgb(40,40,40)` | `grid_view.py:166` |
| Vertical scrollbar | 6 px wide, track `#222`, handle `#666` radius 3, min height 30 | `grid_view.py:238` |
| Horizontal scrollbar | never | `grid_view.py:231` |

Cells render the thumbnail aspect-fit and centred, with antialiasing and smooth
pixmap transform (`grid_view.py:160`). If only the 80 px filmstrip thumbnail is
available it is drawn upscaled over a `rgb(40,40,40)` background as an interim
placeholder until the 200 px thumbnail arrives (`grid_view.py:156`).

Selection: 3 px white rectangle at `(x-2, y-2, cell+4, cell+4)`
(`grid_view.py:168`).

Rating dots: 6 x 6 ellipses in `rgb(255,200,50)`, 10 px apart, at
`y + cell - 14`, centred as `x + (cell - rating*10) / 2` (`grid_view.py:173`).

Reject badge: bold 16 px `✕` in `rgb(230,70,70)`, centred in a `cell x 20` box
at `y + cell - 26` (`grid_view.py:180`).

Thumbnail repaints are batched on a 50 ms timer, selection repaints immediate
(`grid_view.py:93`, `:133`). Scroll events debounce the visible-range signal by
50 ms (`grid_view.py:247`).

---

## 9. Compare mode

Toggled by `C` (`viewer.py:1143`). Unavailable in video mode and when no files
are loaded.

On enter: the current image is pinned into the left pane, the splitter is set to
an equal 50/50 split, and focus goes to the right pane (`viewer.py:1154`). If
the current image cannot be loaded, compare does not activate
(`viewer.py:1152`).

The focused pane is marked with a 2 px `#ffb400` border; the unfocused one gets
a 2 px transparent border so the layout does not shift (`viewer.py:1175`).
Clicking inside either pane's viewport focuses it (`viewer.py:1180`).

Navigation only moves the right pane. The left stays pinned. Rating keys and
the `X` reject toggle apply to whichever pane is focused (`viewer.py:2345`,
`:2483`). Rating the pinned image never auto-advances (`viewer.py:2491`).

`R` rotates the focused pane (`viewer.py:2375`).

Exiting: `C` again, `Esc`, entering grid mode, switching view mode, a folder
rescan, a folder close, or a move-rejected operation (`viewer.py:1162` and its
call sites).

---

## 10. Opening a folder

Three entry points:

1. **Command-line argument** — `main.py` scans the path synchronously before
   the window opens and passes the RAW file list into the viewer
   (`main.py:36`). Note: this path only scans for RAW files. JPEG and video
   lists stay empty, `_current_folder` stays `None`, so subfolder chips, mode
   switching, Resolve export and move-rejected are all unavailable until the
   user opens a folder through the UI. Note: likely unintended.
2. **Folder picker** — the `📂` toolbar button or the centred `📂 Open Folder`
   button. The dialog starts in the most recent folder, falling back to the
   home directory (`viewer.py:1548`).
3. **Drag and drop** — a folder dropped anywhere on the window, the filmstrip,
   the image view or the grid. Only directories are accepted; files are ignored
   (`viewer.py:2272`, `:2290`). Child widgets forward drag and drop events up to
   the main window (`viewer.py:83`, `grid_view.py:202`).

### Scan sequence

`_load_folder` (`viewer.py:1564`):

1. Record the folder as `_current_folder`.
2. Hide the centred open button and the recent list.
3. Show a centred `"Scanning folder..."` label — bg `rgba(40,40,40,220)`,
   `#aaa`, Menlo 14 px, padding `15px 30px` (`viewer.py:943`).
4. On a background thread: scan RAW (with progress), then JPEG, then video.
5. Progress updates rewrite the label to `"Sorting by date... 63%"`
   (`viewer.py:1592`).
6. Emit the result back to the UI thread.

On completion (`viewer.py:1596`):

- If all three lists are empty, the label hides and the empty state returns.
  Nothing else changes, and the folder is **not** added to recents.
- Otherwise the folder is added to the recent list, all caches and per-index
  state are cleared, filters reset (`min_rating_filter = 0`,
  `folder_filter = None`, `excluded_folders = set()`), selection resets to 0,
  and the view mode is forced back to `"raw"` (`viewer.py:1618`).
- The shoot timer resumes from persisted stats for that folder if any, otherwise
  starts fresh (`viewer.py:1645`).
- If there are no RAW files but there are JPEGs or videos, the app auto-switches
  to whichever of the two has more files, with JPEG winning ties
  (`viewer.py:1663`).
- If grid mode was active it is re-entered against the new list
  (`viewer.py:1672`).

---

## 11. Closing a folder

`Esc` with no compare pane pinned, or `Esc` outside grid mode
(`viewer.py:2397`). `_close_folder` (`viewer.py:1696`):

- No-op when nothing is loaded in any mode.
- Exits compare, stops background preloading, stops video.
- Clears every cache, rating map, loading set, filmstrip and grid thumbnail.
- Resets all three mode state bundles to empty.
- Persists shoot stats, then resets the timer.
- Clears `_current_folder`, sets view mode to `"raw"`, display mode to
  `"single"`, title back to `"RAW Viewer"`.
- Clears the image and returns to the empty state.

---

## 12. Quit semantics

`Cmd+Q` and `Cmd+W` both call `self.close()` (`viewer.py:2407`). There is no
distinction between closing the window and quitting; closing the only window
ends the application.

`closeEvent` (`viewer.py:2578`):

1. Persist shoot stats.
2. Stop the background thumbnail preload timer.
3. Stop the video player.
4. Shut down the rating executor **waiting for completion**, so pending XMP
   sidecar writes are flushed.
5. Shut down the preview and thumbnail executors without waiting.

Note: `current_executor` and `render_executor` are never shut down. Harmless in
practice because the process exits. Note: likely unintended.

---

## 13. Filtering

### Rating filter

Values: `0` (all), `1`–`5` (minimum rating), `-1` (rejected only)
(`viewer.py:1514`).

The predicate (`viewer.py:1514`):

- `min_rating_filter == -1` matches only `rating == -1`.
- Otherwise matches `rating >= min_rating_filter`.

Consequence: with `min_rating_filter == 0` (the `All` bucket) the predicate is
`rating >= 0`, so rejected files (`-1`) are **not** shown in `All`. They are
only reachable through the `✕` bucket. The approved design document
(`docs/superpowers/specs/2026-07-03-perf-culling-round1-design.md`, section 5)
states the opposite: "The '0'/All filter includes rejected". The shipped code
does not match that document. Note: likely unintended.

Applying a filter (`viewer.py:1478`):

1. Stop the background thumbnail preload.
2. Remember the currently selected file.
3. Rebuild `files` from `all_files`.
4. Clear filmstrip and grid thumbnails and their loading sets.
5. If the previously selected file survives the filter, keep it selected;
   otherwise select index 0.
6. If nothing survives, clear the image view.

Ratings for every file are read from disk before a non-zero filter is applied
(`viewer.py:1531`), which is the only place a full folder rating sweep happens
outside of `Shift+R` and the Resolve export.

Mac app addition: `min_rating_filter = -2` is an "unrated only" bucket,
matching only `rating == 0`. No Python-app equivalent.

### Subfolder filter

Independent of the rating filter and applied on top of it (`viewer.py:1528`).
A file is in scope when:

- no folder is open → always in scope;
- a `folder_filter` is set → its first-level subfolder name must equal it;
- otherwise → its first-level subfolder name must not be in `excluded_folders`.

---

## 14. Rating and auto-advance

Pressing `0`–`5` (`viewer.py:2479`):

1. If compare is active and the left pane is focused, rate the pinned image,
   update the filmstrip badge if that file is in the current list, and stop.
   No auto-advance.
2. Otherwise update the in-memory rating immediately, queue the XMP write on a
   background single-worker executor, update the filmstrip and grid badges, and
   refresh the overlay.
3. Update shoot stats if the rated/unrated status changed.
4. If the current index is not the last, advance by one.

The UI never blocks on the sidecar write. If the write fails, a snackbar appears
but the in-memory rating is not rolled back (`viewer.py:2519`).

`X` toggles reject: if the target is already `-1` it becomes `0`, otherwise `-1`
(`viewer.py:2343`). Auto-advance applies the same way.

---

## 15. Rotation

`R` rotates the displayed image 90° clockwise, view only. Nothing is written to
disk (`viewer.py:102`). Rotation is cumulative modulo 360. Rotating re-fits the
image to the window (`viewer.py:107`).

Rotation resets to 0 whenever a new image is loaded in single mode
(`viewer.py:1361`). It does not reset the zoom by itself (`viewer.py:109`).

`R` is ignored in video mode (`viewer.py:2376`).

---

## 16. Zoom and pan

Applies to `ZoomableImageView` (`viewer.py:48`).

| Concept | Rule | Source |
|---|---|---|
| Fit to window | on every `set_pixmap`, and on resize while at fit | `viewer.py:100`, `:209` |
| `zoom_factor` | 1.0 means fit-to-window; it is a multiplier on top of fit, not an absolute scale | `viewer.py:126` |
| Minimum zoom | 0.1 | `viewer.py:62` |
| Maximum zoom | 10.0 | `viewer.py:63` |
| Bounds check | a zoom step is applied only if the resulting factor lands inside `[0.1, 10.0]`; otherwise nothing happens — it does not clamp | `viewer.py:138` |
| "At fit" test | `abs(zoom_factor - 1.0) < 0.01` | `viewer.py:130` |
| `Space` toggle | at fit → jump to 2.0x; otherwise → back to fit | `viewer.py:128` |
| Double-click | always back to fit | `viewer.py:204` |
| Reset on navigate | yes — loading a new pixmap calls `reset_zoom` | `viewer.py:100` |
| Pinch | `factor = 1.0 + gesture.value()`, anchored at the gesture position | `viewer.py:157` |
| Mouse drag | left button pans by the raw pixel delta; cursor becomes a closed hand | `viewer.py:180` |
| Two-finger scroll while at fit | horizontal only, navigates images when `abs(dx) > 30` | `viewer.py:168` |
| Two-finger scroll while zoomed | pans both axes | `viewer.py:174` |
| Swipe direction | `dx > 0` goes to the previous image, `dx < 0` to the next | `viewer.py:170` |
| Swipe debounce | 200 ms between navigations | `viewer.py:2469` |

Note: `Space` only ever zooms `image_view`, never the pinned compare pane, even
when the left pane is focused (`viewer.py:2418`). Note: likely unintended.

Note: panning is implemented by moving scrollbars that are set to
`ScrollBarAlwaysOff`. This works in Qt, but a Swift implementation should use a
proper scroll or transform offset.

---

## 17. "Last rated" jump

`Shift+R` loads every rating from disk, then scans the current filtered list
backwards and jumps to the last file with `rating > 0` (`viewer.py:2381`).
Rejected files (`-1`) do not count. If nothing is rated, nothing happens.

---

## 18. Video mode

Entered with `M`, the `MOV` mode button, or automatically after a scan that
found no RAW files and more videos than JPEGs.

| Behaviour | Detail | Source |
|---|---|---|
| On selecting a clip | stop, set source, **play immediately** | `viewer.py:1353` |
| Play/pause | `Space` | `viewer.py:2414` |
| Timeline | range set from clip duration in ms; updated live unless the user is dragging the handle | `viewer.py:2565`, `:2557` |
| Seek | dragging the slider handle | `viewer.py:2568` |
| Time label | `"{pos//60}:{pos%60:02d} / {dur//60}:{dur%60:02d}"`, seconds integer-divided from ms | `viewer.py:2572` |
| Audio | a plain audio output at default volume | `viewer.py:576` |
| Preview cache | not used in video mode; `_load_path_sync` returns `None` | `viewer.py:1137` |
| Preloading | disabled in video mode | `viewer.py:1260` |
| Media backend | forced to macOS native AVFoundation, because the default FFmpeg backend plays 60 fps clips too fast | `main.py:10` |

Video ratings are still written as XMP sidecars, and additionally set a green
Finder tag (see `05`).

---

## 19. JPEG mode

Entered with `J`, the `JPG` mode button, or automatically after a scan with no
RAW files.

`J` refuses to switch and shows the snackbar `"No JPEG files found in this
folder"` when the current mode is `"raw"` and there are no JPEGs
(`viewer.py:1923`).

Note: the guard only checks `view_mode == "raw"`. Pressing `J` while in video
mode with zero JPEGs switches into an empty JPEG mode with no warning. Note:
likely unintended.

JPEG ratings write both an XMP sidecar and a green Finder tag.

---

## 20. Auto-update check

Runs once on a daemon thread at launch (`viewer.py:986`, `:2590`).

| Property | Value | Source |
|---|---|---|
| Skipped when | `VERSION == "dev"` (i.e. no bundled `VERSION` file) | `viewer.py:2592` |
| Endpoint | `https://api.github.com/repos/yannickpulver/raw-viewer/releases/latest` | `viewer.py:2595` |
| Header | `User-Agent: RAW-Viewer` | `viewer.py:2596` |
| Timeout | 5 s | `viewer.py:2597` |
| Latest version | `tag_name` with a leading `v` stripped | `viewer.py:2599` |
| Comparison | plain string inequality `latest != VERSION` | `viewer.py:2600` |
| Link opened | the release's `html_url` | `viewer.py:2601` |
| Errors | swallowed silently | `viewer.py:2603` |

Note: because the comparison is string inequality, not a semantic version
compare, a locally built version that is *newer* than the published release also
shows "Update available". Note: likely unintended.

---

## 21. Reveal in Finder

`O` runs `open -R <current file path>` (`viewer.py:2396`). Single file only, the
currently selected one, regardless of compare focus.

## 22. Open in Lightroom

`Cmd+L` runs
`open -a "Adobe Lightroom Classic" <every file in the current filtered list>`
(`viewer.py:2365`).

Note: this passes the entire visible list as arguments, not just the current
image. With a large folder this is a very long argument list and Lightroom will
import all of them. There is no confirmation dialog, no check that Lightroom is
installed, and no error feedback if the `open` call fails. Note: likely
unintended at this scale, but it is the documented shortcut ("Open all in
Lightroom" in the help overlay).

## 23. Move rejected

`Cmd+Backspace` (`viewer.py:2442`). See `05` for the file operations. UX:

1. No-op when no folder is open or nothing is loaded.
2. Load all ratings, then flush pending sidecar writes by submitting a no-op to
   the rating executor and blocking on its result (`viewer.py:2447`).
3. If nothing is rejected, snackbar `"No rejected files"`.
4. Otherwise a modal Yes/No question:
   `"Move {N} rejected files (+{M} sidecars/pairs) to _rejected/?"`
5. On Yes, move the files, show a result snackbar, exit compare, and rescan the
   folder.

---

## 24. Error and edge states

| Situation | Behaviour | Source |
|---|---|---|
| Folder scan finds nothing at all | scanning label hides, empty state returns, folder not added to recents | `viewer.py:1604` |
| A preview fails to decode | error printed to stdout, `None` returned, nothing displayed; the placeholder thumbnail stays | `preview.py:123` |
| A thumbnail fails | index added to `thumb_failed`, counted as "loaded" for the progress percentage so the bar can still reach 100% | `viewer.py:1256` |
| XMP write fails | snackbar for 4 s, in-memory rating unchanged | `viewer.py:2524` |
| Resolve not installed | `"DaVinci Resolve not found.\nRequires Resolve Studio (paid) for scripting."` | `resolve_export.py:102` |
| Export already running | snackbar, second export refused | `viewer.py:2109` |
| Move-rejected hits an OS error | stops at the first failure, reports how many moved and which file failed | `move_rejected.py:47` |
| Update check fails | silent | `viewer.py:2603` |
| Recent folder no longer exists | filtered out of the list at load time | `recent_folders.py:20` |
