import functools


class Cache:
    """Small cache.

    Keeps values in memory.
    """

    def __init__(self):
        self.items = {}

    def get(self, key):
        if key in self.items:
            return self.items[key]
        raise KeyError(key)

    def put(self, key, value):
        self.items[key] = value


@functools.lru_cache(maxsize=8)
def helper(x):
    return x
