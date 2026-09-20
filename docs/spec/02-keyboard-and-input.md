# 02 — Keyboard, Mouse, Trackpad and Gestures

Everything here is derived from the code, not from `README.md`. Disagreements
with the README are listed in section 7.

## 0. How key events reach the handler

There is exactly one keyboard handler: `ImageViewer.keyPressEvent`
(`viewer.py:2324`). There are **no** `QShortcut`, `QAction`, `setShortcut` or
menu-bar entries anywhere in the codebase. Every binding below is a branch in
that one method.

The image views forward their key events up to the main window
(`viewer.py:215`). The filmstrip, its content, the grid and its content all set
`FocusPolicy.NoFocus` so they never steal keyboard focus
(`viewer.py:377`, `grid_view.py:233`). The video widget and timeline slider are
also `NoFocus` (`viewer.py:550`, `:567`).

When grid mode is active, `_handle_grid_key` (`viewer.py:2301`) gets first
refusal. If it returns `True` the event stops there; otherwise it falls through
to the normal handler.

Unhandled keys are passed to `QMainWindow.keyPressEvent` (`viewer.py:2429`).

### Modifier matching

Modifier checks are exact equality against a single modifier, not a mask test.
`Ctrl` and `Cmd` are treated as interchangeable everywhere a command modifier is
used (`viewer.py:2337`, `:2361`, `:2404`, `:2407`, `:2423`). In Qt on macOS,
`ControlModifier` maps to the Command key by default and `MetaModifier` to the
physical Control key, so in practice both physical keys work.

Consequence of exact matching: adding an extra modifier disables a binding.
`Cmd+Shift+3` does not filter; `Shift+X` does not reject.

---

## 1. Single (non-grid) mode key table

| Key | Modifier | Condition | Effect | Source |
|---|---|---|---|---|
| `→` | any | — | next image, no wrap | `viewer.py:2330` |
| `←` | any | — | previous image, no wrap | `viewer.py:2332` |
| `0`–`5` | none | — | set rating on the focused image, then auto-advance unless already last | `viewer.py:2340` |
| `0`–`5` | Cmd or Ctrl | — | set rating filter to that number | `viewer.py:2337` |
| `X` | none | files loaded | toggle reject: `-1` if not already `-1`, else `0`; then auto-advance | `viewer.py:2343` |
| `I` | any | — | toggle the info overlay (position counter + info line) | `viewer.py:2352` |
| `S` | none | files loaded | jump to index 0 | `viewer.py:2355` |
| `S` | Cmd or Ctrl | files loaded | toggle filmstrip visibility | `viewer.py:2404` |
| `E` | any | files loaded | jump to the last index | `viewer.py:2369` |
| `R` | none | files loaded, not video mode | rotate the focused pane 90° clockwise, view only | `viewer.py:2375` |
| `R` | Shift | files loaded | load all ratings, jump to the last file with `rating > 0` | `viewer.py:2381` |
| `L` | Cmd or Ctrl | files loaded | `open -a "Adobe Lightroom Classic"` with every file in the current filtered list | `viewer.py:2361` |
| `D` | Cmd or Ctrl | — | export to DaVinci Resolve | `viewer.py:2366` |
| `O` | any | files loaded | `open -R` on the current file (reveal in Finder) | `viewer.py:2394` |
| `Esc` | any | compare active | exit compare mode | `viewer.py:2398` |
| `Esc` | any | compare not active | close the folder | `viewer.py:2401` |
| `C` | none | — | toggle compare mode | `viewer.py:2402` |
| `Q` | Cmd or Ctrl | — | close the window (quits) | `viewer.py:2407` |
| `W` | Cmd or Ctrl | — | close the window (quits) | `viewer.py:2407` |
| `J` | any | — | switch to JPEG mode, or back to RAW if already in JPEG | `viewer.py:2410` |
| `M` | any | — | switch to video mode, or back to RAW if already in video | `viewer.py:2412` |
| `Space` | any | video mode | toggle play/pause | `viewer.py:2415` |
| `Space` | any | not video mode | toggle 2x zoom on the right pane | `viewer.py:2417` |
| `H` | any | — | toggle the help overlay | `viewer.py:2419` |
| `T` | any | — | toggle the shoot stats overlay | `viewer.py:2421` |
| `Backspace` | Cmd or Ctrl | — | move rejected files to `_rejected/` | `viewer.py:2423` |
| `G` | none | — | toggle grid view | `viewer.py:2426` |

