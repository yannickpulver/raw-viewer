# RAW Viewer — Rewrite Spec

## What this is

This folder is the complete behavioural specification of the existing RAW Viewer
(Python 3 / PyQt6 / rawpy, ~4200 lines, macOS only). It exists so the app can be
rewritten from scratch in Swift by someone (or some agent) who never reads the
Python source.

The spec plus the repository `README.md` is the input. Anything not written down
here does not exist in the rewrite.

## What the app is

RAW Viewer is a macOS photo culling tool. You point it at a folder of camera
files, it scans recursively, sorts by capture date, and shows one image at a
time on a black full-bleed canvas with a horizontal filmstrip underneath. You
walk the shoot with the arrow keys and press `0`–`5` to rate or `X` to reject.
Ratings are written to Adobe XMP sidecar files (`xmp:Rating`), so Lightroom
picks them up. Previews come from the embedded JPEG inside the RAW file, which
is why it is fast. The same window also handles JPEG folders and video folders
(MOV/MP4/M4V with playback). Finished culls can be pushed into DaVinci Resolve,
where star ratings become clip colours, keywords and "Good Take" flags.

## How to use this spec for a rewrite

1. Read `01` and `02` first. They define what the user sees and what every key
   does. That is the contract.
2. `03`–`05` define the data layer: which files are found, how previews are
   produced, how ratings are stored. These are the parts where getting a
   constant wrong produces a subtly wrong app.
3. `06`–`08` are integrations and packaging. `06` in particular has a
   constraint for Swift (see below).
4. `09` is the current implementation's shape. Treat it as background, not as
   a blueprint. The Swift app should not copy the module layout.

Every behavioural claim cites `file.py:line` from the original repo at version
`0.4.5`. Where the code does something that looks accidental, the spec says what
it *does* and adds a "note: likely unintended" line. Do not silently fix those
during the rewrite; decide deliberately.

## Index

| File | Contents |
|---|---|
| `01-features-and-ux.md` | Every user-facing feature, window layout, overlays, modes, states, exact pixel and colour constants. |
| `02-keyboard-and-input.md` | Complete table of every key, mouse, trackpad and gesture binding with context and effect. |
| `03-file-scanning-and-formats.md` | Supported extensions, recursive scan rules, date extraction, sort order, subfolder chips. |
| `04-preview-and-thumbnails.md` | Preview and thumbnail pipelines, orientation mapping, colour handling, caches, preloading. |
| `05-ratings-and-xmp.md` | XMP sidecar format byte for byte, read/update rules, reject handling, move-rejected, shoot stats. |
| `06-davinci-resolve-export.md` | Resolve discovery, connection, project creation, rating mapping, and how to run the export from Swift without Python. |
| `07-persistence-and-settings.md` | Everything written to disk: exact paths, formats, defaults, what is *not* persisted. |
| `08-build-and-distribution.md` | Version scheme, bundle identity, signing, notarization, Homebrew cask, release flow. |
| `09-architecture-notes.md` | Module map, threading, signal flow, known pitfalls, tech debt, suggested Swift mapping. |

## Behaviour the rewrite must reproduce vs implementation details it may replace

The Python app contains a number of workarounds that exist only because it is
Python and Qt. A native Swift app gets most of them for free. This section
separates the two so the rewrite does not port scaffolding.

### User-visible behaviour — must match

| Behaviour | Where specified |
|---|---|
| Files sorted by EXIF `DateTimeOriginal`, falling back to birthtime then mtime | `03` |
| RAF and CR3 capture dates are read correctly (many libraries miss these) | `03` |
| Exact supported extension lists for RAW / JPEG / video | `03` |
| `._*` files and `_rejected/` directories are never listed | `03` |
| Image orientation is applied automatically from the RAW flip value | `04` |
| Colours are correct on wide-gamut displays (no oversaturation) | `04`, `09` |
| XMP sidecar content and file naming, including `-1` for rejected | `05` |
| Rating `0` and "no sidecar" are both shown as zero stars | `05` |
| Auto-advance after rating, except on the last image | `01`, `02` |
| Every keyboard binding in `02` | `02` |
| Rating → Resolve clip colour / keyword / Good Take mapping | `06` |
| Recent folders list, max 5, most recent first, non-existent pruned | `07` |
| Update banner appears when the GitHub latest release tag differs from the built version | `01`, `08` |

