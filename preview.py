"""Extract embedded JPEG previews from RAW files with correct orientation."""

from pathlib import Path
from typing import Optional, Tuple
import rawpy
from PyQt6.QtGui import QImage, QPixmap, QTransform
from PyQt6.QtCore import QByteArray, Qt


def get_orientation_transform(orientation: int) -> QTransform:
    """Get QTransform for EXIF orientation value."""
    transform = QTransform()

    if orientation == 1:
        pass  # Normal
    elif orientation == 2:
        transform.scale(-1, 1)  # Flip horizontal
    elif orientation == 3:
        transform.rotate(180)
    elif orientation == 4:
        transform.scale(1, -1)  # Flip vertical
    elif orientation == 5:
        transform.rotate(90)
        transform.scale(-1, 1)
    elif orientation == 6:
        transform.rotate(90)
    elif orientation == 7:
        transform.rotate(-90)
        transform.scale(-1, 1)
    elif orientation == 8:
        transform.rotate(-90)

    return transform


def extract_preview(path: Path, thumbnail: bool = False) -> Optional[QPixmap]:
    """Extract embedded JPEG from RAW file, return as QPixmap with correct orientation.

    Args:
        path: Path to RAW file
        thumbnail: If True, return smaller thumbnail for filmstrip
    """
    try:
        with rawpy.imread(str(path)) as raw:
            # Get orientation
            orientation = raw.sizes.flip
            # rawpy flip: 0=none, 3=180, 5=90CCW, 6=90CW
            # Map to EXIF-like values
            orientation_map = {0: 1, 3: 3, 5: 8, 6: 6}
            exif_orientation = orientation_map.get(orientation, 1)

            pixmap = None

            # Try to get embedded thumbnail/preview
            try:
                thumb = raw.extract_thumb()
                if thumb.format == rawpy.ThumbFormat.JPEG:
                    data = QByteArray(thumb.data)
                    image = QImage()
                    image.loadFromData(data, "JPEG")
                    pixmap = QPixmap.fromImage(image)
                elif thumb.format == rawpy.ThumbFormat.BITMAP:
                    h, w = thumb.data.shape[:2]
                    image = QImage(
                        thumb.data.tobytes(),
                        w, h,
                        3 * w,
                        QImage.Format.Format_RGB888
                    )
                    pixmap = QPixmap.fromImage(image.copy())
            except rawpy.LibRawNoThumbnailError:
                pass

            # Fallback: quick half-size postprocess
            if pixmap is None:
                rgb = raw.postprocess(
                    half_size=True,
                    use_camera_wb=True,
                    no_auto_bright=True,
                    output_bps=8
                )
                h, w = rgb.shape[:2]
                image = QImage(
                    rgb.tobytes(),
                    w, h,
                    3 * w,
                    QImage.Format.Format_RGB888
                )
                pixmap = QPixmap.fromImage(image.copy())

            # Apply orientation
            if pixmap and exif_orientation != 1:
                transform = get_orientation_transform(exif_orientation)
                pixmap = pixmap.transformed(transform)

            return pixmap

    except Exception as e:
        print(f"Error loading {path}: {e}")
        return None


def extract_thumbnail(path: Path, size: int = 100) -> Optional[QPixmap]:
    """Extract small thumbnail for filmstrip - optimized for speed."""
    try:
        with rawpy.imread(str(path)) as raw:
            # Get orientation
            orientation = raw.sizes.flip
            orientation_map = {0: 1, 3: 3, 5: 8, 6: 6}
            exif_orientation = orientation_map.get(orientation, 1)

            pixmap = None

            # Try embedded thumbnail first (fastest)
            try:
                thumb = raw.extract_thumb()
                if thumb.format == rawpy.ThumbFormat.JPEG:
                    data = QByteArray(thumb.data)
                    image = QImage()
                    image.loadFromData(data, "JPEG")
                    pixmap = QPixmap.fromImage(image)
                elif thumb.format == rawpy.ThumbFormat.BITMAP:
                    h, w = thumb.data.shape[:2]
                    image = QImage(
                        thumb.data.tobytes(),
                        w, h,
                        3 * w,
                        QImage.Format.Format_RGB888
                    )
                    pixmap = QPixmap.fromImage(image.copy())
            except rawpy.LibRawNoThumbnailError:
                # Fallback: very quick decode
                rgb = raw.postprocess(
                    half_size=True,
                    use_camera_wb=True,
                    no_auto_bright=True,
                    output_bps=8
                )
                h, w = rgb.shape[:2]
                image = QImage(
                    rgb.tobytes(),
                    w, h,
                    3 * w,
                    QImage.Format.Format_RGB888
                )
                pixmap = QPixmap.fromImage(image.copy())

            if pixmap:
                # Apply orientation
                if exif_orientation != 1:
                    transform = get_orientation_transform(exif_orientation)
                    pixmap = pixmap.transformed(transform)

                # Scale to thumbnail size
                return pixmap.scaled(
                    size, size,
                    Qt.AspectRatioMode.KeepAspectRatio,
                    Qt.TransformationMode.FastTransformation
                )
            return None

    except Exception as e:
        print(f"Error loading thumbnail {path}: {e}")
        return None
