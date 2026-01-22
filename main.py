#!/usr/bin/env python3
"""RAW image viewer with rating support."""

import sys
from pathlib import Path

from PyQt6.QtWidgets import QApplication, QFileDialog, QMessageBox

from scanner import scan_folder
from viewer import ImageViewer


def main():
    app = QApplication(sys.argv)

    # Get folder from args or picker
    if len(sys.argv) > 1:
        folder = Path(sys.argv[1])
    else:
        folder_str = QFileDialog.getExistingDirectory(
            None,
            "Select folder with RAW files",
            str(Path.home())
        )
        if not folder_str:
            sys.exit(0)
        folder = Path(folder_str)

    # Scan for RAW files
    print(f"Scanning {folder}...")
    files = scan_folder(folder)

    if not files:
        QMessageBox.warning(
            None,
            "No RAW files",
            f"No RAW files found in {folder}"
        )
        sys.exit(1)

    print(f"Found {len(files)} RAW files")

    # Launch viewer
    viewer = ImageViewer(files)
    viewer.show()

    sys.exit(app.exec())


if __name__ == "__main__":
    main()
