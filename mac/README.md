# RAW Viewer — native macOS (Swift)

Native Swift rewrite of the Python/PyQt RAW Viewer. The behavioural contract is
`../docs/spec/*.md`; this target reproduces `01`–`05` and `07`.

## Generate, build, test

```sh
cd mac
tuist generate --no-open          # only needed after Project.swift changes
xcodebuild -project RAWViewer.xcodeproj -scheme RAWViewer -configuration Debug build
xcodebuild -project RAWViewer.xcodeproj -scheme RAWViewer -configuration Debug test
```

Never `clean`. Use `-only-testing:RAWViewerTests/<Suite>` while iterating.

## Layout

```
RAWViewer/Sources/
  App/            placeholder SwiftUI entry point (UI agent owns this)
  Model/          MediaKind, MediaFile, Rating, ModeState, GridLayout, Library
  Scan/           FolderScanner, DateCache
  Images/         PreviewDecoder, ByteLRUCache, DiskThumbnailCache, PreloadScheduler
  Sidecar/        XMPSidecar, FinderTags, MoveRejected, RatingWriter
  Persistence/    AppPaths, Preferences, RecentFolders, ShootStats, FolderSummary
  Integrations/   (other agent)
  UI/             (other agent)
```

Swift 5 language mode, `SWIFT_STRICT_CONCURRENCY=minimal`, deployment target macOS 15.0,
no sandbox. `Library` and `PreloadScheduler` are `@MainActor @Observable`; all decoding,
scanning and sidecar I/O happens off the main thread.

## Library API (the UI binds to this)

`Library` is `@MainActor @Observable`. Construct one and keep it for the app's lifetime.

### State to read

| Member | Purpose |
|---|---|
| `folder: URL?` | currently open folder, `nil` for the empty state |
| `viewMode: MediaKind` | raw / jpeg / video |
| `displayMode: DisplayMode` | single / grid |
| `files`, `allFiles`, `index`, `currentFile` | the active mode's filtered list and selection |
| `ratingFilter`, `folderFilter`, `excludedFolders` | active filters |
| `rating(for: URL) -> Int`, `currentRating` | ratings; `0` when unknown |
| `isScanning`, `scanProgressText` | "Scanning folder..." / "Sorting by date... 63%" |
| `snackbar: SnackbarEvent?` | post-once event with `text` + `durationMs`; call `clearSnackbar()` |
| `resolveStatus: String?`, `updateAvailable: UpdateInfo?` | Resolve export status, update banner |
| `pinnedFile`, `focusedPane`, `isCompareActive` | compare mode |
| `showInfo`, `filmstripVisible` | persisted overlay toggles |
| `recentFolders: [URL]` | empty-state recents list |
| `folderSummary(for:) -> FolderSummary?` | cached counts + rating histogram for a recent folder |
| `scheduler: PreloadScheduler` | images (see below) |
| `gridColumns: Int` | set this on grid layout so `gridMove` works |

### Text helpers

`positionText` · `infoText` · `filterBadgeText` · `windowTitle` ·
`modeButtonLabel(_:)` / `modeButtonVisible(_:)` · `showsSubfolderChips` ·
`subfolderChips() -> [(name, count, excluded)]` · `allChipCount` ·
`statsLines() -> [String]` · `Library.formatDuration(_:)`.

### Commands

| Method | Purpose |
|---|---|
| `openFolder(_ url: URL)` | scan + reset; safe to call while a scan runs |
| `closeFolder()` | Esc outside compare/grid |
| `navigate(by: Int)` / `jumpToFirst()` / `jumpToLast()` | arrow keys, `S`, `E` |
| `jumpToLastRated() async` | `Shift+R`; loads all ratings first |
| `select(index: Int)` | filmstrip / grid click |
| `gridMove(dx: Int, dy: Int)` | grid arrows, via `GridLayout` |
| `rate(_ value: Int)` | `0`–`5`; auto-advances unless last or pinned pane |
| `toggleReject()` | `X` |
| `setRatingFilter(_ value: Int) async` | `Cmd+0`–`5` / filter buttons; loads ratings when non-zero |
| `setFolderFilter(_ name: String?)` | subfolder chip click |
| `toggleExcluded(_ folder: String)` | chip right-click |
| `switchViewMode(_ kind:toggle:)` | `toggle: true` = `J`/`M`, `toggle: false` = mode buttons |
| `toggleGrid()` · `toggleCompare()` · `focusPane(_:)` · `exitCompare()` | display / compare |
| `toggleInfo()` · `toggleFilmstrip()` | `I`, `Cmd+S` |
| `moveRejected() async -> String?` | returns the alert prompt, or `nil` (snackbar already posted) |
| `performMoveRejected() async` | run after the user confirms; rescans afterwards |
| `moveShownPrompt(to: URL) async -> String?` | returns the alert prompt for moving `files` into `to`, or `nil` (snackbar already posted) |
| `performMoveShown(to: URL) async` | run after the user confirms; rescans afterwards |
| `flushPendingWrites() async` | before quit; `loadAllRatings() async` for a full disk sweep |
| `filmstripVisibleRange(_:)` · `gridVisibleRange(_:)` · `restartBackgroundSweep()` | preload hooks |
| `persistShootStats()` | call on quit; also writes the folder summary |
| `folderSummary(for:)` · `reloadFolderSummaries()` | cached dashboard summary of a recent folder |
| `post(_ event: SnackbarEvent)` · `clearSnackbar()` | snackbar |