Mac app additions, no Python-app equivalent: `0` with `Opt+Cmd` sets the
rating filter to "unrated only" (see spec 01 §13); `M` with `Shift+Cmd` opens
"Move Shown Files to Folder…" (see spec 05 §10 addendum). Both are menu-bar
commands, not part of the single key dispatcher table above.

### Bindings with no modifier check

`→`, `←`, `I`, `E`, `O`, `Esc`, `J`, `M`, `Space`, `H` and `T` do not test the
modifiers at all. `Shift+→`, `Cmd+I`, `Cmd+Space` and so on therefore trigger
the plain action. Note: likely unintended for `Cmd+Space` in particular, which
collides with Spotlight, but Spotlight consumes it before the app sees it.

### Ordering quirk

The `0`–`5` branch is checked before `X`, `S`, `E` and the rest, and the `S`
branch appears before the `Cmd+S` branch. Because each branch also tests its
modifiers, the order is not observable. One exception: the `R` no-modifier
branch appears before the `Shift+R` branch (`viewer.py:2375`, `:2381`), and both
test modifiers exactly, so both work.

---

## 2. Grid mode key table

Handled by `_handle_grid_key` (`viewer.py:2301`) before the normal table.

| Key | Modifier | Effect | Source |
|---|---|---|---|
| `→` | any | selection +1, clamped to the list | `viewer.py:2305` |
| `←` | any | selection -1, clamped | `viewer.py:2307` |
| `↓` | any | selection down one row; stays put when already on the last row, otherwise clamps to the last item | `viewer.py:2309`, `grid_view.py:57` |
| `↑` | any | selection up one row; stays put when already on the first row | `viewer.py:2311`, `grid_view.py:66` |
| `Return` / `Enter` | any | exit grid, show the selected image | `viewer.py:2313` |
| `Esc` | any | exit grid (does **not** close the folder) | `viewer.py:2313` |
| `Space` | none | consumed, does nothing | `viewer.py:2315` |
| `C` | none | consumed, does nothing | `viewer.py:2315` |
| `S` | Cmd or Ctrl | consumed, does nothing (filmstrip is hidden in grid) | `viewer.py:2317` |

Everything else falls through to the single-mode table. In particular, in grid
mode: `0`–`5` rate the selected cell, `X` rejects it, `Cmd+0`–`5` filter, `G`
exits grid, `S` with no modifier jumps to index 0, `E` to the last, `H` and `T`
open overlays, `R` rotates the (hidden) single-view pane, and `O`, `Cmd+L`,
`Cmd+D`, `Cmd+Q`, `Cmd+W`, `Cmd+Backspace`, `I`, `J`, `M` all behave as normal.

Note: `Shift+R` in grid mode jumps to the last rated file and, via
`_load_current`, moves the grid selection there. Rotation and zoom commands
still run against the hidden single view. Note: likely unintended but harmless.

Note: arrow navigation in grid mode does not preload previews, by design
(`viewer.py:2437`).

---

## 3. Mouse

| Widget | Input | Effect | Source |
|---|---|---|---|
| Main window | left press with `y < 40` | begin window drag | `viewer.py:2252` |
| Main window | mouse move while dragging | move the window | `viewer.py:2258` |
| Main window | left release | end window drag | `viewer.py:2266` |
| Update banner | any press inside its rectangle | `open` the release URL; the event is consumed | `viewer.py:2247` |
| Image view / compare view | left press | begin pan, cursor becomes closed hand | `viewer.py:180` |
| Image view / compare view | move while panning | pan by the raw pixel delta | `viewer.py:188` |
| Image view / compare view | left release | end pan, cursor back to arrow | `viewer.py:197` |
| Image view / compare view | double-click | reset zoom to fit | `viewer.py:204` |
| Image view / compare view | any press while compare active | focus that pane | `viewer.py:1180` |
| Filmstrip content | any press | select the cell at `floor(x / 84)` | `viewer.py:339` |
| Grid content | any press | select the cell under the cursor | `grid_view.py:190` |
| Grid content | double-click | select and exit grid to the single view | `grid_view.py:196` |
| Subfolder chip | left click | set that subfolder as the filter (`All` chip clears it) | `viewer.py:1853` |
| Subfolder chip (named only) | right click | context menu with `Exclude from All` / `Include in All` | `viewer.py:1866` |
| Filter buttons | click | set the rating filter; index 6 (`✕`) means rejected-only | `viewer.py:878`, `:1538` |
| Mode buttons | click | switch view mode directly, no toggle-back, ignored if that mode is empty | `viewer.py:896`, `:1781` |
| `📂` toolbar button | click | open the folder picker | `viewer.py:866` |
| `📂 Open Folder` centred button | click | open the folder picker | `viewer.py:938` |
| Recent folder button | click | load that folder | `viewer.py:2196` |
| `?` button and help `✕` | click | toggle the help overlay | `viewer.py:914`, `:738` |
| `⏱` button and stats `✕` | click | toggle the shoot stats overlay | `viewer.py:920`, `:781` |
| Video timeline slider | drag handle | seek | `viewer.py:581` |

