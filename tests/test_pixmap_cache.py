from pixmap_cache import LruByteCache


def test_put_get_and_contains():
    c = LruByteCache(max_bytes=100)
    c.put("a", "va", 10)
    assert c.get("a") == "va"
    assert "a" in c
    assert c.get("missing") is None
    assert "missing" not in c


def test_evicts_least_recently_used_when_over_cap():
    c = LruByteCache(max_bytes=100)
    c.put("a", "va", 40)
    c.put("b", "vb", 40)
    c.put("c", "vc", 40)  # total 120 > 100 -> evict "a"
    assert "a" not in c
    assert "b" in c and "c" in c


def test_get_refreshes_recency():
    c = LruByteCache(max_bytes=100)
    c.put("a", "va", 40)
    c.put("b", "vb", 40)
    c.get("a")            # a becomes most recent
    c.put("c", "vc", 40)  # evicts "b", not "a"
    assert "a" in c
    assert "b" not in c


def test_reput_updates_cost():
    c = LruByteCache(max_bytes=100)
    c.put("a", "va", 90)
    c.put("a", "va2", 10)
    c.put("b", "vb", 80)  # fits: 10 + 80 <= 100
    assert c.get("a") == "va2"
    assert "b" in c


def test_never_evicts_last_item():
    c = LruByteCache(max_bytes=100)
    c.put("huge", "v", 500)  # over cap but only item stays
    assert "huge" in c


def test_clear():
    c = LruByteCache(max_bytes=100)
    c.put("a", "va", 10)
    c.clear()
    assert "a" not in c
