# 08 — Build, Versioning and Distribution

---

## 1. Version scheme

Semantic versioning, `MAJOR.MINOR.PATCH`, no pre-release or build suffixes.
Current value at the time this spec was written: **`0.4.5`**.

| Artefact | Content | Source |
|---|---|---|
| `VERSION` | a single line, e.g. `0.4.5`, with a trailing newline | `VERSION` |
| `version.py` | reads and strips `VERSION`, exposing `VERSION: str` | `version.py:11` |
| Git tag | `v` + the version, e.g. `v0.4.5` | `.github/workflows/build.yml` |
| Release name | `RAW Viewer 0.4.5` | `.github/workflows/build.yml` |
| Homebrew cask version | `0.4.5` (tag with the `v` stripped) | `.github/workflows/update-homebrew-tap.yml` |

`version.py` resolves the file relative to `sys._MEIPASS` when frozen and
relative to its own directory otherwise (`version.py:6`). If the file is
missing, `VERSION` becomes the literal string `"dev"` (`version.py:12`), which
disables the update check (`viewer.py:2592`).

The version is bumped by hand in the same commit as the feature, which is
visible throughout the git log ("... ; bump version to 0.4.5"). Pushing to
`main` with a bumped `VERSION` is what cuts a release.

**Carry over**: the version number `0.4.5` as the starting point for the Swift
app, and the `v`-prefixed tag convention, because the update checker compares
against `tag_name` with the `v` stripped.

---

## 2. Bundle identity

| Key | Value | Source |
|---|---|---|
| Bundle identifier | `dev.yannickpulver.rawviewer` | `RAW Viewer.spec:49` |
| Bundle name | `RAW Viewer.app` | `RAW Viewer.spec:47` |
| Executable name | `RAW Viewer` | `RAW Viewer.spec:24` |
| Icon | `icon.icns` (5.5 MB, in the repo root) | `RAW Viewer.spec:48` |
| Window title / app name shown to the user | `RAW Viewer` | `viewer.py:976` |

**Carry over**: the bundle identifier `dev.yannickpulver.rawviewer` exactly. It
is what the Homebrew cask and any existing user data key off.

---

## 3. PyInstaller spec

`RAW Viewer.spec`. Only the parts that affect runtime behaviour are listed;
everything else is PyInstaller boilerplate.

| Setting | Value | Why it matters |
|---|---|---|
| Entry point | `main.py` | |
| `datas` | `[('VERSION', '.')]` | the `VERSION` file is bundled at the root of `sys._MEIPASS`, which is how the frozen app knows its version and enables the update check |
| `exclude_binaries=True` + `COLLECT` | one-directory bundle, not one-file | chosen for faster startup (commit `0d8b08b`) |
| `console=False` | no terminal window | `print()` diagnostics go nowhere visible |
| `upx=True` | binaries are UPX-compressed | |
| `BUNDLE(icon=..., bundle_identifier=...)` | app bundle metadata | |

Not present, and therefore **not** in the shipped app:

- No `info_plist` dictionary. There are no custom `Info.plist` keys beyond what
  PyInstaller generates.
- **No `CFBundleDocumentTypes`** — the app is not registered as a handler for
  any file type. You cannot open a RAW file with it from Finder, and dropping
  files (as opposed to folders) on the Dock icon does nothing.
- **No `UTImportedTypeDeclarations`.**
- No `NSHighResolutionCapable` override, no `LSMinimumSystemVersion`, no
  `NSHumanReadableCopyright`, no privacy usage descriptions.

A Swift rewrite should consider adding document types for the RAW extensions
listed in `03`, and a folder drop handler on the Dock icon. Both are new
behaviour.

---

## 4. Entitlements

`entitlements.plist`, applied on every `codesign` invocation with
`--options runtime`:

```xml
<key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
<key>com.apple.security.cs.disable-library-validation</key><true/>
```

Both exist purely because a frozen CPython interpreter JITs and dynamically
loads unsigned shared objects. **Do not carry these over.** A Swift app needs
neither, and both weaken the hardened runtime.

The app is not sandboxed. There is no `com.apple.security.app-sandbox`
entitlement and no file-access entitlements. If a rewrite adopts the sandbox it
will need user-selected read/write access, and the `_rejected/` move plus XMP
sidecar writes need write access to the folder the user picked, which a security
scoped bookmark covers.

---

## 5. Build and release pipeline

`.github/workflows/build.yml`. Runs on every push to `main` and on every pull
request against `main`. Only pushes to `main` publish.

