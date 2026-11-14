import functools


def base():
    return 0


@functools.wraps(base)
def from_right(x):
    return x - 1
