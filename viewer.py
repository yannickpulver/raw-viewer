"""Fullscreen RAW image viewer with rating support and filmstrip."""

from pathlib import Path
from typing import List, Dict, Optional
from concurrent.futures import ThreadPoolExecutor
import threading
import subprocess
import platform
import urllib.request
import json
import time

from version import VERSION

from PyQt6.QtWidgets import QMainWindow, QLabel, QWidget, QVBoxLayout, QHBoxLayout, QScrollArea, QGraphicsView, QGraphicsScene, QGraphicsPixmapItem, QPushButton, QFileDialog, QStackedWidget, QSlider
from PyQt6.QtGui import QPixmap, QKeyEvent, QPainter, QFont, QColor, QPen, QWheelEvent, QMouseEvent, QNativeGestureEvent
from PyQt6.QtCore import Qt, pyqtSignal, QObject, QSize, QPointF, QEvent, QTimer, QUrl

from PyQt6.QtMultimedia import QMediaPlayer, QAudioOutput
from PyQt6.QtMultimediaWidgets import QVideoWidget

from preview import extract_preview, extract_thumbnail, extract_thumbnail_bytes, load_jpeg_preview, load_jpeg_thumbnail_bytes, needs_full_render, render_full_preview, pixmap_from_jpeg_srgb as _pixmap_from_jpeg_srgb
from rating import read_rating, write_rating, set_green_tag
from resolve_export import export_to_resolve, is_resolve_installed
from scanner import scan_folder, scan_folder_jpeg, scan_folder_video, get_creation_time
from datetime import datetime
from thumbnail_cache import ThumbnailCache
from recent_folders import load_recent_folders, add_recent_folder
from shoot_stats import load_stats, save_stats


