"""Tests for grid layout math (pure functions)."""

from grid_view import (
    CELL,
    SPACING,
    cell_origin,
    columns_for_width,
    content_height,
    index_at,
    move_vertical,
    visible_index_range,
)

STRIDE = CELL + SPACING  # 206


def test_columns_for_width():
    assert columns_for_width(SPACING + 4 * STRIDE + 10) == 4
    assert columns_for_width(SPACING + 4 * STRIDE) == 4
    assert columns_for_width(100) == 1  # never below 1
    assert columns_for_width(0) == 1


def test_cell_origin():
    assert cell_origin(0, 4) == (SPACING, SPACING)
    assert cell_origin(3, 4) == (SPACING + 3 * STRIDE, SPACING)
    assert cell_origin(5, 4) == (SPACING + STRIDE, SPACING + STRIDE)


def test_content_height():
    assert content_height(0, 4) == 0
    assert content_height(1, 4) == SPACING + STRIDE
    assert content_height(4, 4) == SPACING + STRIDE
    assert content_height(5, 4) == SPACING + 2 * STRIDE
    assert content_height(9, 4) == SPACING + 3 * STRIDE


def test_index_at():
    assert index_at(10, 10, 4, 10) == 0
    assert index_at(SPACING + STRIDE + 10, 10, 4, 10) == 1
    assert index_at(10, SPACING + STRIDE + 10, 4, 10) == 4
    # x beyond last column
    assert index_at(SPACING + 4 * STRIDE + 10, 10, 4, 10) == -1
    # y below last occupied row
    assert index_at(10, SPACING + 2 * STRIDE + 10, 4, 5) == -1
    # index past total
    assert index_at(SPACING + STRIDE + 10, SPACING + STRIDE + 10, 4, 5) == -1


def test_visible_index_range():
    assert visible_index_range(0, 400, 4, 100) == (0, 7)
    assert visible_index_range(0, 400, 4, 5) == (0, 4)
    # top exactly at the start of row 1 (y = SPACING + STRIDE)
    assert visible_index_range(SPACING + STRIDE, SPACING + STRIDE + 400, 4, 100) == (4, 11)
    assert visible_index_range(0, 400, 4, 0) == (0, -1)


def test_move_vertical_down():
    assert move_vertical(0, 4, 10, 1) == 4
    assert move_vertical(6, 4, 10, 1) == 9   # clamps to last item
    assert move_vertical(8, 4, 10, 1) == 8   # already on last row
    assert move_vertical(9, 4, 10, 1) == 9


def test_move_vertical_up():
    assert move_vertical(5, 4, 10, -1) == 1
    assert move_vertical(2, 4, 10, -1) == 2  # already on first row
    assert move_vertical(0, 4, 0, 1) == 0    # empty list
