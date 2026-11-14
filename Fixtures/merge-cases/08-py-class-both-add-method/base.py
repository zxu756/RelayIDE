import functools


class Service:
    """Service docs."""

    @staticmethod
    def build(
        name,
        retries=3,
    ):
        return Service()

    @property
    def name(self):
        if self._n:
            for c in self._n:
                if c:
                    return c
        return None