class PreloadSignals(QObject):
    """Signals for background preloading."""
    loaded = pyqtSignal(int, QPixmap)
    thumb_loaded = pyqtSignal(int, QPixmap)
    update_available = pyqtSignal(str, str)  # latest_version, download_url
    folder_scanned = pyqtSignal(list, Path)  # files, folder
    scan_progress = pyqtSignal(int, int)  # current, total
    resolve_status = pyqtSignal(str)  # status message
    resolve_done = pyqtSignal(bool, str)  # success, message


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

    def toggle_zoom(self):
        """Toggle between fit-to-view and 2x zoom."""
        if abs(self.zoom_factor - 1.0) < 0.01:
            self._apply_zoom(2.0)
        else:
            self.reset_zoom()

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
    CACHE_SIZE = 15

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

        # View mode: "raw", "jpeg", or "video"
        self.view_mode: str = "raw"
        self._current_folder: Optional[Path] = None
        # Per-mode state storage
        self._mode_state: Dict[str, dict] = {
            "raw": {"files": [], "all_files": [], "index": 0, "cache": {}, "ratings": {}, "min_rating_filter": 0},
            "jpeg": {"files": [], "all_files": [], "index": 0, "cache": {}, "ratings": {}, "min_rating_filter": 0},
            "video": {"files": [], "all_files": [], "index": 0, "cache": {}, "ratings": {}, "min_rating_filter": 0},
        }

        # Preloading - separate executors for previews and thumbnails
        self.preload_signals = PreloadSignals()
        self.preload_signals.loaded.connect(self._on_preloaded)
        self.preload_signals.thumb_loaded.connect(self._on_thumb_loaded)
        self.preload_signals.update_available.connect(self._on_update_available)
        self.preload_signals.folder_scanned.connect(self._on_folder_scanned)
        self.preload_signals.scan_progress.connect(self._on_scan_progress)
        self.current_executor = ThreadPoolExecutor(max_workers=1)  # Current image (highest priority)
        self.executor = ThreadPoolExecutor(max_workers=6)  # Nearby preloads
        self.thumb_executor = ThreadPoolExecutor(max_workers=4)  # Thumbnails
        self.render_executor = ThreadPoolExecutor(max_workers=1)  # Full RAW renders (low priority)
        self.loading: set = set()
        self.thumb_loading: set = set()
        self.thumb_failed: set = set()  # Track failed thumbnails for progress
        self.lock = threading.Lock()

        # Persistent thumbnail cache
        self.thumb_cache = ThumbnailCache()

        # Throttled progress update
        self._progress_timer = QTimer()
        self._progress_timer.timeout.connect(self._update_loading_progress)
        self._progress_timer.start(200)  # Update every 200ms

        # Shoot selection timer state (persisted per folder)
        # Total elapsed = _shoot_persisted_elapsed + (time.time() - _shoot_session_start).
        # _shoot_last_rating_elapsed is total elapsed at the moment of last rating.
        self._shoot_session_start: Optional[float] = None
        self._shoot_persisted_elapsed: float = 0.0
        self._shoot_last_rating_elapsed: Optional[float] = None
        self._shoot_rated_count: int = 0

        # Main layout
        central = QWidget()
        layout = QVBoxLayout(central)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)

        # Content stack (image or video)
        self.content_stack = QStackedWidget()

        self.image_view = ZoomableImageView()
        self.content_stack.addWidget(self.image_view)

        # Video container with player and timeline
        self.video_container = QWidget()
        self.video_container.setStyleSheet("background-color: black;")
        vc_layout = QVBoxLayout(self.video_container)
        vc_layout.setContentsMargins(0, 0, 0, 0)
        vc_layout.setSpacing(0)

        self.video_widget = QVideoWidget()
        self.video_widget.setFocusPolicy(Qt.FocusPolicy.NoFocus)
        vc_layout.addWidget(self.video_widget, 1)

        # Timeline
        timeline_row = QWidget()
        timeline_row.setStyleSheet("background-color: rgba(20, 20, 20, 220);")
        tl_layout = QHBoxLayout(timeline_row)
        tl_layout.setContentsMargins(10, 4, 10, 4)
        self.timeline_slider = QSlider(Qt.Orientation.Horizontal)
        self.timeline_slider.setStyleSheet("""
            QSlider::groove:horizontal { height: 4px; background: #333; border-radius: 2px; }
            QSlider::handle:horizontal { background: #fff; width: 12px; height: 12px; margin: -4px 0; border-radius: 6px; }
            QSlider::sub-page:horizontal { background: #888; border-radius: 2px; }
        """)
        self.time_label = QLabel("0:00 / 0:00")
        self.time_label.setStyleSheet("color: #aaa; font-family: Menlo, Monaco, monospace; font-size: 11px; padding: 0 8px;")
        self.time_label.setFixedWidth(100)
        self.timeline_slider.setFocusPolicy(Qt.FocusPolicy.NoFocus)
        tl_layout.addWidget(self.timeline_slider)
        tl_layout.addWidget(self.time_label)
        vc_layout.addWidget(timeline_row)

        self.content_stack.addWidget(self.video_container)

        # Media player
        self.player = QMediaPlayer()
        self.audio_output = QAudioOutput()
        self.player.setAudioOutput(self.audio_output)
        self.player.setVideoOutput(self.video_widget)
        self.player.positionChanged.connect(self._on_position_changed)
        self.player.durationChanged.connect(self._on_duration_changed)
        self.timeline_slider.sliderMoved.connect(self._on_timeline_seek)

        layout.addWidget(self.content_stack, 1)

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

        # Resolve export status label
        self.resolve_label = QLabel(self)
        self.resolve_label.setStyleSheet("""
            QLabel {
                background-color: rgba(40, 40, 40, 220);
                color: #ddd;
                padding: 8px 16px;
                font-family: Menlo, Monaco, monospace;
                font-size: 12px;
            }
        """)
        self.resolve_label.setVisible(False)
        self._resolve_exporting = False
        self.preload_signals.resolve_status.connect(self._on_resolve_status)
        self.preload_signals.resolve_done.connect(self._on_resolve_done)

        # Help overlay
        help_text = """
  Keyboard Shortcuts

  ←/→         Navigate images
  0-5          Rate current image
  ⌘0-5        Filter by rating

  S            Go to start
  E            Go to end
  R            Go to last rated

  J            Toggle RAW/JPEG mode
  M            Toggle Video mode
  Space        Play/Pause video
  I            Toggle info overlay
  ⌘S          Toggle filmstrip
  H            Toggle this help
  T            Toggle shoot stats

  O            Show in Finder
  ⌘L          Open all in Lightroom
  ⌘D          Export to DaVinci Resolve
  Esc          Close folder
  ⌘Q          Quit
"""
        self.help_label = QWidget(self)
        self.help_label.setStyleSheet("background-color: rgba(0, 0, 0, 200);")
        help_layout = QVBoxLayout(self.help_label)
        help_layout.setContentsMargins(20, 15, 20, 20)
        help_layout.setSpacing(8)
        # Title row with close button
        title_row = QHBoxLayout()
        title_label = QLabel("Keyboard Shortcuts")
        title_label.setStyleSheet("""
            QLabel {
                background: transparent; color: #ddd;
                font-family: Menlo, Monaco, monospace;
                font-size: 13px; font-weight: bold;
            }
        """)
        close_btn = QPushButton("✕")
        close_btn.setStyleSheet("""
            QPushButton {
                background: transparent; color: #999; border: none;
                font-size: 16px; padding: 0px;
            }
            QPushButton:hover { color: white; }
        """)
        close_btn.setFixedSize(24, 24)
        close_btn.clicked.connect(self._toggle_help)
        title_row.addWidget(title_label)
        title_row.addStretch()
        title_row.addWidget(close_btn)
        help_layout.addLayout(title_row)
        # Help text (without the title line)
        shortcuts_text = "\n".join(help_text.strip().split("\n")[1:]).strip()
        help_content = QLabel(shortcuts_text)
        help_content.setStyleSheet("""
            QLabel {
                background: transparent; color: #ddd;
                font-family: Menlo, Monaco, monospace;
                font-size: 13px; line-height: 1.6;
            }
        """)
        help_layout.addWidget(help_content)
        self.help_label.adjustSize()
        self.help_label.setVisible(False)

        # Shoot stats overlay (stats for nerds)
        self.stats_label = QWidget(self)
        self.stats_label.setStyleSheet("background-color: rgba(0, 0, 0, 200);")
        stats_layout = QVBoxLayout(self.stats_label)
        stats_layout.setContentsMargins(20, 15, 20, 20)
        stats_layout.setSpacing(8)
        stats_title_row = QHBoxLayout()
        stats_title_label = QLabel("Shoot Stats")
        stats_title_label.setStyleSheet("""
            QLabel {
                background: transparent; color: #ddd;
                font-family: Menlo, Monaco, monospace;
                font-size: 13px; font-weight: bold;
            }
        """)
        stats_close_btn = QPushButton("✕")
        stats_close_btn.setStyleSheet("""
            QPushButton {
                background: transparent; color: #999; border: none;
                font-size: 16px; padding: 0px;
            }
            QPushButton:hover { color: white; }
        """)
        stats_close_btn.setFixedSize(24, 24)
        stats_close_btn.clicked.connect(self._toggle_stats)
        stats_title_row.addWidget(stats_title_label)
        stats_title_row.addStretch()
        stats_title_row.addWidget(stats_close_btn)
        stats_layout.addLayout(stats_title_row)
        self.stats_content = QLabel("No shoot active.")
        self.stats_content.setStyleSheet("""
            QLabel {
                background: transparent; color: #ddd;
                font-family: Menlo, Monaco, monospace;
                font-size: 13px; line-height: 1.6;
            }
        """)
        self.stats_content.setMinimumWidth(280)
        stats_layout.addWidget(self.stats_content)
        self.stats_label.adjustSize()
        self.stats_label.setVisible(False)
        self._stats_refresh_timer = QTimer(self)
        self._stats_refresh_timer.timeout.connect(self._update_stats_content)
        self._stats_refresh_timer.setInterval(1000)

        # Snackbar
        self.snackbar = QLabel(self)
        self.snackbar.setStyleSheet("""
            QLabel {
                background-color: rgba(50, 50, 50, 220);
                color: #ddd;
                padding: 8px 16px;
                font-family: 'SF Pro Text', 'Helvetica Neue', sans-serif;
                font-size: 12px;
                border-radius: 4px;
            }
        """)
        self.snackbar.setVisible(False)
        self._snackbar_timer = QTimer(self)
        self._snackbar_timer.setSingleShot(True)
        self._snackbar_timer.timeout.connect(lambda: self.snackbar.setVisible(False))

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

        # Mode switcher buttons (top-left)
        self.mode_switcher = QWidget(self)
        self.mode_switcher.setStyleSheet("background: transparent;")
        ms_layout = QHBoxLayout(self.mode_switcher)
        ms_layout.setContentsMargins(0, 0, 0, 0)
        ms_layout.setSpacing(4)
        self.mode_buttons: Dict[str, QPushButton] = {}
        for mode, label in [("raw", "RAW"), ("jpeg", "JPG"), ("video", "MOV")]:
            btn = QPushButton(label)
            btn.setCheckable(True)
            btn.setStyleSheet(button_style)
            btn.clicked.connect(lambda checked, m=mode: self._on_mode_button(m))
            ms_layout.addWidget(btn)
            self.mode_buttons[mode] = btn
        self.mode_switcher.adjustSize()
        self.mode_switcher.setVisible(False)

        # Help button (standalone, bottom-left, always visible)
        self.help_btn = QPushButton("?", self)
        self.help_btn.setStyleSheet(button_style)
        self.help_btn.clicked.connect(self._toggle_help)
        self.help_btn.adjustSize()

        # Stats button (bottom-left, next to help)
        self.stats_btn = QPushButton("⏱", self)
        self.stats_btn.setStyleSheet(button_style)
        self.stats_btn.clicked.connect(self._toggle_stats)
        self.stats_btn.adjustSize()

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

        # Version label (bottom center on overview)
        self.version_label = QLabel(f"v{VERSION}", self)
        self.version_label.setStyleSheet("""
            QLabel {
                color: #666;
                font-family: Menlo, Monaco, monospace;
                font-size: 11px;
                background: transparent;
            }
        """)
        self.version_label.adjustSize()

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
            if self.view_mode == "video":
                return None  # Video mode uses player, not cached pixmaps
            if self.view_mode == "jpeg":
                return load_jpeg_preview(self.files[idx])
            return extract_preview(self.files[idx])
        return None

    def _load_thumb_sync(self, idx: int) -> Optional[QPixmap]:
        if 0 <= idx < len(self.files):
            if self.view_mode == "jpeg":
                from preview import load_jpeg_thumbnail
                return load_jpeg_thumbnail(self.files[idx], FilmstripWidget.THUMB_SIZE)
            if self.view_mode == "video":
                from preview import load_video_thumbnail
                return load_video_thumbnail(self.files[idx], FilmstripWidget.THUMB_SIZE)
            return extract_thumbnail(self.files[idx], FilmstripWidget.THUMB_SIZE)
        return None

    def _preload_one(self, idx: int):
        if self.view_mode == "video":
            return
        pixmap = self._load_sync(idx)
        if pixmap:
            self.preload_signals.loaded.emit(idx, pixmap)

    def _render_full(self, idx: int):
        """Background full render for files with small embedded previews."""
        pixmap = render_full_preview(self.files[idx])
        if pixmap:
            self.preload_signals.loaded.emit(idx, pixmap)

    def _preload_thumb(self, idx: int):
        success = False
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
                pixmap = _pixmap_from_jpeg_srgb(cached_bytes)
                if pixmap is not None:
                    self.preload_signals.thumb_loaded.emit(idx, pixmap)
                    success = True

            # Generate and cache
            if not success:
                if self.view_mode == "video":
                    from preview import load_video_thumbnail_bytes
                    thumb_bytes = load_video_thumbnail_bytes(path, size)
                elif self.view_mode == "jpeg":
                    thumb_bytes = load_jpeg_thumbnail_bytes(path, size)
                else:
                    thumb_bytes = extract_thumbnail_bytes(path, size)
                if thumb_bytes:
                    self.thumb_cache.set(path, size, thumb_bytes)
                    pixmap = _pixmap_from_jpeg_srgb(thumb_bytes)
                    if pixmap is not None:
                        self.preload_signals.thumb_loaded.emit(idx, pixmap)
                        success = True
        except Exception:
            pass
        finally:
            # Always remove from loading set to prevent stuck entries
            with self.lock:
                self.thumb_loading.discard(idx)
                if not success:
                    self.thumb_failed.add(idx)

    def _preload_nearby(self):
        if self.view_mode == "video":
            return
        for offset in [1, -1, 2, -2, 3, -3, 4, -4, 5, -5, 6, -6]:
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

        if self.view_mode == "video":
            # Load video into player
            self.player.stop()
            self.player.setSource(QUrl.fromLocalFile(str(self.files[self.index])))
            self.player.play()
            self.content_stack.setCurrentIndex(1)
        else:
            self.content_stack.setCurrentIndex(0)
            # Use cached full preview if available (instant)
            with self.lock:
                cached = self.cache.get(self.index)
            if cached:
                self._display(cached)
            else:
                # Show filmstrip thumbnail as placeholder if available
                thumb_pixmap = self.filmstrip.thumbnails.get(self.index)
                if thumb_pixmap:
                    self._display(thumb_pixmap)
                # Load preview on dedicated executor (skips preload queue)
                idx = self.index
                with self.lock:
                    if idx not in self.loading:
                        self.loading.add(idx)
                        self.current_executor.submit(self._preload_one, idx)

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
            self.pos_label.setText("")
            self.pos_label.setVisible(False)
            self.info_label.setVisible(False)
            return
        self.pos_label.setVisible(True)

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

        loaded = len(self.filmstrip.thumbnails) + len(self.thumb_failed)
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
        self.thumb_failed.clear()

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
            "Select folder with images",
            start_dir
        )
        if not folder_str:
            return

        self._load_folder(Path(folder_str))

    def _load_folder(self, folder: Path):
        """Load files from folder (async scan)."""
        self._current_folder = folder
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
            jpeg_files = scan_folder_jpeg(folder)
            video_files = scan_folder_video(folder)
            self._mode_state["jpeg"] = {"files": jpeg_files, "all_files": jpeg_files, "index": 0, "cache": {}, "ratings": {}, "min_rating_filter": 0}
            self._mode_state["video"] = {"files": video_files, "all_files": video_files, "index": 0, "cache": {}, "ratings": {}, "min_rating_filter": 0}
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

        jpeg_count = len(self._mode_state["jpeg"]["files"])
        video_count = len(self._mode_state["video"]["files"])

        if not files and jpeg_count == 0 and video_count == 0:
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
        self.thumb_failed.clear()
        self.filmstrip.thumbnails.clear()

        # Load new files
        self.files = files
        self.all_files = files
        self.index = 0
        self.min_rating_filter = 0

        # Resume (or start) shoot selection timer for this folder
        prior = load_stats(str(folder))
        if prior is not None:
            self._shoot_persisted_elapsed = prior["elapsed"]
            self._shoot_rated_count = prior["rated_count"]
            self._shoot_last_rating_elapsed = prior["last_rating_elapsed"]
        else:
            self._shoot_persisted_elapsed = 0.0
            self._shoot_rated_count = 0
            self._shoot_last_rating_elapsed = None
        self._shoot_session_start = time.time()
        self._update_stats_content()

        # Update UI
        self.filmstrip.set_total(len(self.files))
        self._update_filter_buttons()
        self._update_empty_state()

        # Auto-switch to JPEG/video viewer if no raws but other media exist
        if not files and (jpeg_count > 0 or video_count > 0):
            target = "jpeg" if jpeg_count >= video_count else "video"
            self._switch_view_mode(target)
            return

        self._load_current()
        self._preload_nearby()
        self._preload_all_thumbnails()
        self._update_overlay()

    def _update_empty_state(self):
        """Show/hide UI elements based on whether files are loaded."""
        has_files = len(self.files) > 0
        # Show entire filter toolbar only when files loaded
        self.filter_buttons_widget.setVisible(has_files)
        # Show filmstrip only when files loaded and user hasn't hidden it
        self.filmstrip.setVisible(has_files and self.filmstrip_visible)
        # Show centered button and recent folders only when no files
        self.open_btn_center.setVisible(not has_files)
        self.recent_container.setVisible(not has_files and len(self.recent_buttons) > 0)
        self.version_label.setVisible(not has_files)
        # Reposition centered button
        if not has_files:
            self._center_open_button()
            self._position_version_label()
        self._update_mode_switcher()

    def _close_folder(self):
        """Close current folder and show open folder UI."""
        has_any = self.files or any(s["files"] for s in self._mode_state.values())
        if not has_any:
            return
        # Stop background preload
        if hasattr(self, '_bg_preload_timer'):
            self._bg_preload_timer.stop()
        # Stop video
        self.player.stop()
        # Clear state
        self.cache.clear()
        self.ratings.clear()
        self.loading.clear()
        self.thumb_loading.clear()
        self.thumb_failed.clear()
        self.filmstrip.thumbnails.clear()
        self.files = []
        self.all_files = []
        self.index = 0
        self.min_rating_filter = 0
        # Clear all mode states
        for mode in self._mode_state:
            self._mode_state[mode] = {"files": [], "all_files": [], "index": 0, "cache": {}, "ratings": {}, "min_rating_filter": 0}
        # Persist shoot timer before clearing current folder
        self._persist_shoot_stats()
        self._shoot_session_start = None
        self._shoot_persisted_elapsed = 0.0
        self._shoot_last_rating_elapsed = None
        self._shoot_rated_count = 0
        self._current_folder = None
        self.view_mode = "raw"
        self._update_stats_content()
        self.content_stack.setCurrentIndex(0)
        self.title_label.setText("RAW Viewer")
        self.title_label.adjustSize()
        # Clear image view
        self.image_view.set_pixmap(QPixmap())
        self._update_overlay()
        self._update_filter_buttons()
        self._update_empty_state()

    def _save_mode_state(self, mode: str):
        """Save current active state to the given mode's storage."""
        self._mode_state[mode] = {
            "files": self.files,
            "all_files": self.all_files,
            "index": self.index,
            "cache": self.cache,
            "ratings": self.ratings,
            "min_rating_filter": self.min_rating_filter,
        }

    def _load_mode_state(self, mode: str):
        """Load state from given mode's storage into active state."""
        state = self._mode_state[mode]
        self.files = state["files"]
        self.all_files = state["all_files"]
        self.index = state["index"]
        self.cache = state["cache"]
        self.ratings = state["ratings"]
        self.min_rating_filter = state["min_rating_filter"]

    def _on_mode_button(self, mode: str):
        """Handle mode switcher button click."""
        if mode == self.view_mode:
            self._update_mode_switcher()
            return
        if not self._mode_state[mode]["files"]:
            self._update_mode_switcher()
            return
        # Save current, switch directly without toggle-back behavior
        if hasattr(self, '_bg_preload_timer'):
            self._bg_preload_timer.stop()
        if self.view_mode == "video":
            self.player.stop()
        self._save_mode_state(self.view_mode)
        self._load_mode_state(mode)
        self.view_mode = mode
        self.loading.clear()
        self.thumb_loading.clear()
        self.thumb_failed.clear()
        self.filmstrip.thumbnails.clear()
        titles = {"raw": "RAW Viewer", "jpeg": "JPEG Viewer", "video": "Video Viewer"}
        self.title_label.setText(titles[self.view_mode])
        self.title_label.adjustSize()
        self.content_stack.setCurrentIndex(1 if self.view_mode == "video" else 0)
        self.filmstrip.set_total(len(self.files))
        self._update_filter_buttons()
        self._update_empty_state()
        if self.files:
            self._load_current()
            self._preload_nearby()
            self._preload_all_thumbnails()
        else:
            if self.view_mode != "video":
                self.image_view.set_pixmap(QPixmap())
        self._update_overlay()
        self._update_mode_switcher()

    def _update_mode_switcher(self):
        """Show/hide mode buttons based on available files; mark current as checked."""
        labels = {"raw": "RAW", "jpeg": "JPG", "video": "MOV"}
        any_visible = False
        for mode, btn in self.mode_buttons.items():
            if mode == self.view_mode:
                count = len(self.files)
            else:
                count = len(self._mode_state[mode]["files"])
            available = count > 0
            btn.setVisible(available)
            btn.setChecked(mode == self.view_mode)
            btn.setText(f"{labels[mode]} ({count})" if available else labels[mode])
            if available:
                any_visible = True
        self.mode_switcher.adjustSize()
        self.mode_switcher.setVisible(any_visible)
        self.mode_switcher.move(80, 8)
        self.mode_switcher.raise_()

    def _switch_view_mode(self, target_mode: str):
        """Switch to target mode, or back to raw if already in it."""
        if not self._current_folder:
            return
        # Don't switch to JPEG if no JPEGs available
        if self.view_mode == "raw" and target_mode == "jpeg" and not self._mode_state["jpeg"]["files"]:
            self._show_snackbar("No JPEG files found in this folder")
            return

        # Toggle back to raw if already in target
        if self.view_mode == target_mode:
            target_mode = "raw"

        # Stop background preload
        if hasattr(self, '_bg_preload_timer'):
            self._bg_preload_timer.stop()

        # Stop video if leaving video mode
        if self.view_mode == "video":
            self.player.stop()

        # Save current, load target
        self._save_mode_state(self.view_mode)
        self._load_mode_state(target_mode)
        self.view_mode = target_mode

        # Clear transient state
        self.loading.clear()
        self.thumb_loading.clear()
        self.thumb_failed.clear()
        self.filmstrip.thumbnails.clear()

        # Update title
        titles = {"raw": "RAW Viewer", "jpeg": "JPEG Viewer", "video": "Video Viewer"}
        self.title_label.setText(titles[self.view_mode])
        self.title_label.adjustSize()

        # Switch content view
        self.content_stack.setCurrentIndex(1 if self.view_mode == "video" else 0)

        # Update UI
        self.filmstrip.set_total(len(self.files))
        self._update_filter_buttons()
        self._update_empty_state()
        if self.files:
            self._load_current()
            self._preload_nearby()
            self._preload_all_thumbnails()
        else:
            if self.view_mode != "video":
                self.image_view.set_pixmap(QPixmap())
        self._update_overlay()
        self._update_mode_switcher()

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

    def _position_version_label(self):
        """Position version label at bottom center."""
        x = (self.width() - self.version_label.width()) // 2
        y = self.height() - self.version_label.height() - 10
        self.version_label.move(x, y)

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

    def _toggle_help(self):
        """Toggle help overlay visibility."""
        self.help_label.setVisible(not self.help_label.isVisible())
        if self.help_label.isVisible():
            self.help_label.raise_()
        self._center_help_label()

    def _center_stats_label(self):
        """Center the stats label on screen."""
        x = (self.width() - self.stats_label.width()) // 2
        y = (self.height() - self.stats_label.height()) // 2
        self.stats_label.move(x, y)

    def _toggle_stats(self):
        """Toggle shoot stats overlay visibility."""
        visible = not self.stats_label.isVisible()
        self._update_stats_content()
        self.stats_label.setVisible(visible)
        if visible:
            self.stats_label.raise_()
            self._stats_refresh_timer.start()
        else:
            self._stats_refresh_timer.stop()
        self._center_stats_label()

    def _format_duration(self, seconds: float) -> str:
        """Format seconds as H:MM:SS or M:SS."""
        seconds = int(seconds)
        h, rem = divmod(seconds, 3600)
        m, s = divmod(rem, 60)
        if h:
            return f"{h}:{m:02d}:{s:02d}"
        return f"{m}:{s:02d}"

    def _shoot_elapsed(self) -> float:
        """Total elapsed time in the current shoot (persisted + session)."""
        if self._shoot_session_start is None:
            return self._shoot_persisted_elapsed
        return self._shoot_persisted_elapsed + (time.time() - self._shoot_session_start)

    def _persist_shoot_stats(self):
        """Write current shoot stats to disk."""
        if self._current_folder is None or self._shoot_session_start is None:
            return
        save_stats(
            str(self._current_folder),
            self._shoot_elapsed(),
            self._shoot_rated_count,
            self._shoot_last_rating_elapsed,
        )

    def _update_stats_content(self):
        """Refresh shoot stats text."""
        if self._shoot_session_start is None:
            self.stats_content.setText("No shoot active.\nOpen a folder to start tracking.")
            self.stats_label.adjustSize()
            if self.stats_label.isVisible():
                self._center_stats_label()
            return

        elapsed = self._shoot_elapsed()
        total = len(self.all_files)
        rated = self._shoot_rated_count
        lines = [
            f"Folder:      {self._current_folder.name if self._current_folder else '-'}",
            f"Elapsed:     {self._format_duration(elapsed)}",
            f"Rated:       {rated} / {total}",
        ]
        if self._shoot_last_rating_elapsed is not None:
            to_last = self._shoot_last_rating_elapsed
            lines.append(f"To last rate: {self._format_duration(to_last)}")
            if rated > 0:
                lines.append(f"Avg/rate:    {to_last / rated:.1f}s")
        else:
            lines.append("To last rate: -")
            lines.append("Avg/rate:    -")
        self.stats_content.setText("\n".join(lines))
        self.stats_label.adjustSize()
        if self.stats_label.isVisible():
            self._center_stats_label()

    def _export_to_resolve(self):
        """Export current files with ratings to DaVinci Resolve."""
        if not self.files:
            self._show_snackbar("No files to export")
            return
        if self._resolve_exporting:
            self._show_snackbar("Export already in progress")
            return

        self._resolve_exporting = True
        self._load_all_ratings()
        folder_name = self._current_folder.name if self._current_folder else "Untitled"

        # Capture state for thread
        files = list(self.files)
        ratings = dict(self.ratings)
        all_files = list(self.all_files)
        signals = self.preload_signals

        def run():
            def on_status(msg):
                signals.resolve_status.emit(msg)
            success, message = export_to_resolve(files, ratings, all_files, folder_name, on_status)
            signals.resolve_done.emit(success, message)

        threading.Thread(target=run, daemon=True).start()

    def _on_resolve_status(self, message: str):
        """Update resolve export status label."""
        if message:
            self.resolve_label.setText(message)
            self.resolve_label.adjustSize()
            x = (self.width() - self.resolve_label.width()) // 2
            y = (self.height() - self.resolve_label.height()) // 2
            self.resolve_label.move(x, y)
            self.resolve_label.setVisible(True)
            self.resolve_label.raise_()
        else:
            self.resolve_label.setVisible(False)

    def _on_resolve_done(self, success: bool, message: str):
        """Handle resolve export completion."""
        self._resolve_exporting = False
        self.resolve_label.setVisible(False)
        self._show_snackbar(message, 4000 if success else 5000)

    def _show_snackbar(self, text: str, duration: int = 2000):
        """Show a temporary snackbar message at the bottom center."""
        self.snackbar.setText(text)
        self.snackbar.adjustSize()
        filmstrip_height = self.filmstrip.height() if self.filmstrip.isVisible() else 0
        x = (self.width() - self.snackbar.width()) // 2
        y = self.height() - filmstrip_height - self.snackbar.height() - 20
        self.snackbar.move(x, y)
        self.snackbar.setVisible(True)
        self.snackbar.raise_()
        self._snackbar_timer.start(duration)

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
            btn.adjustSize()
            self.recent_layout.addWidget(btn)
            self.recent_buttons.append(btn)

        self.recent_layout.activate()
        self.recent_container.adjustSize()
        if self.recent_container.isVisible():
            self._center_open_button()

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
        # Position help button bottom-left, above filmstrip
        self.help_btn.move(10, btn_y)
        # Position stats button next to help button
        self.stats_btn.move(10 + self.help_btn.width() + 6, btn_y)
        # Position mode switcher top-left
        self.mode_switcher.move(80, 8)
        # Center open button if visible
        if self.open_btn_center.isVisible():
            self._center_open_button()
        # Position version label if visible
        if self.version_label.isVisible():
            self._position_version_label()
        # Center scanning label if visible
        if self.scanning_label.isVisible():
            self._center_scanning_label()
        # Center help label if visible
        if self.help_label.isVisible():
            self._center_help_label()
        # Center stats label if visible
        if self.stats_label.isVisible():
            self._center_stats_label()

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
        elif key == Qt.Key.Key_D and (event.modifiers() == Qt.KeyboardModifier.ControlModifier or
                                       event.modifiers() == Qt.KeyboardModifier.MetaModifier):
            self._export_to_resolve()
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
        elif key == Qt.Key.Key_J:
            self._switch_view_mode("jpeg")
        elif key == Qt.Key.Key_M:
            self._switch_view_mode("video")
        elif key == Qt.Key.Key_Space:
            if self.view_mode == "video":
                self._toggle_playback()
            else:
                self.image_view.toggle_zoom()
        elif key == Qt.Key.Key_H:
            self._toggle_help()
        elif key == Qt.Key.Key_T:
            self._toggle_stats()
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
        prev_rating = self.ratings.get(orig_idx, 0)
        self.ratings[orig_idx] = rating
        current_file = self.files[self.index]
        write_rating(current_file, rating)
        if self.view_mode in ("jpeg", "video"):
            set_green_tag(current_file, rating > 0)
        self.filmstrip.set_rating(self.index, rating)
        self._update_overlay()

        # Track shoot selection progress
        if self._shoot_session_start is not None:
            changed = False
            if prev_rating == 0 and rating > 0:
                self._shoot_rated_count += 1
                changed = True
            elif prev_rating > 0 and rating == 0:
                self._shoot_rated_count = max(0, self._shoot_rated_count - 1)
                changed = True
            if changed:
                self._shoot_last_rating_elapsed = self._shoot_elapsed()
                self._persist_shoot_stats()
                self._update_stats_content()

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

    def _toggle_playback(self):
        """Toggle video play/pause."""
        if self.player.playbackState() == QMediaPlayer.PlaybackState.PlayingState:
            self.player.pause()
        else:
            self.player.play()

    def _on_position_changed(self, position: int):
        """Update timeline slider as video plays."""
        if not self.timeline_slider.isSliderDown():
            self.timeline_slider.setValue(position)
        self._update_time_label()

    def _on_duration_changed(self, duration: int):
        """Update timeline range when video loads."""
        self.timeline_slider.setRange(0, duration)
        self._update_time_label()

    def _on_timeline_seek(self, position: int):
        """Seek video to slider position."""
        self.player.setPosition(position)

    def _update_time_label(self):
        """Update the time display label."""
        pos = self.player.position() // 1000
        dur = self.player.duration() // 1000
        self.time_label.setText(f"{pos // 60}:{pos % 60:02d} / {dur // 60}:{dur % 60:02d}")

    def closeEvent(self, event):
        # Persist shoot stats before teardown
        self._persist_shoot_stats()
        # Stop background preload timer
        if hasattr(self, '_bg_preload_timer'):
            self._bg_preload_timer.stop()
        self.player.stop()
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
                latest = data.get("tag_name", "").lstrip("v")
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
