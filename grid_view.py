"""Grid view: virtualized thumbnail grid for glancing over many images."""

from typing import Dict, Tuple

from PyQt6.QtWidgets import QWidget, QScrollArea
from PyQt6.QtGui import QPixmap, QPainter, QColor, QPen
from PyQt6.QtCore import Qt, pyqtSignal, QTimer, QRect

CELL = 200
SPACING = 6


def columns_for_width(width: int, cell: int = CELL, spacing: int = SPACING) -> int:
    return max(1, (width - spacing) // (cell + spacing))


def cell_size_for_width(width: int, columns: int, cell: int = CELL, spacing: int = SPACING) -> int:
    """Stretch cells to fill the width; never smaller than the base cell."""
    return max(cell, (width - (columns + 1) * spacing) // columns)


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


class GridContent(QWidget):
    """Inner content widget: draws only the visible rows of thumbnails."""

    clicked = pyqtSignal(int)
    activated = pyqtSignal(int)
    visible_range_changed = pyqtSignal(int, int)  # first, last visible index

    def __init__(self, parent=None):
        super().__init__(parent)
        self.thumbnails: Dict[int, QPixmap] = {}
        self.fallback_thumbs: Dict[int, QPixmap] = {}
        self.current_index = 0
        self.total_count = 0
        self.columns = 1
        self.cell = CELL
        self.ratings: Dict[int, int] = {}
        self.setStyleSheet("background-color: transparent;")
        self.setAcceptDrops(True)
        self._dirty = False
        self._update_timer = QTimer()
        self._update_timer.setSingleShot(True)
        self._update_timer.timeout.connect(self._do_update)
        self._last_visible_range = (-1, -1)

    def _schedule_update(self):
        self._dirty = True
        if not self._update_timer.isActive():
            self._update_timer.start(50)  # Batch updates every 50ms

    def _do_update(self):
        if self._dirty:
            self._dirty = False
            self.update()

    def update_visible_range(self, viewport_rect):
        if self.total_count == 0:
            return
        new_range = visible_index_range(viewport_rect.top(), viewport_rect.bottom(),
                                        self.columns, self.total_count, self.cell)
        if new_range != self._last_visible_range:
            self._last_visible_range = new_range
            self.visible_range_changed.emit(*new_range)

    def set_total(self, count: int):
        self.total_count = count
        self._last_visible_range = (-1, -1)
        self.update()

    def set_columns(self, columns: int):
        if columns != self.columns:
            self.columns = columns
            self._last_visible_range = (-1, -1)
            self.update()

    def set_cell(self, cell: int):
        if cell != self.cell:
            self.cell = cell
            self._last_visible_range = (-1, -1)
            self.update()

    def set_thumbnail(self, index: int, pixmap: QPixmap):
        self.thumbnails[index] = pixmap
        self._schedule_update()

    def set_current(self, index: int):
        self.current_index = index
        self.update()  # Immediate for navigation

    def set_rating(self, index: int, rating: int):
        self.ratings[index] = rating
        self._schedule_update()

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.fillRect(event.rect(), QColor(20, 20, 20))
        if self.total_count == 0:
            painter.end()
            return
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        painter.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform)
        cell = self.cell
        rect = event.rect()
        first, last = visible_index_range(rect.top(), rect.bottom(),
                                          self.columns, self.total_count, cell)
        for idx in range(first, last + 1):
            x, y = cell_origin(idx, self.columns, cell)

            thumb = self.thumbnails.get(idx) or self.fallback_thumbs.get(idx)
            if thumb is not None and thumb.width() > 0 and thumb.height() > 0:
                if idx not in self.thumbnails:
                    painter.fillRect(x, y, cell, cell, QColor(40, 40, 40))
                scale = min(cell / thumb.width(), cell / thumb.height())
                tw = int(thumb.width() * scale)
                th = int(thumb.height() * scale)
                target = QRect(x + (cell - tw) // 2, y + (cell - th) // 2, tw, th)
                painter.drawPixmap(target, thumb)
            else:
                painter.fillRect(x, y, cell, cell, QColor(40, 40, 40))

            if idx == self.current_index:
                painter.setPen(QPen(QColor(255, 255, 255), 3))
                painter.setBrush(Qt.BrushStyle.NoBrush)
                painter.drawRect(x - 2, y - 2, cell + 4, cell + 4)

            rating = self.ratings.get(idx, 0)
            if rating > 0:
                painter.setPen(Qt.PenStyle.NoPen)
                painter.setBrush(QColor(255, 200, 50))
                dot_start_x = x + (cell - rating * 10) // 2
                for r in range(rating):
                    painter.drawEllipse(dot_start_x + r * 10, y + cell - 14, 6, 6)
            elif rating == -1:
                painter.setPen(QPen(QColor(230, 70, 70), 2))
                font = painter.font()
                font.setPixelSize(16)
                font.setBold(True)
                painter.setFont(font)
                painter.drawText(x, y + cell - 26, cell, 20,
                                 Qt.AlignmentFlag.AlignCenter, "✕")
        painter.end()

    def mousePressEvent(self, event):
        idx = index_at(event.position().x(), event.position().y(),
                       self.columns, self.total_count, self.cell)
        if idx >= 0:
            self.clicked.emit(idx)

    def mouseDoubleClickEvent(self, event):
        idx = index_at(event.position().x(), event.position().y(),
                       self.columns, self.total_count, self.cell)
        if idx >= 0:
            self.activated.emit(idx)

    def dragEnterEvent(self, event):
        """Forward to main window."""
        self.window().dragEnterEvent(event)

    def dragMoveEvent(self, event):
        """Forward to main window."""
        self.window().dragEnterEvent(event)

    def dropEvent(self, event):
        """Forward to main window."""
        self.window().dropEvent(event)


class GridWidget(QScrollArea):
    """Vertical scrollable grid of thumbnails."""

    clicked = pyqtSignal(int)
    activated = pyqtSignal(int)
    visible_range_changed = pyqtSignal(int, int)

    def __init__(self, parent=None):
        super().__init__(parent)
        self.content = GridContent()
        self.content.clicked.connect(self.clicked.emit)
        self.content.activated.connect(self.activated.emit)
        self.content.visible_range_changed.connect(self.visible_range_changed.emit)

        self.setWidget(self.content)
        self.setWidgetResizable(False)
        self.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self.setVerticalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAsNeeded)
        self.setFocusPolicy(Qt.FocusPolicy.NoFocus)
        self.content.setFocusPolicy(Qt.FocusPolicy.NoFocus)
        self.setAcceptDrops(True)
        self.setStyleSheet("""
            QScrollArea { background-color: rgb(20, 20, 20); border: none; }
            QScrollBar:vertical { width: 6px; background: #222; }
            QScrollBar::handle:vertical { background: #666; border-radius: 3px; min-height: 30px; }
            QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical { height: 0; }
        """)

        # Debounced scroll -> visible range emission (same pattern as FilmstripWidget)
        self._scroll_timer = QTimer()
        self._scroll_timer.setSingleShot(True)
        self._scroll_timer.timeout.connect(self._emit_visible_range)
        self.verticalScrollBar().valueChanged.connect(lambda: self._scroll_timer.start(50))

    def _emit_visible_range(self):
        rect = self.viewport().rect()
        rect.moveTop(self.verticalScrollBar().value())
        self.content.update_visible_range(rect)

    def _relayout(self):
        w = max(1, self.viewport().width())
        columns = columns_for_width(w)
        cell = cell_size_for_width(w, columns)
        self.content.set_columns(columns)
        self.content.set_cell(cell)
        h = content_height(self.content.total_count, columns, cell)
        self.content.setFixedSize(max(w, cell + 2 * SPACING), max(h, 1))
        self._scroll_timer.start(50)

    def showEvent(self, event):
        super().showEvent(event)
        self._relayout()
        QTimer.singleShot(0, self._emit_visible_range)

    def resizeEvent(self, event):
        super().resizeEvent(event)
        self._relayout()

    @property
    def thumbnails(self):
        return self.content.thumbnails

    @property
    def columns(self):
        return self.content.columns

    def set_total(self, count: int):
        self.content.set_total(count)
        self._relayout()

    def set_thumbnail(self, index: int, pixmap: QPixmap):
        self.content.set_thumbnail(index, pixmap)

    def set_current(self, index: int):
        self.content.set_current(index)
        if index >= 0 and self.content.columns > 0:
            cell = self.content.cell
            x, y = cell_origin(index, self.content.columns, cell)
            self.ensureVisible(x + cell // 2, y + cell // 2, cell // 2, cell // 2 + SPACING)

    def set_rating(self, index: int, rating: int):
        self.content.set_rating(index, rating)

    def set_fallback_thumbs(self, thumbs: Dict[int, QPixmap]):
        self.content.fallback_thumbs = thumbs

    def clear_thumbnails(self):
        self.content.thumbnails.clear()
        self.content.ratings.clear()
        self.content._last_visible_range = (-1, -1)

    def dragEnterEvent(self, event):
        """Forward to main window."""
        self.window().dragEnterEvent(event)

    def dragMoveEvent(self, event):
        """Forward to main window."""
        self.window().dragEnterEvent(event)

    def dropEvent(self, event):
        """Forward to main window."""
        self.window().dropEvent(event)
