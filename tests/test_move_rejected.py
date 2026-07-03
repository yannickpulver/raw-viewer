from pathlib import Path

from move_rejected import collect_move_set, find_siblings, move_to_rejected
from scanner import scan_folder


def make(p: Path):
    p.parent.mkdir(parents=True, exist_ok=True)
    p.touch()
    return p


def test_find_siblings_same_stem(tmp_path: Path):
    raw = make(tmp_path / "IMG_0001.CR3")
    jpg = make(tmp_path / "IMG_0001.jpg")
    xmp = make(tmp_path / "IMG_0001.xmp")
    make(tmp_path / "IMG_0002.CR3")  # different stem, excluded
    siblings = find_siblings(raw)
    assert set(siblings) == {jpg, xmp}


def test_collect_move_set_dedupes_pairs(tmp_path: Path):
    raw = make(tmp_path / "a.cr3")
    jpg = make(tmp_path / "a.jpg")
    result = collect_move_set([raw, jpg])
    assert sorted(result, key=str) == sorted([raw, jpg], key=str)


def test_move_preserves_subpath(tmp_path: Path):
    f = make(tmp_path / "day1" / "IMG_0001.cr3")
    moved, error = move_to_rejected([f], tmp_path)
    assert moved == 1 and error == ""
    assert not f.exists()
    assert (tmp_path / "_rejected" / "day1" / "IMG_0001.cr3").exists()


def test_move_stops_on_missing_file(tmp_path: Path):
    a = make(tmp_path / "a.cr3")
    ghost = tmp_path / "ghost.cr3"  # never created
    b = make(tmp_path / "b.cr3")
    moved, error = move_to_rejected([a, ghost, b], tmp_path)
    assert moved == 1
    assert "ghost.cr3" in error
    assert b.exists()  # untouched after error


def test_scanner_skips_rejected_dir(tmp_path: Path):
    make(tmp_path / "keep.cr3")
    make(tmp_path / "_rejected" / "gone.cr3")
    files = scan_folder(tmp_path)
    assert [f.name for f in files] == ["keep.cr3"]
