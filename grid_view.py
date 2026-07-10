"""Grid view: virtualized thumbnail grid for glancing over many images."""

from typing import Dict, Tuple

from PyQt6.QtWidgets import QWidget, QScrollArea
from PyQt6.QtGui import QPixmap, QPainter, QColor, QPen
from PyQt6.QtCore import Qt, pyqtSignal, QTimer, QRect

CELL = 200
SPACING = 6


def columns_for_width(width: int, cell: int = CELL, spacing: int = SPACING) -> int:
    return max(1, (width - spacing) // (cell + spacing))


def cell_origin(index: int, columns: int, cell: int = CELL, spacing: int = SPACING) -> Tuple[int, int]:
    row, col = divmod(index, columns)
    return spacing + col * (cell + spacing), spacing + row * (cell + spacing)


def content_height(total: int, columns: int, cell: int = CELL, spacing: int = SPACING) -> int:
    if total <= 0:
        return 0
    rows = (total + columns - 1) // columns
    return spacing + rows * (cell + spacing)


def index_at(x: float, y: float, columns: int, total: int,
             cell: int = CELL, spacing: int = SPACING) -> int:
    stride = cell + spacing
    col = int(max(0.0, x - spacing) // stride)
    row = int(max(0.0, y - spacing) // stride)
    if col >= columns:
        return -1
    idx = row * columns + col
    return idx if 0 <= idx < total else -1


def visible_index_range(top: int, bottom: int, columns: int, total: int,
                        cell: int = CELL, spacing: int = SPACING) -> Tuple[int, int]:
    if total <= 0:
        return (0, -1)
    stride = cell + spacing
    first_row = max(0, (top - spacing) // stride)
    last_row = max(0, (bottom - spacing) // stride)
    first = min(total - 1, first_row * columns)
    last = min(total - 1, (last_row + 1) * columns - 1)
    return first, last


def move_vertical(index: int, columns: int, total: int, delta_rows: int) -> int:
    """Move selection by rows; clamp to last item, stay put at edges."""
    if total <= 0:
        return index
    target = index + delta_rows * columns
    if delta_rows > 0:
        if index // columns >= (total - 1) // columns:
            return index
        return min(target, total - 1)
    return index if target < 0 else target
