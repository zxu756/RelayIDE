def process(items):
    total = 0
    offset = 1
    for i in items:
        total += i
    tax = 2
    total += tax
    bonus = 3
    total += bonus
    return total + offset


def other():
    return 7
