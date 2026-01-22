#!/usr/bin/env python3
"""RAW image viewer with rating support."""

import sys
from pathlib import Path

from PyQt6.QtWidgets import QApplication

from scanner import scan_folder
from viewer import ImageViewer


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

    sys.exit(app.exec())


if __name__ == "__main__":
    main()
