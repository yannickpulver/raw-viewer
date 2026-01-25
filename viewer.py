"""Fullscreen RAW image viewer with rating support and filmstrip."""

from pathlib import Path
from typing import List, Dict, Optional
from concurrent.futures import ThreadPoolExecutor
import threading
import subprocess
import platform
import urllib.request
import json

from version import VERSION

from PyQt6.QtWidgets import QMainWindow, QLabel, QWidget, QVBoxLayout, QHBoxLayout, QScrollArea, QGraphicsView, QGraphicsScene, QGraphicsPixmapItem, QPushButton, QFileDialog
from PyQt6.QtGui import QPixmap, QKeyEvent, QPainter, QFont, QColor, QPen, QWheelEvent, QMouseEvent, QNativeGestureEvent
from PyQt6.QtCore import Qt, pyqtSignal, QObject, QSize, QPointF, QEvent, QTimer

from preview import extract_preview, extract_thumbnail, extract_thumbnail_bytes
from rating import read_rating, write_rating
from scanner import scan_folder, get_creation_time
from datetime import datetime
from thumbnail_cache import ThumbnailCache
from recent_folders import load_recent_folders, add_recent_folder


class PreloadSignals(QObject):
    """Signals for background preloading."""
    loaded = pyqtSignal(int, QPixmap)
    thumb_loaded = pyqtSignal(int, QPixmap)
    update_available = pyqtSignal(str, str)  # latest_version, download_url
    folder_scanned = pyqtSignal(list, Path)  # files, folder
    scan_progress = pyqtSignal(int, int)  # current, total