### Implementation detail — replaceable

| Python/Qt mechanism | Why it exists | Swift equivalent |
|---|---|---|
| Hand-written RAF header parser reading the embedded JPEG offset at byte 84 (`scanner.py:105`) | exifread cannot see inside a RAF | `CGImageSourceCopyPropertiesAtIndex` via ImageIO usually returns `DateTimeOriginal` for RAF directly |
| Hand-written ISO-BMFF box walker for CR3 `moov > uuid(Canon) > CMT2` (`scanner.py:116`) | same reason, for Canon CR3 | ImageIO reads CR3 natively |
| `rawpy`/LibRaw `extract_thumb()` + `postprocess()` (`preview.py:49`) | no native RAW decoder in Python | `CGImageSourceCreateThumbnailAtIndex` for the embedded preview, `CIRAWFilter` for a full decode |
| `rawpy.sizes.flip` → EXIF orientation lookup table (`preview.py:62`) | LibRaw reports a non-EXIF flip code | ImageIO returns `kCGImagePropertyOrientation` directly |
| Pillow `ImageCms.profileToProfile` ICC→sRGB conversion, re-encoding the JPEG at quality 95 (`preview.py:266`) | Qt does not colour-manage embedded ICC profiles | ColorSync / CoreImage does this transparently; do not re-encode |
| Tagging the `NSWindow` colour space as sRGB through PyObjC (`main.py:18`) | works around Qt drawing untagged sRGB data into a P3 backing store | not needed; use correctly tagged `CGColorSpace` |
| `qlmanage -t` subprocess for video thumbnails, 10 s timeout, temp dir, PNG scrape (`preview.py:370`) | no Quick Look binding available | `QLThumbnailGenerator`, or `AVAssetImageGenerator` |
| `QT_MEDIA_BACKEND=darwin` env var before Qt loads (`main.py:10`) | Qt's default FFmpeg backend plays 60 fps clips at the wrong speed | `AVPlayer` |
| `xattr -px` / `xattr -wx` subprocesses with hand-built binary plists for Finder tags (`rating.py:86`) | no Python binding | `URLResourceValues.tagNames` |
| Manual `LruByteCache` with a byte budget (`pixmap_cache.py`) | Qt's cache is count-based | `NSCache` with `totalCostLimit` |
| Disk thumbnail cache as MD5-named `.jpg` + `.mtime` file pairs (`thumbnail_cache.py`) | hand rolled | keep the concept; a single store or `URLCache`-style directory is fine |
| Transparent title bar configured by walking `NSApplication.windows()` and matching on window title (`viewer.py:2534`) | PyQt cannot reach the `NSWindow` cleanly | `.titlebarAppearsTransparent` set directly |
| PyInstaller `onedir` bundle, `VERSION` file bundled as data (`RAW Viewer.spec`) | Python freezing | normal Xcode target; version from `Info.plist` |
| Hardened-runtime entitlements allowing unsigned executable memory and disabling library validation (`entitlements.plist`) | required by the Python interpreter | not needed; drop them |
| Manual `urllib` GitHub releases poll (`viewer.py:2590`) | no updater framework | Sparkle, or keep the same endpoint |

### DaVinci Resolve export in Swift

Blackmagic's scripting API is exposed only to Python and Lua, so the export
cannot be called from Swift directly. It does not need Python though. Resolve
ships its own script interpreter (`fuscript`) in its app bundle, and the Swift
app can spawn it with a bundled Lua script. That keeps full feature parity with
no extra dependency. See `06` section 1, option D, for what was verified and
what the rewrite agent still has to test against a running Resolve Studio.
