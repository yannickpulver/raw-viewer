# RAW Viewer

Fast RAW image viewer for photo culling with Lightroom-compatible ratings.

![Screenshot](docs/screenshot.png)

## Features

- Load RAW files from folder (recursive)
- Fast preview using embedded JPEGs
- Star ratings (0-5) saved to XMP sidecar files
- Filmstrip navigation
- Pinch-to-zoom
- Filter by minimum rating

## Install

```bash
pip install -r requirements.txt
```

## Run

```bash
python main.py "/path/to/photos"
```

Or run without arguments to open folder picker.

## Build Executable

```bash
pip install pyinstaller
pyinstaller --onefile --windowed --name "RAW Viewer" main.py
```

Output: `dist/RAW Viewer.app`

## Shortcuts

| Key | Action |
|-----|--------|
| `←` `→` | Previous / Next image |
| `0-5` | Set rating (auto-advances) |
| `Shift+0-5` | Filter by minimum rating |
| `F` | Toggle info overlay |
| `O` | Open folder in Finder |
| `Cmd+Q` | Quit |
| `Esc` | Quit |

Pinch trackpad to zoom, drag to pan.