| Step | Detail |
|---|---|
| Runner | `macos-latest` |
| Python | 3.13 |
| Dependencies | `requirements.txt` plus `pyinstaller` |
| Build | `pyinstaller "RAW Viewer.spec" --noconfirm` |
| Certificate | a base64 `.p12` from secrets, imported into a temporary keychain |
| Signing identity | `Developer ID Application: Yannick Pulver (<APPLE_TEAM_ID>)` |
| Signing order | framework inner binaries, then framework bundles, then loose `.dylib`/`.so`, then standalone executables in `MacOS`, `Resources` and `Frameworks`, then the app bundle last |
| Verification | `codesign --verify --deep --strict` |
| Archive | `ditto -c -k --keepParent` (not `zip`, which loses the symlinks notarization needs — commit `18dd692`) |
| Notarize | `xcrun notarytool submit --wait`; parses the output, fetches the log and fails the build on `status: Invalid`, and also fails if `status: Accepted` is absent |
| Staple | `xcrun stapler staple` |
| Re-archive | the zip is deleted and rebuilt after stapling (commit `e9135be`) |
| Release | `softprops/action-gh-release@v2`, tag `v{version}`, name `RAW Viewer {version}`, asset `dist/RAW-Viewer.zip`, auto-generated release notes |
| Downstream | calls the Homebrew tap workflow with the tag |

Required GitHub secrets: `APPLE_CERTIFICATE_BASE64`,
`APPLE_CERTIFICATE_PASSWORD`, `APPLE_TEAM_ID`, `APPLE_ID`,
`APPLE_APP_PASSWORD`, `HOMEBREW_TAP_TOKEN`.

The release asset filename is always `RAW-Viewer.zip`, with the version carried
only by the tag.

---

## 6. Homebrew cask

`.github/workflows/update-homebrew-tap.yml`. Triggered by a published release,
by the build workflow, or manually with a tag input.

It downloads the release asset, computes its SHA-256, checks out
`yannickpulver/homebrew-tap`, and writes `Casks/raw-viewer.rb`:

```ruby
cask "raw-viewer" do
  version "0.4.5"
  sha256 "<computed>"

  url "https://github.com/yannickpulver/raw-viewer/releases/download/v#{version}/RAW-Viewer.zip"
  name "RAW Viewer"
  desc "RAW image viewer"
  homepage "https://github.com/yannickpulver/raw-viewer"

  app "RAW Viewer.app"

  zap trash: [
    "~/Library/Preferences/com.yannickpulver.raw-viewer.plist",
    "~/Library/Application Support/RAW Viewer",
  ]
end
```

Install command, as documented in `README.md`:

```sh
brew install --cask yannickpulver/tap/raw-viewer
```

**Carry over**: the cask name `raw-viewer`, the tap `yannickpulver/tap`, the
asset name `RAW-Viewer.zip` and the download URL shape. Changing any of these
breaks existing installs' upgrade path.

Note: the `zap` paths do not match anything the app actually creates. The real
data lives in `~/.cache/raw-viewer/` (see `07`). Note: likely unintended. A
rewrite that stores data under
`~/Library/Application Support/RAW Viewer` would make the existing zap stanza
correct for the first time.

Note: the plist path in the zap stanza uses the identifier
`com.yannickpulver.raw-viewer`, while the app's actual bundle identifier is
`dev.yannickpulver.rawviewer`. Note: likely unintended.

---

## 7. Update check endpoint

Covered in detail in `01` section 20 and `07` section 10. Summary for the
distribution side:

- Endpoint: `https://api.github.com/repos/yannickpulver/raw-viewer/releases/latest`.
- Compared field: `tag_name`, with a leading `v` stripped, against the bundled
  `VERSION` string.
- Comparison is string inequality. Commit `89161ae` fixed the case where the
  `v` prefix caused a permanent "update available" banner; the remaining
  weakness is that a locally built newer version also triggers the banner.
- The banner links to the release's `html_url`, which is the human-readable
  release page, not the asset.
- There is no in-app download, no delta updates, no signature verification of
  the update, and no user preference to disable the check.

**Carry over or replace**: the endpoint and the "release page in the browser"
behaviour are fine to keep. If the rewrite adopts Sparkle it needs an appcast
feed, which the release pipeline would have to generate. Keeping the existing
GitHub API check is the lower-effort path and preserves current behaviour
exactly.

---

## 8. Development dependencies

`requirements.txt`:

```
PyQt6>=6.5.0
rawpy>=0.19.0
numpy>=1.24.0
pyobjc-framework-Cocoa>=10.0
exifread>=3.0.0
Pillow>=10.0.0
```

`requirements-dev.txt`: `pytest`.

Local run: `python main.py "/path/to/photos"`, or without arguments to start at
the folder picker.

Tests: `pytest` from the repo root. Five test modules, all pure logic with no Qt
or filesystem-heavy fixtures except `tmp_path`:

| Module | Covers |
|---|---|
| `tests/test_scanner.py` | RAF and CR3 embedded EXIF date extraction, JPEG date, filesystem fallback, subfolder grouping |
| `tests/test_rating.py` | XMP round trip 0–5, reject `-1`, updating an existing sidecar, clamping |
| `tests/test_pixmap_cache.py` | LRU eviction, recency refresh, cost update on re-put, never evicting the last item |
| `tests/test_move_rejected.py` | sibling discovery, deduplication, subpath preservation, stopping at the first error, scanner skipping `_rejected/` |
| `tests/test_grid_view.py` | all grid layout maths |

There is no UI test, no snapshot test and no integration test. The repository
also contains two stray artefacts that are not part of the build: `=10.0` (a pip
install log accidentally created by an unquoted `pip install pyobjc>=10.0`) and
`firebase-debug.log`. Neither is referenced by anything.