Note: the image views' pan starts on any left press without a drag threshold, so
a plain click that moves a pixel scrolls the image slightly.

Note: filmstrip hit testing uses `floor(x / 84)` with no bounds correction for
the 4 px gap, so a click in the gap after cell *n* selects cell *n+1*
(`viewer.py:343`). Grid hit testing does reject clicks past the last column
(`grid_view.py:39`).

---

## 4. Trackpad and wheel

| Widget | Input | Condition | Effect | Source |
|---|---|---|---|---|
| Image view | two-finger scroll | at fit zoom, `abs(pixelDelta.x) > 30` | navigate: `dx > 0` → previous, `dx < 0` → next, debounced to one step per 200 ms | `viewer.py:168`, `:2469` |
| Image view | two-finger scroll | at fit zoom, `abs(dx) <= 30` | nothing; the event is consumed | `viewer.py:171` |
| Image view | two-finger scroll | zoomed in | pan by `pixelDelta` on both axes | `viewer.py:174` |
| Filmstrip | two-finger scroll | `pixelDelta` non-null | scroll horizontally by `pixelDelta.x`; vertical delta is ignored | `viewer.py:414` |
| Filmstrip | mouse wheel | `pixelDelta` null | scroll horizontally by `angleDelta.y` (vertical wheel becomes horizontal scroll) | `viewer.py:420` |
| Grid | vertical scroll | — | standard `QScrollArea` vertical scrolling; the visible-range signal is debounced 50 ms | `grid_view.py:247` |

The image view consumes every wheel event, so a vertical two-finger scroll at
fit zoom does nothing at all.

---

## 5. Gestures

Only one gesture is handled.

| Gesture | Where | Effect | Source |
|---|---|---|---|
| Pinch (`ZoomNativeGesture`) | image view and compare view | zoom by `1.0 + gesture.value()`, anchored at the gesture position | `viewer.py:151` |

`PinchGesture` is grabbed and `WA_AcceptTouchEvents` is set
(`viewer.py:79`), but the actual handling is through the native gesture event,
not the Qt gesture framework. There is no rotate gesture, no smart-zoom (two
finger double tap) handling, and no swipe gesture handler — swiping is
implemented through wheel events as described above.

`QNativeGestureEvent` is imported but never referenced (`viewer.py:16`).

---

## 6. Drag and drop

| Widget | Behaviour | Source |
|---|---|---|
| Main window | accepts a drag when any dragged URL is a local directory | `viewer.py:2272`, `:2281` |
| Main window | on drop, loads the first local directory found and consumes the event | `viewer.py:2290` |
| Image view, compare view | forwards `dragEnter`, `dragMove`, `drop` to the main window | `viewer.py:83` |
| Filmstrip and its content | same | `viewer.py:347`, `:447` |
| Grid and its content | same | `grid_view.py:202`, `:306` |

Note: every `dragMoveEvent` forwarder calls the window's **`dragEnterEvent`**,
not its `dragMoveEvent` (`viewer.py:89`, `grid_view.py:208`). The two methods
are identical in body so the behaviour is correct. Note: likely a copy-paste
slip.

Files are never accepted, only directories.

---

## 7. Where the README and the code disagree

