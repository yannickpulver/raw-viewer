"""Extract embedded JPEG previews from RAW files with correct orientation."""

from pathlib import Path
from typing import Optional, Tuple
import io
import rawpy
import exifread
from PIL import Image as PILImage
from PIL import ImageCms
from PyQt6.QtGui import QImage, QPixmap, QTransform, QImageReader, QColorSpace
from PyQt6.QtCore import QByteArray, QBuffer, QIODevice, Qt, QSize

_srgb_profile = ImageCms.createProfile("sRGB")
_srgb_icc_bytes = ImageCms.ImageCmsProfile(_srgb_profile).tobytes()
_qt_srgb = QColorSpace(QColorSpace.NamedColorSpace.SRgb)


def _tag_srgb(image: QImage) -> QImage:
    image.setColorSpace(_qt_srgb)
    return image


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
                    converted = _convert_icc_to_srgb(thumb.data)
                    data = QByteArray(converted)
                    image = QImage()
                    image.loadFromData(data, "JPEG")
                    _tag_srgb(image)
                    pixmap = QPixmap.fromImage(image)
                elif thumb.format == rawpy.ThumbFormat.BITMAP:
                    h, w = thumb.data.shape[:2]
                    image = QImage(
                        thumb.data.tobytes(),
                        w, h,
                        3 * w,
                        QImage.Format.Format_RGB888
                    ).copy()
                    _tag_srgb(image)
                    pixmap = QPixmap.fromImage(image)
            except rawpy.LibRawNoThumbnailError:
                pass

            # Fallback: full postprocess when no embedded thumb at all
            if pixmap is None:
                rgb = raw.postprocess(
                    half_size=True,
                    use_camera_wb=True,
                    no_auto_bright=True,
                    output_bps=8,
                    output_color=rawpy.ColorSpace.sRGB,
                )
                h, w = rgb.shape[:2]
                image = QImage(
                    rgb.tobytes(),
                    w, h,
                    3 * w,
                    QImage.Format.Format_RGB888
                ).copy()
                _tag_srgb(image)
                pixmap = QPixmap.fromImage(image)

            # Apply orientation
            if pixmap and exif_orientation != 1:
                transform = get_orientation_transform(exif_orientation)
                pixmap = pixmap.transformed(transform)

            return pixmap

    except Exception as e:
        print(f"Error loading {path}: {e}")
        return None


MIN_PREVIEW_WIDTH = 640


def needs_full_render(pixmap: Optional[QPixmap]) -> bool:
    """Check if a preview pixmap is too small and needs full RAW postprocessing."""
    return pixmap is not None and pixmap.width() < MIN_PREVIEW_WIDTH


def render_full_preview(path: Path) -> Optional[QPixmap]:
    """Full RAW postprocess for files with small embedded previews (e.g. DJI DNG)."""
    try:
        with rawpy.imread(str(path)) as raw:
            orientation = raw.sizes.flip
            orientation_map = {0: 1, 3: 3, 5: 8, 6: 6}
            exif_orientation = orientation_map.get(orientation, 1)

            rgb = raw.postprocess(
                half_size=True,
                use_camera_wb=True,
                no_auto_bright=True,
                output_bps=8,
                output_color=rawpy.ColorSpace.sRGB,
            )
            h, w = rgb.shape[:2]
            image = QImage(
                rgb.tobytes(),
                w, h,
                3 * w,
                QImage.Format.Format_RGB888
            ).copy()
            _tag_srgb(image)
            pixmap = QPixmap.fromImage(image)

            if exif_orientation != 1:
                transform = get_orientation_transform(exif_orientation)
                pixmap = pixmap.transformed(transform)

            return pixmap
    except Exception as e:
        print(f"Error rendering full preview {path}: {e}")
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
                    converted = _convert_icc_to_srgb(thumb.data)
                    data = QByteArray(converted)
                    image = QImage()
                    image.loadFromData(data, "JPEG")
                    _tag_srgb(image)
                    pixmap = QPixmap.fromImage(image)
                elif thumb.format == rawpy.ThumbFormat.BITMAP:
                    h, w = thumb.data.shape[:2]
                    image = QImage(
                        thumb.data.tobytes(),
                        w, h,
                        3 * w,
                        QImage.Format.Format_RGB888
                    ).copy()
                    _tag_srgb(image)
                    pixmap = QPixmap.fromImage(image)
            except rawpy.LibRawNoThumbnailError:
                # Fallback: very quick decode
                rgb = raw.postprocess(
                    half_size=True,
                    use_camera_wb=True,
                    no_auto_bright=True,
                    output_bps=8,
                    output_color=rawpy.ColorSpace.sRGB,
                )
                h, w = rgb.shape[:2]
                image = QImage(
                    rgb.tobytes(),
                    w, h,
                    3 * w,
                    QImage.Format.Format_RGB888
                ).copy()
                _tag_srgb(image)
                pixmap = QPixmap.fromImage(image)

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