### PreloadScheduler

`@MainActor @Observable`, owned by `Library`. Read images with
`preview(for: URL) -> CGImage?`, `thumb80(for:)`, `thumb200(for:)`,
and `progressFraction` for the "Loading: N%" label. `previewRevision` is bumped on every
preview arrival so `preview(for:)` participates in observation. Drive it through the
`Library` hooks above; the direct API is `setCurrent(_:)`, `preloadNearby(index:in:)`,
`preloadFilmstrip(range:in:)`, `gridVisibleRange(_:in:)`,
`startBackgroundSweep(from:in:)`, `stopBackgroundSweep()`, `reset(totalFileCount:)`,
`closeFolder()`, `cancelAll()`.

Concurrency: 1 current image, 6 nearby previews, 4 thumbnails, 1 full RAW develop.

## Deliberate deviations from the Python app

- Ratings, previews and thumbnails are keyed by file URL rather than by list index.
- One shared 1.5 GB preview cache instead of 1.5 GB per view mode.
- `move_rejected` appends ` 2`, ` 3`… to a colliding destination instead of overwriting.
- A RAW whose embedded preview is far smaller than the source gets a `CIRAWFilter`
  full develop on a background queue, swapped in when ready (the DJI DNG path).
- `showInfo` and `filmstripVisible` persist in `UserDefaults`.
- Caches live in `~/Library/Caches/dev.yannickpulver.rawviewer/`, shoot stats in
  `~/Library/Application Support/RAW Viewer/`. The old `~/.cache/raw-viewer/`
  recents and shoot stats are imported once on first launch.
- The disk thumbnail cache is one file per entry (mtime in the filename), written
  atomically, and trimmed from 2 GB back to 1.5 GB in the background (swept once at launch).
- `Cmd+O` opens the folder panel. The Python app had no such shortcut; it is the standard
  macOS binding and does not collide with anything in spec 02.
- `Cmd+H`, `Cmd+M` and `Cmd+,` fall through to the system (hide / minimise / preferences)
  instead of firing the bare `H` (help) and `M` (video mode) actions. Spec 02 says `H` and `M`
  ignore modifiers; on macOS those two combinations belong to the system.
- The menu bar registers **no** bare-letter / digit / arrow / space / escape key equivalents.
  The single key dispatcher owns those keys and refuses to run while a modal is up; a menu key
  equivalent would bypass that and rate or reject a file from inside an `NSOpenPanel` or
  `NSAlert`. The menu shows those keys as text in the item title instead.
- The floating chrome is native macOS, not a pixel copy of the Qt original: the filter bar and
  the mode switcher are `.segmented` `Picker`s, the subfolder chips and the `📂` / `?` / `⏱`
  buttons are bordered/capsule system buttons with SF Symbols, and every floating panel sits on
  a system material (Liquid Glass on macOS 26+) over a dark scrim. Key bindings and the
  canvas / filmstrip / grid are unchanged; excluded chips render at 50 % opacity instead of
  struck through.
- The top chrome is a unified window toolbar, transparent over the image, instead of widgets
  floating next to the traffic lights: a Back button (same as `Esc`), the mode switcher, the
  subfolder chips as toolbar toggles, and the active rating filter as a compact amber capsule
  (`≥3★ · 1/30`) at the trailing edge. The toolbar drags the window, the position / info
  block sits below it, and the update banner lives bottom-left next to `?` / `⏱`.
- The empty-state dashboard shows, per recent folder, the RAW / JPG / MOV counts and the rating
  histogram of the last time that folder was open, cached in
  `~/Library/Application Support/RAW Viewer/folder_summaries.json` (`FolderSummaryStore`).
  Recent folders are never rescanned in the background. To make the cached histogram complete,
  a successful scan now kicks off a full `loadAllRatings()` sweep in the background; the Python
  app only swept ratings on demand (filters, `Shift+R`, move-rejected, Resolve export).
  The summary is rewritten on close, on quit, after a move-rejected rescan, and 1 s after the
  last rating key.
- `PreloadScheduler.preview(for:)` is a peek: it does not refresh LRU recency, because SwiftUI
  reads it from `body`. `setCurrent(_:)` does the recency touch.
- Rating filter has an 8th bucket, "unrated only" (`RatingFilter.unratedValue`, `-2`; matches
  `rating == 0`), as a toolbar segment between `All` and `1+`, a Rate menu item, and `Opt+Cmd+0`.
  No Python-app equivalent.
- File menu "Move Shown Files to Folder…" (`Shift+Cmd+M`) moves every file of the current
  filtered timeline, plus its XMP sidecar, into one user-chosen folder, flat. See
  `docs/spec/05-ratings-and-xmp.md` §10 addendum and `Sidecar/MoveFiles.swift`. No Python-app
  equivalent.

Behaviour the spec flags as "likely unintended" is kept as shipped, notably: the `All`
rating bucket hides rejected files, and the `J` snackbar guard only fires from RAW mode.
