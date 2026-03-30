"""Extract embedded JPEG previews from RAW files with correct orientation."""

from pathlib import Path
from typing import Optional, Tuple
import rawpy
import exifread
from PyQt6.QtGui import QImage, QPixmap, QTransform, QImageReader
from PyQt6.QtCore import QByteArray, QBuffer, QIODevice, Qt, QSize


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


def extract_thumbnail_bytes(path: Path, size: int = 100, quality: int = 85) -> Optional[bytes]:
    """Extract thumbnail and return as JPEG bytes for caching."""
    pixmap = extract_thumbnail(path, size)
    if pixmap is None:
        return None

    # Convert to JPEG bytes
    byte_array = QByteArray()
    buffer = QBuffer(byte_array)
    buffer.open(QIODevice.OpenModeFlag.WriteOnly)
    pixmap.save(buffer, "JPEG", quality)
    buffer.close()
    return bytes(byte_array.data())


def _get_jpeg_orientation(path: Path) -> int:
    """Read EXIF orientation from JPEG file."""
    try:
        with open(path, 'rb') as f:
            tags = exifread.process_file(f, stop_tag='Image Orientation', details=False)
            if 'Image Orientation' in tags:
                return tags['Image Orientation'].values[0]
    except Exception:
        pass
    return 1


def load_jpeg_preview(path: Path, max_size: int = 2560) -> Optional[QPixmap]:
    """Load JPEG file as QPixmap, downscaled for display performance."""
    try:
        reader = QImageReader(str(path))
        reader.setAutoTransform(True)
        orig_size = reader.size()
        if orig_size.isValid():
            # Downsample large images on decode
            scale = min(max_size / max(orig_size.width(), orig_size.height(), 1), 1.0)
            if scale < 1.0:
                reader.setScaledSize(QSize(
                    int(orig_size.width() * scale),
                    int(orig_size.height() * scale)
                ))
        image = reader.read()
        if image.isNull():
            return None
        return QPixmap.fromImage(image)
    except Exception as e:
        print(f"Error loading JPEG {path}: {e}")
        return None


def load_jpeg_thumbnail(path: Path, size: int = 100) -> Optional[QPixmap]:
    """Load JPEG thumbnail for filmstrip, downscaled on decode."""
    try:
        reader = QImageReader(str(path))
        reader.setAutoTransform(True)
        orig_size = reader.size()
        if orig_size.isValid():
            # Scale down to thumbnail size during decode
            reader.setScaledSize(orig_size.scaled(
                QSize(size, size),
                Qt.AspectRatioMode.KeepAspectRatio
            ))
        image = reader.read()
        if image.isNull():
            return None
        return QPixmap.fromImage(image)
    except Exception as e:
        print(f"Error loading JPEG thumbnail {path}: {e}")
        return None


def load_jpeg_thumbnail_bytes(path: Path, size: int = 100, quality: int = 85) -> Optional[bytes]:
    """Load JPEG thumbnail as bytes for caching."""
    pixmap = load_jpeg_thumbnail(path, size)
    if pixmap is None:
        return None
    byte_array = QByteArray()
    buffer = QBuffer(byte_array)
    buffer.open(QIODevice.OpenModeFlag.WriteOnly)
    pixmap.save(buffer, "JPEG", quality)
    buffer.close()
    return bytes(byte_array.data())


def load_video_thumbnail(path: Path, size: int = 100) -> Optional[QPixmap]:
    """Extract video thumbnail using macOS Quick Look."""
    try:
        import subprocess
        import tempfile

        with tempfile.TemporaryDirectory() as tmpdir:
            subprocess.run(
                ['qlmanage', '-t', '-s', str(size * 2), '-o', tmpdir, str(path)],
                capture_output=True, timeout=10
            )
            for f in Path(tmpdir).iterdir():
                if f.suffix == '.png':
                    pixmap = QPixmap(str(f))
                    if not pixmap.isNull():
                        return pixmap.scaled(
                            size, size,
                            Qt.AspectRatioMode.KeepAspectRatio,
                            Qt.TransformationMode.SmoothTransformation
                        )
        return None
    except Exception as e:
        print(f"Error loading video thumbnail {path}: {e}")
        return None


def load_video_thumbnail_bytes(path: Path, size: int = 100, quality: int = 85) -> Optional[bytes]:
    """Extract video thumbnail as JPEG bytes for caching."""
    pixmap = load_video_thumbnail(path, size)
    if pixmap is None:
        return None
    byte_array = QByteArray()
    buffer = QBuffer(byte_array)
    buffer.open(QIODevice.OpenModeFlag.WriteOnly)
    pixmap.save(buffer, "JPEG", quality)
    buffer.close()
    return bytes(byte_array.data())