def pixmap_from_jpeg_srgb(image_bytes: bytes) -> Optional[QPixmap]:
    """Decode JPEG bytes to QPixmap tagged sRGB. Returns None on failure."""
    image = QImage()
    if not image.loadFromData(QByteArray(image_bytes), "JPEG"):
        return None
    if image.isNull():
        return None
    _tag_srgb(image)
    return QPixmap.fromImage(image)


def _convert_icc_to_srgb(image_bytes: bytes) -> bytes:
    """Convert JPEG with embedded ICC profile to sRGB. Returns original bytes if no profile or already sRGB."""
    try:
        pil_img = PILImage.open(io.BytesIO(image_bytes))
        icc_data = pil_img.info.get("icc_profile")
        if not icc_data:
            return image_bytes
        src_profile = ImageCms.ImageCmsProfile(io.BytesIO(icc_data))
        # Check if already sRGB (avoid unnecessary conversion)
        desc = ImageCms.getProfileDescription(src_profile).strip()
        if "srgb" in desc.lower():
            return image_bytes
        pil_img = ImageCms.profileToProfile(pil_img, src_profile, _srgb_profile, outputMode="RGB")
        out = io.BytesIO()
        pil_img.save(out, format="JPEG", quality=95, icc_profile=_srgb_icc_bytes)
        return out.getvalue()
    except Exception:
        return image_bytes


def _load_jpeg_with_icc(path: Path) -> Optional[PILImage.Image]:
    """Load JPEG via Pillow, converting embedded ICC profile to sRGB."""
    try:
        pil_img = PILImage.open(path)
        icc_data = pil_img.info.get("icc_profile")
        if icc_data:
            src_profile = ImageCms.ImageCmsProfile(io.BytesIO(icc_data))
            desc = ImageCms.getProfileDescription(src_profile).strip()
            if "srgb" not in desc.lower():
                pil_img = ImageCms.profileToProfile(pil_img, src_profile, _srgb_profile, outputMode="RGB")
        return pil_img
    except Exception:
        return None


def _pil_to_qpixmap(pil_img: PILImage.Image) -> QPixmap:
    """Convert PIL Image to QPixmap (sRGB tagged)."""
    pil_img = pil_img.convert("RGB")
    data = pil_img.tobytes()
    image = QImage(data, pil_img.width, pil_img.height, 3 * pil_img.width, QImage.Format.Format_RGB888).copy()
    _tag_srgb(image)
    return QPixmap.fromImage(image)


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
    """Load JPEG file as QPixmap with ICC→sRGB conversion, downscaled for display."""
    try:
        pil_img = _load_jpeg_with_icc(path)
        if pil_img is None:
            return None
        # Apply EXIF orientation
        from PIL import ImageOps
        pil_img = ImageOps.exif_transpose(pil_img)
        # Downscale if needed
        w, h = pil_img.size
        scale = min(max_size / max(w, h, 1), 1.0)
        if scale < 1.0:
            pil_img = pil_img.resize((int(w * scale), int(h * scale)), PILImage.Resampling.LANCZOS)
        return _pil_to_qpixmap(pil_img)
    except Exception as e:
        print(f"Error loading JPEG {path}: {e}")
        return None


def load_jpeg_thumbnail(path: Path, size: int = 100) -> Optional[QPixmap]:
    """Load JPEG thumbnail with ICC→sRGB conversion, downscaled on decode."""
    try:
        pil_img = _load_jpeg_with_icc(path)
        if pil_img is None:
            return None
        from PIL import ImageOps
        pil_img = ImageOps.exif_transpose(pil_img)
        pil_img.thumbnail((size, size), PILImage.Resampling.LANCZOS)
        return _pil_to_qpixmap(pil_img)
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
