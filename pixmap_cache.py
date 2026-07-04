"""Byte-capped LRU cache for preview pixmaps."""

from collections import OrderedDict
from typing import Any, Hashable, Optional, Tuple


class LruByteCache:
    """LRU cache bounded by total cost in bytes. Keeps at least one entry."""

    def __init__(self, max_bytes: int):
        self.max_bytes = max_bytes
        self._items: "OrderedDict[Hashable, Tuple[Any, int]]" = OrderedDict()
        self._total = 0

    def get(self, key: Hashable) -> Optional[Any]:
        item = self._items.get(key)
        if item is None:
            return None
        self._items.move_to_end(key)
        return item[0]

    def put(self, key: Hashable, value: Any, cost: int):
        if key in self._items:
            self._total -= self._items[key][1]
            del self._items[key]
        self._items[key] = (value, cost)
        self._total += cost
        while self._total > self.max_bytes and len(self._items) > 1:
            _, (_, evicted_cost) = self._items.popitem(last=False)
            self._total -= evicted_cost

    def __contains__(self, key: Hashable) -> bool:
        return key in self._items

    def clear(self):
        self._items.clear()
        self._total = 0
