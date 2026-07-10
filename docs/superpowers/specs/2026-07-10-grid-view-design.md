# Grid View — Design

Date: 2026-07-10
Status: Approved

## Goal

A Lightroom-style grid view to glance over many images at once, complementing the existing single-image view + horizontal filmstrip.

## UX

- **`G` toggles grid mode.** Grid replaces the content area (new page in `content_stack`); the filmstrip is hidden while the grid is active. `Esc` in grid returns to single view (before its existing exit-compare/close-folder behavior).
- Grid opens **scrolled to the current image**, which is selected with the same white-border style as the filmstrip.
- **Navigation:** arrow keys move selection 2D (`←`/`→` ±1, `↑`/`↓` ±columns, clamped). Click selects. Double-click, `Enter`, or `G` returns to single view on the selected image.
- **Rating/reject:** `0–5` and `X` act on the selected cell. Rating dots and red ✕ are drawn on cells exactly like the filmstrip.
- **Filters:** `⌘0–5` rating filters work in grid; the grid re-lays-out on filter change and selection is clamped to the new list.
- Grid works in all file-type modes (raw/jpeg/video) — it renders whatever `self.files` currently is.

## Architecture

### New file: `grid_view.py`

Keeps `viewer.py` (already 2277 lines) from growing further.

- **`GridContent(QWidget)`** — custom `paintEvent`, virtualized like `FilmstripContent`:
  - `CELL = 200`, `SPACING = 6`.
  - `columns = max(1, width // (CELL + SPACING))`; widget height = `rows * (CELL + SPACING)`.
  - Draws only the visible row range; dark placeholder rects for unloaded thumbs.
  - Thumbs aspect-fit inside square cells, letterboxed on dark background.
  - Selection border (3px white), rating dots (yellow), rejected ✕ (red) — same visual language as filmstrip.
  - Signals: `clicked(int)`, `activated(int)` (double-click), `visible_range_changed(first, last)`.
  - Layout math (index ↔ row/col, visible range for a scroll viewport) as pure functions/methods for unit testing.
- **`GridWidget(QScrollArea)`** — vertical scroll container. Debounced scroll → visible-range emission (same pattern as `FilmstripWidget`). `set_current(index)` scrolls selection into view. Recomputes columns on resize.

### Thumbnails (size 200)

- Reuse the existing pipeline: `ThumbnailCache` is keyed by `(path, size)`, so size 200 namespaces itself on disk with no cache changes.
- New loader path in `viewer.py`: a grid variant of `_load_thumbnails_range` submitting to the existing `thumb_executor`, with a new signal (`grid_thumb_loaded(idx, pixmap)`) so 80px filmstrip thumbs and 200px grid thumbs never mix.
- Load visible range + small buffer only. **No full-folder background preload at 200px** — keeps memory bounded.
- If the 80px filmstrip thumb is already loaded, show it upscaled as an interim placeholder; replace when the 200px thumb arrives. Grid feels instant, sharpens progressively.

### Wiring in `viewer.py`

- New state: `self.display_mode ∈ {"single", "grid"}`, orthogonal to the file-type `self.view_mode`.
- `content_stack` gets a third page (index 2) for the grid.
- `keyPressEvent`: when `display_mode == "grid"`, route arrows/Enter to grid selection; `G` toggles; `0–5`/`X`/`⌘0–5` fall through to the existing handlers (they operate on `self.index`, which grid selection updates directly).
- Grid selection updates `self.index` (and filmstrip current, so state stays consistent).
- Exiting grid → `content_stack` back to image page, show filmstrip, `_load_current()` + `_preload_nearby()` as usual.
- Filter changes and rescans call the grid's re-layout when it's active.

## Edge cases

- Empty folder / all filtered out: grid shows nothing; toggling still works; selection stays -1/none.
- Window resize while in grid: columns recompute, selection kept visible.
- Rescan while in grid: grid refreshes from new `self.files`, selection clamped.
- Mode switch (J/M) while in grid: grid re-renders new file list; thumbs load per new mode's extractor (existing `_preload_thumb` dispatch).

## Testing

- `tests/test_grid_view.py`: pure layout math — index↔row/col mapping, columns-for-width, visible index range for a scroll viewport, clamping on navigation.
- Interaction (toggle, rating, filters, double-click) verified manually.

## Out of scope

- Multi-select / bulk rating
- Adjustable cell size
- Drag reorder, marquee selection