class ZoomableImageView(QGraphicsView):
    """Image view with pinch-to-zoom and pan support."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self.scene = QGraphicsScene(self)
        self.setScene(self.scene)

        self.pixmap_item = QGraphicsPixmapItem()
        self.scene.addItem(self.pixmap_item)

        # Zoom state
        self.zoom_factor = 1.0
        self.base_zoom = 1.0  # Store the fit-to-view zoom level
        self.min_zoom = 0.1
        self.max_zoom = 10.0

        # Pan state
        self.panning = False
        self.last_pan_point = QPointF()

        # Setup
        self.setStyleSheet("background-color: black; border: none;")
        self.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self.setVerticalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self.setDragMode(QGraphicsView.DragMode.NoDrag)
        self.setTransformationAnchor(QGraphicsView.ViewportAnchor.AnchorUnderMouse)
        self.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform)

        # Enable native gestures
        self.grabGesture(Qt.GestureType.PinchGesture)
        self.setAttribute(Qt.WidgetAttribute.WA_AcceptTouchEvents)
        self.setAcceptDrops(True)

    def dragEnterEvent(self, event):
        """Forward to main window."""
        self.window().dragEnterEvent(event)

    def dragMoveEvent(self, event):
        """Forward to main window."""
        self.window().dragEnterEvent(event)

    def dropEvent(self, event):
        """Forward to main window."""
        self.window().dropEvent(event)

    def set_pixmap(self, pixmap: QPixmap):
        """Set the image to display."""
        self.pixmap_item.setPixmap(pixmap)
        if not pixmap.isNull():
            self.scene.setSceneRect(pixmap.rect().toRectF())
            self.reset_zoom()

    def reset_zoom(self):
        """Fit image to view."""
        self.resetTransform()
        if not self.pixmap_item.pixmap().isNull():
            self.fitInView(self.pixmap_item, Qt.AspectRatioMode.KeepAspectRatio)
            self.base_zoom = self.transform().m11()
            self.zoom_factor = 1.0

    def _apply_zoom(self, factor: float, center: QPointF = None):
        """Apply zoom factor around a point."""
        new_zoom = self.zoom_factor * factor
        if self.min_zoom <= new_zoom <= self.max_zoom:
            self.zoom_factor = new_zoom
            if center:
                self.setTransformationAnchor(QGraphicsView.ViewportAnchor.NoAnchor)
                old_pos = self.mapToScene(center.toPoint())
                self.scale(factor, factor)
                new_pos = self.mapToScene(center.toPoint())
                delta = new_pos - old_pos
                self.translate(delta.x(), delta.y())
                self.setTransformationAnchor(QGraphicsView.ViewportAnchor.AnchorUnderMouse)
            else:
                self.scale(factor, factor)

    def event(self, event: QEvent) -> bool:
        """Handle native gesture events for pinch zoom."""
        if event.type() == QEvent.Type.NativeGesture:
            gesture = event
            if gesture.gestureType() == Qt.NativeGestureType.ZoomNativeGesture:
                # Pinch zoom - value is the scale delta
                factor = 1.0 + gesture.value()
                self._apply_zoom(factor, gesture.position())
                return True
        return super().event(event)

    def wheelEvent(self, event: QWheelEvent):
        """Handle scroll for panning or navigation."""
        dx = event.pixelDelta().x()
        dy = event.pixelDelta().y()

        # When not zoomed, horizontal scroll navigates images
        if abs(self.zoom_factor - 1.0) < 0.01:
            if abs(dx) > 30:  # Horizontal swipe threshold
                self.parent().window()._on_scroll_navigate(-1 if dx > 0 else 1)
            event.accept()
            return

        # When zoomed, pan
        if dx != 0 or dy != 0:
            self.horizontalScrollBar().setValue(self.horizontalScrollBar().value() - dx)
            self.verticalScrollBar().setValue(self.verticalScrollBar().value() - dy)
        event.accept()

    def mousePressEvent(self, event: QMouseEvent):
        """Start panning on mouse press."""
        if event.button() == Qt.MouseButton.LeftButton:
            self.panning = True
            self.last_pan_point = event.position()
            self.setCursor(Qt.CursorShape.ClosedHandCursor)
        super().mousePressEvent(event)

    def mouseMoveEvent(self, event: QMouseEvent):
        """Pan while dragging."""
        if self.panning:
            delta = event.position() - self.last_pan_point
            self.last_pan_point = event.position()
            self.horizontalScrollBar().setValue(int(self.horizontalScrollBar().value() - delta.x()))
            self.verticalScrollBar().setValue(int(self.verticalScrollBar().value() - delta.y()))
        super().mouseMoveEvent(event)

    def mouseReleaseEvent(self, event: QMouseEvent):
        """Stop panning."""
        if event.button() == Qt.MouseButton.LeftButton:
            self.panning = False
            self.setCursor(Qt.CursorShape.ArrowCursor)
        super().mouseReleaseEvent(event)

    def mouseDoubleClickEvent(self, event: QMouseEvent):
        """Double-click to reset zoom."""
        self.reset_zoom()
        super().mouseDoubleClickEvent(event)

    def resizeEvent(self, event):
        """Re-fit image on resize if at default zoom."""
        super().resizeEvent(event)
        if abs(self.zoom_factor - 1.0) < 0.01:
            self.reset_zoom()

    def keyPressEvent(self, event: QKeyEvent):
        """Forward key events to parent window."""
        self.parent().window().keyPressEvent(event)


class FilmstripContent(QWidget):
    """Inner content widget for filmstrip thumbnails."""
    THUMB_SIZE = 80
    SPACING = 4

    clicked = pyqtSignal(int)
    visible_range_changed = pyqtSignal(int, int)  # first, last visible index

    def __init__(self, parent=None):
        super().__init__(parent)
        self.thumbnails: Dict[int, QPixmap] = {}
        self.current_index = 0
        self.total_count = 0
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
        """Calculate and emit visible range based on viewport."""
        if self.total_count == 0:
            return
        item_width = self.THUMB_SIZE + self.SPACING
        first = max(0, viewport_rect.left() // item_width)
        last = min(self.total_count - 1, viewport_rect.right() // item_width + 1)
        new_range = (first, last)
        if new_range != self._last_visible_range:
            self._last_visible_range = new_range
            self.visible_range_changed.emit(first, last)

    def set_total(self, count: int):
        self.total_count = count
        self._update_size()

    def _update_size(self):
        width = self.total_count * (self.THUMB_SIZE + self.SPACING)
        self.setFixedSize(width, self.THUMB_SIZE + 20)

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
        if self.total_count == 0:
            return

        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)

        # Only paint visible region
        rect = event.rect()
        item_width = self.THUMB_SIZE + self.SPACING
        first_visible = max(0, rect.left() // item_width)
        last_visible = min(self.total_count - 1, rect.right() // item_width + 1)

        # Fill only visible background
        painter.fillRect(rect, QColor(20, 20, 20))

        for idx in range(first_visible, last_visible + 1):
            x = idx * item_width
            y = 4  # Padding for selection border

            # Draw thumbnail or placeholder
            if idx in self.thumbnails:
                thumb = self.thumbnails[idx]
                tx = x + (self.THUMB_SIZE - thumb.width()) // 2
                ty = y + (self.THUMB_SIZE - thumb.height()) // 2
                painter.drawPixmap(tx, ty, thumb)
            else:
                painter.fillRect(x, y, self.THUMB_SIZE, self.THUMB_SIZE, QColor(40, 40, 40))

            # Highlight current with border only
            if idx == self.current_index:
                painter.setPen(QPen(QColor(255, 255, 255), 3))
                painter.setBrush(Qt.BrushStyle.NoBrush)
                painter.drawRect(x - 2, y - 2, self.THUMB_SIZE + 4, self.THUMB_SIZE + 4)

            # Draw rating dots
            rating = self.ratings.get(idx, 0)
            if rating > 0:
                painter.setPen(Qt.PenStyle.NoPen)
                painter.setBrush(QColor(255, 200, 50))
                dot_y = y + self.THUMB_SIZE + 5
                dot_start_x = x + (self.THUMB_SIZE - rating * 8) // 2
                for r in range(rating):
                    painter.drawEllipse(dot_start_x + r * 8, dot_y, 5, 5)

        painter.end()

    def mousePressEvent(self, event):
        if self.total_count == 0:
            return
        click_x = event.position().x()
        idx = int(click_x // (self.THUMB_SIZE + self.SPACING))
        if 0 <= idx < self.total_count:
            self.clicked.emit(idx)

    def dragEnterEvent(self, event):
        """Forward to main window."""
        self.window().dragEnterEvent(event)

    def dragMoveEvent(self, event):
        """Forward to main window."""
        self.window().dragEnterEvent(event)

    def dropEvent(self, event):
        """Forward to main window."""
        self.window().dropEvent(event)


class FilmstripWidget(QScrollArea):
    """Horizontal scrollable filmstrip."""
    clicked = pyqtSignal(int)
    visible_range_changed = pyqtSignal(int, int)
    THUMB_SIZE = FilmstripContent.THUMB_SIZE

    def __init__(self, parent=None):
        super().__init__(parent)
        self.content = FilmstripContent()
        self.content.clicked.connect(self.clicked.emit)
        self.content.visible_range_changed.connect(self.visible_range_changed.emit)

        self.setWidget(self.content)
        self.setWidgetResizable(False)
        self.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOn)
        self.setVerticalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self.setFixedHeight(FilmstripContent.THUMB_SIZE + 44)
        self.setFocusPolicy(Qt.FocusPolicy.NoFocus)
        self.content.setFocusPolicy(Qt.FocusPolicy.NoFocus)
        self.setAcceptDrops(True)
        self.content.setAcceptDrops(True)
        self.setStyleSheet("""
            QScrollArea { background-color: rgba(0, 0, 0, 200); border: none; }
            QScrollBar:horizontal { height: 6px; background: #222; }
            QScrollBar::handle:horizontal { background: #666; border-radius: 3px; min-width: 30px; }
            QScrollBar::add-line:horizontal, QScrollBar::sub-line:horizontal { width: 0; }
        """)

        # Track scroll to update visible range (debounced)
        self._scroll_timer = QTimer()
        self._scroll_timer.setSingleShot(True)
        self._scroll_timer.timeout.connect(self._on_scroll_stopped)
        self.horizontalScrollBar().valueChanged.connect(self._on_scroll)

    def _on_scroll(self):
        """Debounce scroll - only load after scrolling stops."""
        self._scroll_timer.start(50)  # Wait 50ms after last scroll (disk cache makes this safe)

    def _on_scroll_stopped(self):
        """Scrolling stopped - now load visible thumbnails."""
        viewport_rect = self.viewport().rect()
        viewport_rect.moveLeft(self.horizontalScrollBar().value())
        self.content.update_visible_range(viewport_rect)

    def showEvent(self, event):
        super().showEvent(event)
        # Initial visible range update
        QTimer.singleShot(0, self._on_scroll_stopped)

    def wheelEvent(self, event: QWheelEvent):
        """Handle scroll - use horizontal, or convert vertical to horizontal."""
        # Prefer pixelDelta for smooth trackpad scrolling
        px = event.pixelDelta()
        if not px.isNull():
            # Use horizontal scroll directly, ignore vertical
            delta = px.x()
        else:
            # Mouse wheel: convert vertical to horizontal
            delta = event.angleDelta().y()

        if delta != 0:
            self.horizontalScrollBar().setValue(
                self.horizontalScrollBar().value() - delta
            )
        event.accept()

    @property
    def thumbnails(self):
        return self.content.thumbnails

    def set_total(self, count: int):
        self.content.set_total(count)

    def set_thumbnail(self, index: int, pixmap: QPixmap):
        self.content.set_thumbnail(index, pixmap)

    def set_current(self, index: int):
        self.content.set_current(index)
        # Scroll to make current visible
        x = index * (FilmstripContent.THUMB_SIZE + FilmstripContent.SPACING)
        self.ensureVisible(x, 0, self.width() // 2, 0)

    def set_rating(self, index: int, rating: int):
        self.content.set_rating(index, rating)

    def dragEnterEvent(self, event):
        """Forward to main window."""
        self.window().dragEnterEvent(event)

    def dragMoveEvent(self, event):
        """Forward to main window."""
        self.window().dragEnterEvent(event)

    def dropEvent(self, event):
        """Forward to main window."""
        self.window().dropEvent(event)


class ImageViewer(QMainWindow):
    CACHE_SIZE = 7

    def __init__(self, files: Optional[List[Path]] = None):
        super().__init__()
        self.files = files or []
        self.all_files = self.files  # Keep original list
        self.index = 0
        self.cache: Dict[int, QPixmap] = {}
        self.ratings: Dict[int, int] = {}  # Maps original index to rating
        self.show_info = True
        self.filmstrip_visible = True
        self.min_rating_filter = 0  # 0 = show all

        # Preloading - separate executors for previews and thumbnails
        self.preload_signals = PreloadSignals()
        self.preload_signals.loaded.connect(self._on_preloaded)
        self.preload_signals.thumb_loaded.connect(self._on_thumb_loaded)
        self.preload_signals.update_available.connect(self._on_update_available)
        self.preload_signals.folder_scanned.connect(self._on_folder_scanned)
        self.preload_signals.scan_progress.connect(self._on_scan_progress)
        self.executor = ThreadPoolExecutor(max_workers=4)  # Main previews
        self.thumb_executor = ThreadPoolExecutor(max_workers=4)  # Thumbnails
        self.loading: set = set()
        self.thumb_loading: set = set()
        self.lock = threading.Lock()

        # Persistent thumbnail cache
        self.thumb_cache = ThumbnailCache()

        # Throttled progress update
        self._progress_timer = QTimer()
        self._progress_timer.timeout.connect(self._update_loading_progress)
        self._progress_timer.start(200)  # Update every 200ms

        # Main layout
        central = QWidget()
        layout = QVBoxLayout(central)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)

        # Image display
        self.image_view = ZoomableImageView()
        layout.addWidget(self.image_view, 1)

        # Filmstrip
        self.filmstrip = FilmstripWidget()
        self.filmstrip.set_total(len(self.files))
        self.filmstrip.clicked.connect(self._on_filmstrip_click)
        self.filmstrip.visible_range_changed.connect(self._on_visible_range_changed)
        layout.addWidget(self.filmstrip)

        self.setCentralWidget(central)

        # Info overlay (on top of everything) - all on the right
        self.info_label = QLabel(self)
        self.info_label.setStyleSheet("""
            QLabel {
                background-color: transparent;
                color: white;
                padding: 6px 12px;
                font-family: Menlo, Monaco, monospace;
                font-size: 12px;
            }
        """)

        self.pos_label = QLabel(self)
        self.pos_label.setStyleSheet("""
            QLabel {
                background-color: transparent;
                color: white;
                padding: 6px 12px;
                font-family: Menlo, Monaco, monospace;
                font-size: 14px;
            }
        """)

        # Loading progress label
        self.loading_label = QLabel(self)
        self.loading_label.setStyleSheet("""
            QLabel {
                background-color: rgba(0, 0, 0, 150);
                color: #aaa;
                padding: 4px 10px;
                font-family: Menlo, Monaco, monospace;
                font-size: 11px;
            }
        """)

        # Filter label
        self.filter_label = QLabel(self)
        self.filter_label.setStyleSheet("""
            QLabel {
                background-color: rgba(255, 180, 0, 200);
                color: black;
                padding: 4px 10px;
                font-family: Menlo, Monaco, monospace;
                font-size: 12px;
                font-weight: bold;
            }
        """)
        self.filter_label.setVisible(False)

        # Update available label
        self.update_label = QLabel(self)
        self.update_label.setStyleSheet("""
            QLabel {
                background-color: rgba(80, 180, 80, 220);
                color: white;
                padding: 4px 10px;
                font-family: Menlo, Monaco, monospace;
                font-size: 11px;
            }
        """)
        self.update_label.setVisible(False)
        self.update_label.setCursor(Qt.CursorShape.PointingHandCursor)
        self.update_url = None

        # Help overlay
        help_text = """
  Keyboard Shortcuts

  ←/→         Navigate images
  0-5          Rate current image
  ⌘0-5        Filter by rating

  S            Go to start
  E            Go to end
  R            Go to last rated

  I            Toggle info overlay
  ⌘S          Toggle filmstrip
  H            Toggle this help

  O            Show in Finder
  ⌘L          Open all in Lightroom
  Esc          Close folder
  ⌘Q          Quit
"""
        self.help_label = QLabel(help_text.strip(), self)
        self.help_label.setStyleSheet("""
            QLabel {
                background-color: rgba(0, 0, 0, 200);
                color: #ddd;
                padding: 20px 30px;
                font-family: Menlo, Monaco, monospace;
                font-size: 13px;
                line-height: 1.6;
            }
        """)
        self.help_label.adjustSize()
        self.help_label.setVisible(False)

        # Title label (centered in title bar)
        self.title_label = QLabel("RAW Viewer", self)
        self.title_label.setStyleSheet("""
            QLabel {
                background-color: transparent;
                color: rgba(255, 255, 255, 120);
                padding: 0px 12px;
                font-family: 'SF Pro Text', 'Helvetica Neue', sans-serif;
                font-size: 13px;
                font-weight: 500;
            }
        """)
        self.title_label.adjustSize()

        # Drag state
        self._drag_pos = None

        # Filter buttons container
        self.filter_buttons_widget = QWidget(self)
        self.filter_buttons_widget.setStyleSheet("background: transparent;")
        filter_layout = QHBoxLayout(self.filter_buttons_widget)
        filter_layout.setContentsMargins(0, 0, 0, 0)
        filter_layout.setSpacing(4)

        self.filter_buttons = []
        button_style = """
            QPushButton {
                background-color: rgba(60, 60, 60, 200);
                color: #ccc;
                border: 1px solid #555;
                padding: 2px 4px;
                font-family: Menlo, Monaco, monospace;
                font-size: 10px;
                min-width: 14px;
            }
            QPushButton:hover {
                background-color: rgba(80, 80, 80, 220);
            }
            QPushButton:checked {
                background-color: rgba(255, 180, 0, 200);
                color: black;
                border: 1px solid #ffb400;
            }
        """
        # Open folder button (in toolbar)
        self.open_btn_small = QPushButton("📂")
        self.open_btn_small.setStyleSheet(button_style)
        self.open_btn_small.clicked.connect(self._open_folder)
        filter_layout.addWidget(self.open_btn_small)

        # Spacer
        filter_layout.addSpacing(10)

        # Filter buttons
        labels = ["All", "1+", "2+", "3+", "4+", "5"]
        for i, label in enumerate(labels):
            btn = QPushButton(label)
            btn.setCheckable(True)
            btn.setStyleSheet(button_style)
            btn.clicked.connect(lambda checked, idx=i: self._on_filter_button(idx))
            filter_layout.addWidget(btn)
            self.filter_buttons.append(btn)

        self.filter_buttons[0].setChecked(True)
        self.filter_buttons_widget.adjustSize()

        # Centered open button (shown when no files)
        self.open_btn_center = QPushButton("📂 Open Folder", self)
        self.open_btn_center.setStyleSheet("""
            QPushButton {
                background-color: rgba(60, 60, 60, 220);
                color: white;
                border: 1px solid #666;
                padding: 15px 30px;
                font-family: Menlo, Monaco, monospace;
                font-size: 16px;
            }
            QPushButton:hover {
                background-color: rgba(80, 80, 80, 240);
            }
        """)
        self.open_btn_center.clicked.connect(self._open_folder)
        self.open_btn_center.adjustSize()

        # Scanning indicator (shown while loading folder)
        self.scanning_label = QLabel("Scanning folder...", self)
        self.scanning_label.setStyleSheet("""
            QLabel {
                background-color: rgba(40, 40, 40, 220);
                color: #aaa;
                padding: 15px 30px;
                font-family: Menlo, Monaco, monospace;
                font-size: 14px;
            }
        """)
        self.scanning_label.adjustSize()
        self.scanning_label.setVisible(False)

        # Recent folders container
        self.recent_container = QWidget(self)
        self.recent_layout = QVBoxLayout(self.recent_container)
        self.recent_layout.setContentsMargins(0, 10, 0, 0)
        self.recent_layout.setSpacing(5)
        self.recent_buttons: List[QPushButton] = []
        self._update_recent_folders_ui()

        # Window setup
        self.setWindowTitle("RAW Viewer")
        self.setStyleSheet("background-color: black;")
        self.resize(1400, 900)
        self._titlebar_configured = False
        self.setAcceptDrops(True)

        # Update UI state
        self._update_empty_state()

        # Check for updates in background
        threading.Thread(target=self._check_for_updates, daemon=True).start()

        # Load initial
        if self.files:
            self._load_current()
            self._preload_nearby()
            self._preload_all_thumbnails()

    def _on_filmstrip_click(self, index: int):
        """Navigate to clicked thumbnail."""
        if 0 <= index < len(self.files):
            self.index = index
            self._load_current()
            self._preload_nearby()
            self._preload_all_thumbnails()  # Restart from new position

    def _on_preloaded(self, idx: int, pixmap: QPixmap):
        with self.lock:
            if idx not in self.cache:
                self.cache[idx] = pixmap
            self.loading.discard(idx)
        if idx == self.index and pixmap:
            self._display(pixmap)
        # Also create thumbnail
        if pixmap and idx not in self.filmstrip.thumbnails:
            thumb = pixmap.scaled(80, 80, Qt.AspectRatioMode.KeepAspectRatio, Qt.TransformationMode.FastTransformation)
            self.filmstrip.set_thumbnail(idx, thumb)

    def _on_thumb_loaded(self, idx: int, pixmap: QPixmap):
        self.filmstrip.set_thumbnail(idx, pixmap)
        # Update rating in filmstrip
        orig_idx = self.all_files.index(self.files[idx])
        rating = self.ratings.get(orig_idx, 0)
        self.filmstrip.set_rating(idx, rating)

    def _load_sync(self, idx: int) -> Optional[QPixmap]:
        if 0 <= idx < len(self.files):
            return extract_preview(self.files[idx])
        return None

    def _load_thumb_sync(self, idx: int) -> Optional[QPixmap]:
        if 0 <= idx < len(self.files):
            return extract_thumbnail(self.files[idx], FilmstripWidget.THUMB_SIZE)
        return None

    def _preload_one(self, idx: int):
        pixmap = self._load_sync(idx)
        if pixmap:
            self.preload_signals.loaded.emit(idx, pixmap)

    def _preload_thumb(self, idx: int):
        try:
            # Load rating too
            orig_idx = self.all_files.index(self.files[idx])
            if orig_idx not in self.ratings:
                rating = read_rating(self.files[idx])
                self.ratings[orig_idx] = rating if rating is not None else 0

            path = self.files[idx]
            size = 80

            # Check disk cache first
            cached_bytes = self.thumb_cache.get(path, size)
            if cached_bytes:
                pixmap = QPixmap()
                pixmap.loadFromData(cached_bytes)
                if not pixmap.isNull():
                    self.preload_signals.thumb_loaded.emit(idx, pixmap)
                    return

            # Generate and cache
            thumb_bytes = extract_thumbnail_bytes(path, size)
            if thumb_bytes:
                self.thumb_cache.set(path, size, thumb_bytes)
                pixmap = QPixmap()
                pixmap.loadFromData(thumb_bytes)
                if not pixmap.isNull():
                    self.preload_signals.thumb_loaded.emit(idx, pixmap)
        except Exception:
            pass  # Failed to load this thumbnail
        finally:
            # Always remove from loading set to prevent stuck entries
            with self.lock:
                self.thumb_loading.discard(idx)

    def _preload_nearby(self):
        for offset in [1, -1, 2, -2, 3, -3]:
            idx = self.index + offset
            with self.lock:
                if 0 <= idx < len(self.files) and idx not in self.cache and idx not in self.loading:
                    self.loading.add(idx)
                    self.executor.submit(self._preload_one, idx)
        self._trim_cache()

    def _preload_thumbnails(self):
        """Preload thumbnails around current index (for navigation)."""
        self._load_thumbnails_range(self.index - 10, self.index + 10)

    def _on_visible_range_changed(self, first: int, last: int):
        """Load thumbnails for visible range + buffer."""
        buffer = 5  # Load a few extra on each side
        self._load_thumbnails_range(first - buffer, last + buffer)

    def _load_thumbnails_range(self, start: int, end: int):
        """Load thumbnails in a specific range."""
        start = max(0, start)
        end = min(len(self.files) - 1, end)
        for idx in range(start, end + 1):
            with self.lock:
                if idx not in self.filmstrip.thumbnails and idx not in self.thumb_loading:
                    self.thumb_loading.add(idx)
                    self.thumb_executor.submit(self._preload_thumb, idx)

    def _preload_all_thumbnails(self):
        """Progressively load all thumbnails in background, starting from current index."""
        # Start background preload timer
        if not hasattr(self, '_bg_preload_timer'):
            self._bg_preload_timer = QTimer()
            self._bg_preload_timer.timeout.connect(self._background_preload_batch)

        # Start from current selection, track where we started
        self._bg_preload_idx = self.index
        self._bg_preload_start = self.index
        self._bg_preload_wrapped = False
        self._bg_preload_timer.start(100)  # Process batch every 100ms

    def _background_preload_batch(self):
        """Load a batch of thumbnails in background (low priority)."""
        if not self.files:
            self._bg_preload_timer.stop()
            return

        batch_size = 5  # Load 5 at a time
        loaded = 0
        total = len(self.files)

        while loaded < batch_size:
            idx = self._bg_preload_idx

            # Check if we've completed full cycle
            if self._bg_preload_wrapped and idx >= self._bg_preload_start:
                self._bg_preload_timer.stop()
                return

            # Wrap around at end
            if idx >= total:
                self._bg_preload_idx = 0
                self._bg_preload_wrapped = True
                continue

            self._bg_preload_idx += 1

            # Skip if already loaded or loading
            with self.lock:
                if idx in self.filmstrip.thumbnails or idx in self.thumb_loading:
                    continue
                self.thumb_loading.add(idx)

            self.thumb_executor.submit(self._preload_thumb, idx)
            loaded += 1

    def _trim_cache(self):
        with self.lock:
            to_remove = [k for k in self.cache.keys() if abs(k - self.index) > self.CACHE_SIZE // 2]
            for k in to_remove:
                del self.cache[k]

    def _load_current(self):
        if not self.files:
            return

        with self.lock:
            pixmap = self.cache.get(self.index)

        if pixmap:
            self._display(pixmap)
        else:
            pixmap = self._load_sync(self.index)
            if pixmap:
                with self.lock:
                    self.cache[self.index] = pixmap
                self._display(pixmap)
                # Generate thumbnail too
                if self.index not in self.filmstrip.thumbnails:
                    thumb = pixmap.scaled(80, 80, Qt.AspectRatioMode.KeepAspectRatio, Qt.TransformationMode.FastTransformation)
                    self.filmstrip.set_thumbnail(self.index, thumb)

        # Load rating (use original index)
        orig_idx = self.all_files.index(self.files[self.index])
        if orig_idx not in self.ratings:
            rating = read_rating(self.files[self.index])
            self.ratings[orig_idx] = rating if rating is not None else 0

        # Update filmstrip and overlay
        self.filmstrip.set_current(self.index)
        self.filmstrip.set_rating(self.index, self.ratings[orig_idx])
        self._update_overlay()

    def _display(self, pixmap: QPixmap):
        if pixmap.isNull():
            return
        self.image_view.set_pixmap(pixmap)
        self.update()

    def _update_overlay(self):
        """Update the info overlay labels."""
        if not self.files:
            self.pos_label.setText("No images")
            self.pos_label.adjustSize()
            self.pos_label.move(self.width() - self.pos_label.width() - 10, 10)
            self.info_label.setVisible(False)
            return

        # Top right: position counter + filter info
        position = f"{self.index + 1}/{len(self.files)}"
        if self.min_rating_filter > 0:
            position += f"  (≥{self.min_rating_filter}★)"
        self.pos_label.setText(position)
        self.pos_label.adjustSize()
        self.pos_label.move(self.width() - self.pos_label.width() - 10, 10)
        self.pos_label.setVisible(self.show_info)

        # Below position: filename, date, and rating
        current_file = self.files[self.index]
        filename = current_file.name
        creation_time = get_creation_time(current_file)
        date_str = datetime.fromtimestamp(creation_time).strftime("%Y-%m-%d %H:%M")
        orig_idx = self.all_files.index(current_file)
        rating = self.ratings.get(orig_idx, 0)
        stars = "★" * rating + "☆" * (5 - rating) if rating else "☆☆☆☆☆"
        self.info_label.setText(f"{filename}  |  {date_str}  |  {stars}")
        self.info_label.adjustSize()
        self.info_label.move(self.width() - self.info_label.width() - 10, 10 + self.pos_label.height())
        self.info_label.setVisible(self.show_info)

        # Filter label (shown when filter active)
        if self.min_rating_filter > 0:
            total_filtered = len(self.files)
            total_all = len(self.all_files)
            self.filter_label.setText(f"Filter: ≥{self.min_rating_filter}★  ({total_filtered}/{total_all})")
            self.filter_label.adjustSize()
            self.filter_label.move(10, 10)
            self.filter_label.setVisible(True)
        else:
            self.filter_label.setVisible(False)

        # Update loading progress position
        self._update_loading_progress()

    def _update_loading_progress(self):
        """Update the loading progress indicator."""
        if not self.files:
            self.loading_label.setVisible(False)
            return

        loaded = len(self.filmstrip.thumbnails)
        total = len(self.files)
        percent = int(loaded / total * 100) if total > 0 else 0

        if percent >= 100:
            self.loading_label.setVisible(False)
        else:
            self.loading_label.setText(f"Loading: {percent}%")
            self.loading_label.adjustSize()
            # Position below info label on the right
            y_pos = 10 + self.pos_label.height() + self.info_label.height()
            self.loading_label.move(self.width() - self.loading_label.width() - 10, y_pos)
            self.loading_label.setVisible(True)

    def _load_all_ratings(self):
        """Load ratings for all files."""
        for i, f in enumerate(self.all_files):
            if i not in self.ratings:
                rating = read_rating(f)
                self.ratings[i] = rating if rating is not None else 0

    def _apply_filter(self, min_rating: int):
        """Apply rating filter."""
        # Stop background preload
        if hasattr(self, '_bg_preload_timer'):
            self._bg_preload_timer.stop()

        # Remember currently selected file
        current_file = self.files[self.index] if self.files and 0 <= self.index < len(self.files) else None

        self.min_rating_filter = min_rating

        if min_rating == 0:
            self.files = self.all_files
        else:
            # Load all ratings first
            self._load_all_ratings()
            # Filter files
            self.files = [f for i, f in enumerate(self.all_files) if self.ratings.get(i, 0) >= min_rating]

        # Update filmstrip
        self.filmstrip.set_total(len(self.files))
        self.filmstrip.thumbnails.clear()
        self.thumb_loading.clear()

        # Preserve selection if still in filtered list, otherwise reset to 0
        if self.files:
            if current_file and current_file in self.files:
                self.index = self.files.index(current_file)
            else:
                self.index = 0
            self._load_current()
            self._preload_nearby()
            self._preload_all_thumbnails()
        else:
            self.image_view.set_pixmap(QPixmap())

        self._update_overlay()
        self._update_filter_buttons()

    def _on_filter_button(self, idx: int):
        """Handle filter button click."""
        self._apply_filter(idx)

    def _update_filter_buttons(self):
        """Update filter button states."""
        for i, btn in enumerate(self.filter_buttons):
            btn.setChecked(i == self.min_rating_filter)

    def _open_folder(self):
        """Open folder picker and load new files."""
        # Start from last used folder if available
        recent = load_recent_folders()
        start_dir = recent[0] if recent else str(Path.home())

        folder_str = QFileDialog.getExistingDirectory(
            self,
            "Select folder with RAW files",
            start_dir
        )
        if not folder_str:
            return

        self._load_folder(Path(folder_str))

    def _load_folder(self, folder: Path):
        """Load files from folder (async scan)."""
        # Show scanning indicator
        self.open_btn_center.setVisible(False)
        self.recent_container.setVisible(False)
        self.scanning_label.setText("Scanning folder...")
        self.scanning_label.adjustSize()
        self.scanning_label.setVisible(True)
        self._center_scanning_label()

        # Scan in background with progress
        def progress(current, total):
            self.preload_signals.scan_progress.emit(current, total)

        def scan():
            files = scan_folder(folder, progress_callback=progress)
            self.preload_signals.folder_scanned.emit(files, folder)

        threading.Thread(target=scan, daemon=True).start()

    def _on_scan_progress(self, current: int, total: int):
        """Update scanning progress."""
        pct = int(current / total * 100)
        self.scanning_label.setText(f"Sorting by date... {pct}%")
        self.scanning_label.adjustSize()
        self._center_scanning_label()

    def _on_folder_scanned(self, files: list, folder: Path):
        """Handle folder scan completion."""
        self.scanning_label.setVisible(False)

        if not files:
            self._update_empty_state()
            return

        # Save to recent folders
        add_recent_folder(str(folder))
        self._update_recent_folders_ui()

        # Stop background preload
        if hasattr(self, '_bg_preload_timer'):
            self._bg_preload_timer.stop()

        # Clear state
        self.cache.clear()
        self.ratings.clear()
        self.loading.clear()
        self.thumb_loading.clear()
        self.filmstrip.thumbnails.clear()

        # Load new files
        self.files = files
        self.all_files = files
        self.index = 0
        self.min_rating_filter = 0

        # Update UI
        self.filmstrip.set_total(len(self.files))
        self._update_filter_buttons()
        self._update_empty_state()
        self._load_current()
        self._preload_nearby()
        self._preload_all_thumbnails()
        self._update_overlay()

    def _update_empty_state(self):
        """Show/hide UI elements based on whether files are loaded."""
        has_files = len(self.files) > 0
        # Show filter buttons only when files loaded
        for btn in self.filter_buttons:
            btn.setVisible(has_files)
        # Show filmstrip only when files loaded and user hasn't hidden it
        self.filmstrip.setVisible(has_files and self.filmstrip_visible)
        # Show centered button and recent folders only when no files
        self.open_btn_center.setVisible(not has_files)
        self.recent_container.setVisible(not has_files and len(self.recent_buttons) > 0)
        # Reposition centered button
        if not has_files:
            self._center_open_button()

    def _close_folder(self):
        """Close current folder and show open folder UI."""
        if not self.files:
            return
        # Stop background preload
        if hasattr(self, '_bg_preload_timer'):
            self._bg_preload_timer.stop()
        # Clear state
        self.cache.clear()
        self.ratings.clear()
        self.loading.clear()
        self.thumb_loading.clear()
        self.filmstrip.thumbnails.clear()
        self.files = []
        self.all_files = []
        self.index = 0
        self.min_rating_filter = 0
        # Clear image view
        self.image_view.set_pixmap(QPixmap())
        self._update_overlay()
        self._update_filter_buttons()
        self._update_empty_state()

    def _toggle_filmstrip(self):
        """Toggle filmstrip visibility."""
        if not self.files:
            return
        self.filmstrip_visible = not self.filmstrip_visible
        self.filmstrip.setVisible(self.filmstrip_visible)
        # Reposition filter buttons
        filmstrip_height = self.filmstrip.height() if self.filmstrip_visible else 0
        btn_y = self.height() - filmstrip_height - self.filter_buttons_widget.height() - 10
        btn_x = self.width() - self.filter_buttons_widget.width() - 10
        self.filter_buttons_widget.move(btn_x, btn_y)

    def _center_open_button(self):
        """Center the open button and recent folders on screen."""
        # Position open button
        btn_x = (self.width() - self.open_btn_center.width()) // 2
        btn_y = (self.height() - self.open_btn_center.height()) // 2 - 40
        self.open_btn_center.move(btn_x, btn_y)

        # Position recent folders below button
        self.recent_container.adjustSize()
        rc_x = (self.width() - self.recent_container.width()) // 2
        rc_y = btn_y + self.open_btn_center.height() + 15
        self.recent_container.move(rc_x, rc_y)

    def _center_scanning_label(self):
        """Center the scanning label on screen."""
        x = (self.width() - self.scanning_label.width()) // 2
        y = (self.height() - self.scanning_label.height()) // 2
        self.scanning_label.move(x, y)

    def _center_help_label(self):
        """Center the help label on screen."""
        x = (self.width() - self.help_label.width()) // 2
        y = (self.height() - self.help_label.height()) // 2
        self.help_label.move(x, y)

    def _update_recent_folders_ui(self):
        """Update recent folders buttons."""
        # Clear existing buttons
        for btn in self.recent_buttons:
            self.recent_layout.removeWidget(btn)
            btn.deleteLater()
        self.recent_buttons.clear()

        recent = load_recent_folders()
        if not recent:
            return

        btn_style = """
            QPushButton {
                background-color: rgba(40, 40, 40, 200);
                color: #aaa;
                border: 1px solid #444;
                padding: 8px 15px;
                font-family: Menlo, Monaco, monospace;
                font-size: 12px;
                text-align: left;
            }
            QPushButton:hover {
                background-color: rgba(60, 60, 60, 220);
                color: white;
            }
        """

        for folder in recent:
            # Show only folder name, not full path
            display_name = Path(folder).name
            btn = QPushButton(f"📁 {display_name}", self.recent_container)
            btn.setStyleSheet(btn_style)
            btn.setToolTip(folder)
            btn.clicked.connect(lambda checked, f=folder: self._open_recent_folder(f))
            self.recent_layout.addWidget(btn)
            self.recent_buttons.append(btn)

        self.recent_container.adjustSize()

    def _open_recent_folder(self, folder: str):
        """Open a folder from recent list."""
        self._load_folder(Path(folder))

    def resizeEvent(self, event):
        super().resizeEvent(event)
        self._update_overlay()
        # Position title label (centered horizontally in title bar area)
        self.title_label.move((self.width() - self.title_label.width()) // 2, 6)
        # Position filter buttons in bottom right, above filmstrip
        filmstrip_height = self.filmstrip.height() if self.filmstrip.isVisible() else 0
        btn_y = self.height() - filmstrip_height - self.filter_buttons_widget.height() - 10
        btn_x = self.width() - self.filter_buttons_widget.width() - 10
        self.filter_buttons_widget.move(btn_x, btn_y)
        # Center open button if visible
        if self.open_btn_center.isVisible():
            self._center_open_button()
        # Center scanning label if visible
        if self.scanning_label.isVisible():
            self._center_scanning_label()
        # Center help label if visible
        if self.help_label.isVisible():
            self._center_help_label()

    def mousePressEvent(self, event: QMouseEvent):
        """Handle clicks on update label and title bar dragging."""
        pos = event.position()
        # Check for update label click
        if self.update_label.isVisible() and self.update_label.geometry().contains(int(pos.x()), int(pos.y())):
            if self.update_url:
                subprocess.run(['open', self.update_url])
            return
        # Title bar drag
        if event.button() == Qt.MouseButton.LeftButton and pos.y() < 40:
            self._drag_pos = event.globalPosition().toPoint() - self.frameGeometry().topLeft()
            event.accept()
        else:
            super().mousePressEvent(event)

    def mouseMoveEvent(self, event: QMouseEvent):
        """Drag window if in title bar drag mode."""
        if self._drag_pos is not None:
            self.move(event.globalPosition().toPoint() - self._drag_pos)
            event.accept()
        else:
            super().mouseMoveEvent(event)

    def mouseReleaseEvent(self, event: QMouseEvent):
        """End drag mode."""
        if event.button() == Qt.MouseButton.LeftButton:
            self._drag_pos = None
        super().mouseReleaseEvent(event)

    def dragEnterEvent(self, event):
        """Accept folder drops."""
        if event.mimeData().hasUrls():
            for url in event.mimeData().urls():
                if url.isLocalFile() and Path(url.toLocalFile()).is_dir():
                    event.acceptProposedAction()
                    return
        event.ignore()

    def dragMoveEvent(self, event):
        """Accept folder drops during drag."""
        if event.mimeData().hasUrls():
            for url in event.mimeData().urls():
                if url.isLocalFile() and Path(url.toLocalFile()).is_dir():
                    event.acceptProposedAction()
                    return
        event.ignore()

    def dropEvent(self, event):
        """Open dropped folder."""
        for url in event.mimeData().urls():
            if url.isLocalFile():
                path = Path(url.toLocalFile())
                if path.is_dir():
                    self._load_folder(path)
                    event.acceptProposedAction()
                    return
        event.ignore()

    def keyPressEvent(self, event: QKeyEvent):
        key = event.key()

        if key == Qt.Key.Key_Right:
            self._navigate(1)
        elif key == Qt.Key.Key_Left:
            self._navigate(-1)
        elif key in (Qt.Key.Key_0, Qt.Key.Key_1, Qt.Key.Key_2,
                     Qt.Key.Key_3, Qt.Key.Key_4, Qt.Key.Key_5):
            num = key - Qt.Key.Key_0
            if event.modifiers() in (Qt.KeyboardModifier.ControlModifier, Qt.KeyboardModifier.MetaModifier):
                # Cmd+number = filter
                self._apply_filter(num)
            elif event.modifiers() == Qt.KeyboardModifier.NoModifier:
                # Number = rate
                self._set_rating(num)
        elif key == Qt.Key.Key_I:
            self.show_info = not self.show_info
            self._update_overlay()
        elif key == Qt.Key.Key_S and event.modifiers() == Qt.KeyboardModifier.NoModifier:
            if self.files:
                self.index = 0
                self._load_current()
                self._preload_nearby()
                self._preload_thumbnails()
        elif key == Qt.Key.Key_L and (event.modifiers() == Qt.KeyboardModifier.ControlModifier or
                                       event.modifiers() == Qt.KeyboardModifier.MetaModifier):
            if self.files:
                # Open all files in Lightroom
                subprocess.run(['open', '-a', 'Adobe Lightroom Classic'] + [str(f) for f in self.files])
        elif key == Qt.Key.Key_E:
            if self.files:
                self.index = len(self.files) - 1
                self._load_current()
                self._preload_nearby()
                self._preload_thumbnails()
        elif key == Qt.Key.Key_R:
            if self.files:
                # Ensure all ratings are loaded
                self._load_all_ratings()
                # Find last rated image in current view
                for i in range(len(self.files) - 1, -1, -1):
                    orig_idx = self.all_files.index(self.files[i])
                    if self.ratings.get(orig_idx, 0) > 0:
                        self.index = i
                        self._load_current()
                        self._preload_nearby()
                        self._preload_thumbnails()
                        break
        elif key == Qt.Key.Key_O:
            if self.files:
                subprocess.run(['open', '-R', str(self.files[self.index])])
        elif key == Qt.Key.Key_Escape:
            self._close_folder()
        elif key == Qt.Key.Key_S and (event.modifiers() == Qt.KeyboardModifier.ControlModifier or
                                       event.modifiers() == Qt.KeyboardModifier.MetaModifier):
            self._toggle_filmstrip()
        elif key in (Qt.Key.Key_Q, Qt.Key.Key_W) and (event.modifiers() == Qt.KeyboardModifier.ControlModifier or
                                                       event.modifiers() == Qt.KeyboardModifier.MetaModifier):
            self.close()
        elif key == Qt.Key.Key_H:
            self.help_label.setVisible(not self.help_label.isVisible())
            self._center_help_label()
        else:
            super().keyPressEvent(event)

    def _navigate(self, delta: int):
        new_index = self.index + delta
        if 0 <= new_index < len(self.files):
            self.index = new_index
            self._load_current()
            self._preload_nearby()
            self._preload_thumbnails()

    def _on_scroll_navigate(self, delta: int):
        """Handle scroll-based navigation with debouncing."""
        if not hasattr(self, '_last_scroll_time'):
            self._last_scroll_time = 0
        import time
        current = time.time()
        if current - self._last_scroll_time > 0.2:  # 200ms debounce
            self._last_scroll_time = current
            self._navigate(delta)

    def _set_rating(self, rating: int):
        if not self.files:
            return

        orig_idx = self.all_files.index(self.files[self.index])
        self.ratings[orig_idx] = rating
        write_rating(self.files[self.index], rating)
        self.filmstrip.set_rating(self.index, rating)
        self._update_overlay()

        if self.index < len(self.files) - 1:
            self._navigate(1)

    def showEvent(self, event):
        """Configure transparent titlebar after window is shown."""
        super().showEvent(event)
        if not self._titlebar_configured:
            self._titlebar_configured = True
            QTimer.singleShot(0, self._setup_transparent_titlebar)

    def _setup_transparent_titlebar(self):
        """Configure transparent title bar on macOS."""
        if platform.system() != "Darwin":
            return
        try:
            from AppKit import NSApplication
            ns_app = NSApplication.sharedApplication()
            for window in ns_app.windows():
                if window.title() == self.windowTitle():
                    window.setStyleMask_(window.styleMask() | (1 << 15))  # NSWindowStyleMaskFullSizeContentView
                    window.setTitlebarAppearsTransparent_(True)
                    window.setTitleVisibility_(1)  # NSWindowTitleHidden
                    break
        except ImportError:
            pass

    def closeEvent(self, event):
        # Stop background preload timer
        if hasattr(self, '_bg_preload_timer'):
            self._bg_preload_timer.stop()
        self.executor.shutdown(wait=False)
        self.thumb_executor.shutdown(wait=False)
        super().closeEvent(event)

    def _check_for_updates(self):
        """Check GitHub for newer releases."""
        if VERSION == "dev":
            return
        try:
            url = "https://api.github.com/repos/yannickpulver/raw-viewer/releases/latest"
            req = urllib.request.Request(url, headers={"User-Agent": "RAW-Viewer"})
            with urllib.request.urlopen(req, timeout=5) as resp:
                data = json.loads(resp.read().decode())
                latest = data.get("tag_name", "")
                if latest and latest != VERSION:
                    download_url = data.get("html_url", "")
                    self.preload_signals.update_available.emit(latest, download_url)
        except Exception:
            pass

    def _on_update_available(self, latest: str, download_url: str):
        """Show update available label."""
        self.update_label.setText(f"Update available: {latest}")
        self.update_label.adjustSize()
        self.update_label.move(10, 40)
        self.update_label.setVisible(True)
        self.update_url = download_url
