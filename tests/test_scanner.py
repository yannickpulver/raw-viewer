import io
import struct
from datetime import datetime
from pathlib import Path

from PIL import Image

from scanner import get_creation_time

DATE = '2026:05:23 10:38:44'
EXPECTED = datetime.strptime(DATE, '%Y:%m:%d %H:%M:%S').timestamp()
EXIF_IFD_TAG = 0x8769
DATE_TIME_ORIGINAL_TAG = 0x9003


def _exif_with_date() -> Image.Exif:
    exif = Image.Exif()
    exif.get_ifd(EXIF_IFD_TAG)[DATE_TIME_ORIGINAL_TAG] = DATE
    return exif


def _jpeg_with_exif() -> bytes:
    buf = io.BytesIO()
    Image.new('RGB', (4, 4)).save(buf, 'JPEG', exif=_exif_with_date())
    return buf.getvalue()


def _box(box_type: bytes, payload: bytes) -> bytes:
    return struct.pack('>I4s', 8 + len(payload), box_type) + payload


def _write_raf(path: Path) -> None:
    jpeg = _jpeg_with_exif()
    header = bytearray(b'FUJIFILMCCD-RAW 0201FF393103'.ljust(84, b'\0'))
    header += struct.pack('>II', 148, len(jpeg))
    header = header.ljust(148, b'\0')
    path.write_bytes(bytes(header) + jpeg)


def _write_cr3(path: Path) -> None:
    exif_ifd = Image.Exif()
    exif_ifd[DATE_TIME_ORIGINAL_TAG] = DATE
    tiff_blob = exif_ifd.tobytes()[6:]  # strip "Exif\0\0"
    canon_uuid = bytes.fromhex('85c0b687820f11e08111f4ce462b6a48')
    uuid_box = _box(b'uuid', canon_uuid + _box(b'CMT1', b'x' * 8) + _box(b'CMT2', tiff_blob))
    moov = _box(b'moov', uuid_box + _box(b'mvhd', b'\0' * 100))
    path.write_bytes(_box(b'ftyp', b'crx ') + moov + _box(b'mdat', b'\0' * 16))


def test_raf_uses_embedded_jpeg_exif_date(tmp_path):
    raf = tmp_path / 'DSCF0001.RAF'
    _write_raf(raf)
    assert get_creation_time(raf, use_cache=False) == EXPECTED


def test_cr3_uses_cmt2_exif_date(tmp_path):
    cr3 = tmp_path / 'IMG_0001.CR3'
    _write_cr3(cr3)
    assert get_creation_time(cr3, use_cache=False) == EXPECTED


def test_jpeg_exif_date_still_read_directly(tmp_path):
    jpg = tmp_path / 'IMG_0001.jpg'
    jpg.write_bytes(_jpeg_with_exif())
    assert get_creation_time(jpg, use_cache=False) == EXPECTED


def test_unparseable_file_falls_back_to_filesystem_time(tmp_path):
    bogus = tmp_path / 'broken.RAF'
    bogus.write_bytes(b'not a raf file')
    stat = bogus.stat()
    assert get_creation_time(bogus, use_cache=False) == getattr(stat, 'st_birthtime', stat.st_mtime)


def test_subfolder_counts_groups_by_first_level_folder(tmp_path):
    from scanner import subfolder_counts
    files = [
        tmp_path / 'X100VI' / 'a.RAF',
        tmp_path / 'X100VI' / 'b.RAF',
        tmp_path / 'R5' / 'c.CR3',
        tmp_path / 'DJI' / 'DCIM' / 'd.DNG',
        tmp_path / 'e.RAF',
    ]
    assert subfolder_counts(files, tmp_path) == [
        ('DJI', 1), ('R5', 1), ('X100VI', 2), (tmp_path.name, 1),
    ]


def test_subfolder_counts_empty():
    from scanner import subfolder_counts
    assert subfolder_counts([], Path('/x')) == []


def test_subfolder_name(tmp_path):
    from scanner import subfolder_name
    assert subfolder_name(tmp_path / 'X100VI' / 'a.RAF', tmp_path) == 'X100VI'
    assert subfolder_name(tmp_path / 'DJI' / 'DCIM' / 'd.DNG', tmp_path) == 'DJI'
    assert subfolder_name(tmp_path / 'e.RAF', tmp_path) == tmp_path.name
