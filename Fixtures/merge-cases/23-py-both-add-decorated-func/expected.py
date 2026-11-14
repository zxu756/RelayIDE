import functools


def base():
    return 0


@functools.lru_cache
def from_left(x):
    return x + 1


@functools.wraps(base)
def from_right(x):
    return x - 1
