import functools


class Cache:
    """Small cache.

    Keeps values in memory.

    Not thread safe.
    """

    def __init__(self):
        self.items = {}

    def get(self, key):
        if key in self.items:
            return self.items[key]
        return None

    def put(self, key, value):
        self.items[key] = value

    def size(self):
        return len(self.items)


def helper(x):
    return x
