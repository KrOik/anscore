"""Independent mathematical oracle. No RTL state, RAM schedule or external code."""


def clear(rows, reference, capacity, requested=None):
    requested = len(rows) if requested is None else requested
    zero = dict(status=1, price=0, matched=0, buy=0, sell=0, imbalance=0)
    if requested > capacity:
        return dict(zero, status=2)
    assert requested == len(rows)
    if any(qty == 0 for side, price, qty in rows):
        return dict(zero, status=3)
    metrics = []
    for price in sorted({p for side, p, qty in rows}):
        buy = sum(q for side, p, q in rows if side == 0 and p >= price)
        sell = sum(q for side, p, q in rows if side == 1 and p <= price)
        matched = min(buy, sell)
        through_buy = sum(q for side, p, q in rows if side == 0 and p > price)
        through_sell = sum(q for side, p, q in rows if side == 1 and p < price)
        if matched and max(through_buy, through_sell) <= matched:
            metrics.append(((-matched, abs(buy-sell), abs(price-reference), price),
                            dict(status=0, price=price, matched=matched, buy=buy,
                                 sell=sell, imbalance=buy-sell)))
    return min(metrics, key=lambda item: item[0])[1] if metrics else zero


class Book:
    """Two ordinary Python dictionaries; maintenance mirrors the public L2 API."""
    def __init__(self, levels, price_w, qty_w):
        self.levels = levels
        self.maximum = (1 << qty_w)-1
        self.sides = [{}, {}]

    def reset(self):
        self.sides = [{}, {}]

    def command(self, op, side, price, qty, rank):
        book = self.sides[side]
        status = 0
        found = out_price = after = before = 0
        if op > 7:
            status = 7
        elif op <= 2 and qty == 0:
            status = 3
        elif op == 5 and rank >= self.levels:
            status = 6
        elif op <= 3:
            exists = price in book
            previous = book.get(price, 0)
            if op in (2, 3) and not exists:
                status = 1
            elif op == 1 and previous+qty > self.maximum:
                status = 4
            elif op == 2 and previous < qty:
                status = 5
            elif op in (0, 1) and not exists and len(book) == self.levels:
                status = 2
            else:
                new = qty if op == 0 else previous+qty if op == 1 else previous-qty if op == 2 else 0
                if new:
                    book[price] = new
                else:
                    del book[price]
                found, out_price, after, before = int(exists), price, new, previous
        elif op in (4, 5):
            prices = sorted(book, reverse=(side == 0))
            index = 0 if op == 4 else rank
            if index >= len(prices):
                status = 1
            else:
                found, out_price = 1, prices[index]
                after = book[out_price]
        elif op == 6:
            book.clear()
        else:
            self.reset()
        return dict(status=status, found=found, price=out_price, quantity=after,
                    previous=before, bids=len(self.sides[0]), asks=len(self.sides[1]))

    def auction(self, reference):
        rows = [(side, p, q) for side, book in enumerate(self.sides) for p, q in book.items()]
        return dict(clear(rows, reference, 2*self.levels), rows=len(rows),
                    bids=len(self.sides[0]), asks=len(self.sides[1]))
