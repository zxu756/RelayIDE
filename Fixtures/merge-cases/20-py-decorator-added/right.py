import functools


def f(x):
    return x + 1


@functools.lru_cache
def g(x):
    return x * 2
