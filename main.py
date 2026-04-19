#!/usr/bin/env python3
"""RAW image viewer with rating support."""

import sys
from pathlib import Path

from PyQt6.QtWidgets import QApplication

from scanner import scan_folder
from viewer import ImageViewer


def _apply_srgb_window_colorspace(widget):
    """Tag NSWindow as sRGB so AppKit color-manages backing store to the display."""
    try:
        import objc
        from AppKit import NSColorSpace
        ns_view = objc.objc_object(c_void_p=widget.winId().__int__())
        ns_window = ns_view.window()
        if ns_window is not None:
            ns_window.setColorSpace_(NSColorSpace.sRGBColorSpace())
    except Exception as e:
        print(f"colorspace hook failed: {e}")


def main():
    app = QApplication(sys.argv)

    # Get folder from args (optional)
    files = []
    if len(sys.argv) > 1:
        folder = Path(sys.argv[1])
        print(f"Scanning {folder}...")
        files = scan_folder(folder)
        if files:
            print(f"Found {len(files)} RAW files")

    # Launch viewer (with or without files)
    viewer = ImageViewer(files if files else None)
    viewer.show()
    _apply_srgb_window_colorspace(viewer)

    sys.exit(app.exec())


if __name__ == "__main__":
    main()