`README.md` shortcut table vs the implementation:

| README says | Code does | Verdict |
|---|---|---|
| `Cmd+0-5` filter by minimum rating | correct | ok |
| `S` jump to first | correct, but only with no modifier | ok |
| `E` jump to last | correct | ok |
| `Shift+R` jump to last rated | correct | ok |
| `R` rotate 90° | correct, and blocked in video mode | ok |
| `Esc` close folder | also exits compare first, and exits grid first | **incomplete** |
| `Cmd+Q` / `Cmd+W` quit | correct, both close the window | ok |
| `Space` play/pause video | also toggles 2x zoom outside video mode | **incomplete** |
| `Cmd+S` toggle filmstrip | correct, and is a no-op when no files are loaded | ok |
| "Scroll wheel on filmstrip" | correct | ok |
| "two-finger swipe to navigate" | only horizontal, only at fit zoom, only above a 30 px threshold, debounced 200 ms | **incomplete** |
| — | `X` reject toggle | **missing from README** |
| — | `C` compare mode | **missing from README** |
| — | `G` grid view | **missing from README** |
| — | `T` shoot stats | **missing from README** |
| — | `Cmd+Backspace` move rejected | **missing from README** |
| — | right-click on a subfolder chip to exclude it | **missing from README** |
| — | grid arrow-key navigation and `Enter` | **missing from README** |
| — | double-click resets zoom | **missing from README** |

The in-app help overlay (`viewer.py:687`) is more accurate than the README but
still omits `Cmd+W` and the `Space` zoom behaviour.

---

## 8. Complete audit checklist

Every occurrence of an input-handling symbol in the codebase, and where it is
covered above.

| Symbol | Location | Covered in |
|---|---|---|
| `keyPressEvent` | `viewer.py:215` (image view, forwards up) | section 0 |
| `keyPressEvent` | `viewer.py:2324` (main handler) | sections 1, 2 |
| `keyPressEvent` | `viewer.py:2429` (fallthrough to super) | section 0 |
| `QShortcut` | none exist | — |
| `QAction` | none exist | — |
| `setShortcut` | none exist | — |
| `mousePressEvent` | `viewer.py:180` image view pan start | section 3 |
| `mousePressEvent` | `viewer.py:339` filmstrip hit test | section 3 |
| `mousePressEvent` | `viewer.py:2243` window drag + update banner | section 3 |
| `mousePressEvent` | `grid_view.py:190` grid hit test | section 3 |
| `mouseMoveEvent` | `viewer.py:188` image pan | section 3 |
| `mouseMoveEvent` | `viewer.py:2258` window drag | section 3 |
| `mouseReleaseEvent` | `viewer.py:197` end pan | section 3 |
| `mouseReleaseEvent` | `viewer.py:2266` end window drag | section 3 |
| `mouseDoubleClickEvent` | `viewer.py:204` reset zoom | section 3 |
| `mouseDoubleClickEvent` | `grid_view.py:196` activate cell | section 3 |
| `eventFilter` on viewports | `viewer.py:1180` compare focus | section 3 |
| `wheelEvent` | `viewer.py:162` image view | section 4 |
| `wheelEvent` | `viewer.py:411` filmstrip | section 4 |
| `grabGesture(PinchGesture)` | `viewer.py:79` | section 5 |
| `WA_AcceptTouchEvents` | `viewer.py:80` | section 5 |
| `NativeGesture` / `ZoomNativeGesture` | `viewer.py:153` | section 5 |
| `QNativeGestureEvent` import | `viewer.py:16` | unused, section 5 |
| `dragEnterEvent` | `viewer.py:83`, `:347`, `:447`, `:2272`; `grid_view.py:202`, `:306` | section 6 |
| `dragMoveEvent` | `viewer.py:87`, `:351`, `:451`, `:2281`; `grid_view.py:206`, `:310` | section 6 |
| `dropEvent` | `viewer.py:91`, `:355`, `:455`, `:2290`; `grid_view.py:210`, `:314` | section 6 |
| `customContextMenuRequested` | `viewer.py:1867` subfolder chip | section 3 |
| `QMenu` | `viewer.py:1874` chip exclude menu | section 3 |
| `QMessageBox.question` | `viewer.py:2454` move-rejected confirmation | `01` section 23 |
