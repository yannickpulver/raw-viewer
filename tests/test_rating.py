from pathlib import Path

from rating import read_rating, write_rating


def test_write_read_roundtrip_stars(tmp_path: Path):
    raw = tmp_path / "IMG_0001.cr3"
    raw.touch()
    for r in range(0, 6):
        assert write_rating(raw, r)
        assert read_rating(raw) == r


def test_write_read_reject(tmp_path: Path):
    raw = tmp_path / "IMG_0002.cr3"
    raw.touch()
    assert write_rating(raw, -1)
    assert read_rating(raw) == -1
    content = (tmp_path / "IMG_0002.xmp").read_text()
    assert 'xmp:Rating="-1"' in content


def test_update_existing_sidecar_star_to_reject_and_back(tmp_path: Path):
    raw = tmp_path / "IMG_0003.cr3"
    raw.touch()
    write_rating(raw, 3)
    write_rating(raw, -1)
    assert read_rating(raw) == -1
    write_rating(raw, 4)
    assert read_rating(raw) == 4


def test_clamping(tmp_path: Path):
    raw = tmp_path / "IMG_0004.cr3"
    raw.touch()
    write_rating(raw, -5)
    assert read_rating(raw) == -1
    write_rating(raw, 9)
    assert read_rating(raw) == 5
