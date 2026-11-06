"""SPDX-License-Identifier: Apache-2.0. Independent dictionary lifecycle oracle.
Only the separately gated PREPARATION child may execute this source.
"""
import argparse
import random
from pathlib import Path


class Model:
    def __init__(self, contexts, orders):
        self.contexts, self.capacity = contexts, orders
        self.accounts, self.orders, self.faulted = {}, {}, False

    def totals(self, context):
        return tuple(sum(row[2] for row in self.orders.values()
                         if row[0] == context and row[1] == direction) for direction in (1, 0))

    def apply(self, command):
        op, context, token, buy, quantity, position, low, high, tag = command
        status = 0
        snapshot = None
        row_result = None
        if op == 10:
            self.accounts.clear(); self.orders.clear(); self.faulted = False
        elif op == 11:
            self.faulted = True
        elif self.faulted:
            status = 9
        elif op > 11:
            status = 14
        elif op in (0, 9):
            if context >= self.contexts:
                status = 1
            elif op == 0 and not low <= position <= high:
                status = 8
            elif context not in self.accounts and op != 0:
                status = 2
            elif op == 0 and any(self.totals(context)):
                status = 10
            else:
                if op == 0:
                    self.accounts[context] = (position, low, high)
                snapshot = context
        elif op == 1:
            if token in self.orders:
                status = 4
            elif len(self.orders) == self.capacity:
                status = 6
            elif context >= self.contexts:
                status = 1
            elif quantity == 0:
                status = 3
            elif context not in self.accounts:
                status = 2
            else:
                p, lo, hi = self.accounts[context]
                b, s = self.totals(context)
                if p + b + (quantity if buy else 0) > hi or p - s - (0 if buy else quantity) < lo:
                    status = 5
                else:
                    self.orders[token] = (context, buy, quantity, 1)
                    row_result = self.orders[token]
        elif token not in self.orders:
            status = 7
        else:
            ctx, direction, remain, phase = self.orders[token]
            if op == 2 and (phase != 1 or quantity != remain or buy != direction):
                status = 13
            elif op == 3 and phase != 1:
                status = 13
            elif op == 4 and phase != 2:
                status = 13
            elif op == 6 and phase != 3:
                status = 13
            elif op in (5, 7) and phase == 1:
                status = 13
            elif op in (5, 7) and quantity == 0:
                status = 3
            elif op in (5, 7) and quantity > remain:
                status = 12
            else:
                if op in (2, 5, 6):
                    phase = 2
                elif op == 4:
                    phase = 3
                if op in (5, 7):
                    remain -= quantity
                elif op == 3:
                    remain = 0
                if op == 7:
                    p, lo, hi = self.accounts[ctx]
                    self.accounts[ctx] = (p + (quantity if direction else -quantity), lo, hi)
                if remain:
                    self.orders[token] = (ctx, direction, remain, phase)
                else:
                    del self.orders[token]
                    phase = 0
                row_result = (ctx, direction, remain, phase)
        result = [status, 0, 0, 0, 0, 0, 0, 0, 0, 0, len(self.orders), int(self.faulted)]
        if row_result is not None:
            ctx, direction, remain, phase = row_result
            result[1:5] = [phase, ctx, direction, remain]
            snapshot = ctx
        if snapshot is not None:
            result[2] = snapshot
            result[5:8] = self.accounts[snapshot]
            result[8:10] = self.totals(snapshot)
        return result


def vectors(contexts, orders, tag_width):
    model = Model(contexts, orders)
    records = []
    rng = random.Random(0xB470A + contexts * 97 + orders)

    def emit(op, ctx=0, token=0, buy=1, qty=0, p=0, lo=-100, hi=100):
        command = [op, ctx, token, buy, qty, p, lo, hi, len(records) & ((1 << tag_width) - 1)]
        records.append(command + model.apply(command))

    def inspect():
        for ctx in range(contexts):
            emit(9, ctx)
        for token in list(model.orders):
            emit(8, token=token)

    a, b = (1 << 111) | 7, (1 << 96) | 7  # identical low64, different full tokens
    emit(9); emit(8, token=a); emit(1, token=a, qty=1)
    emit(0, hi=10, lo=-10)
    emit(1, token=a, qty=8); emit(2, token=a, qty=7); emit(2, token=a, buy=0, qty=8)
    emit(2, token=a, qty=8); emit(4, token=a); inspect()
    emit(1, token=b, qty=3); emit(7, token=a, qty=3); inspect()
    emit(5, token=a, qty=0); emit(5, token=a, qty=6); emit(5, token=a, qty=2); inspect()
    emit(4, token=a); emit(6, token=a); emit(6, token=a); emit(4, token=a)
    emit(7, token=a, qty=3); emit(5, token=a, qty=1); emit(3, token=a); inspect()
    emit(1, token=a, qty=2); emit(3, token=a); emit(3, token=a)
    emit(10)
    for ctx in range(contexts):
        emit(0, ctx, p=0, lo=-(1 << 63), hi=(1 << 63)-1)
    for n in range(orders):
        emit(1, n % contexts, (1 << 111) + n, n & 1, (1 << 32)-1)
    emit(1, token=(1 << 110), qty=1); emit(1, token=1 << 111, qty=0)
    inspect()
    for token in list(model.orders):
        row = model.orders[token]
        emit(2, token=token, buy=row[1], qty=row[2]); emit(4, token=token)
        emit(7, token=token, qty=1); emit(5, token=token, qty=(1 << 32)-2)
    inspect()
    for n in range(280):
        op = rng.randrange(16)
        token = rng.getrandbits(112)
        if model.orders and rng.randrange(4):
            token = rng.choice(list(model.orders))
        ctx = rng.choice([0, contexts-1, contexts, 0xffffffff])
        qty = rng.choice([0, 1, 2, 9, 0xffffffff])
        buy = rng.randrange(2)
        if token in model.orders and rng.randrange(2):
            row = model.orders[token]; qty = rng.choice([row[2], max(1, row[2]//2)]); buy=row[1]
        emit(op, ctx, token, buy, qty, rng.choice([0, -(1 << 63), (1 << 63)-1]))
        if n % 17 == 0:
            inspect()
    emit(10)
    emit(0, p=(1 << 63)-1, lo=-(1 << 63), hi=(1 << 63)-1)
    emit(1, token=a, qty=1); emit(1, token=b, buy=0, qty=0xffffffff)
    emit(2, token=b, buy=0, qty=0xffffffff); emit(4, token=b); emit(7, token=b, qty=0xffffffff)
    emit(5, token=b, qty=1); inspect()
    emit(0, p=-(1 << 63), lo=-(1 << 63), hi=(1 << 63)-1)
    emit(1, token=a, buy=0, qty=1); emit(1, token=b, qty=0xffffffff)
    emit(2, token=b, qty=0xffffffff); emit(5, token=b, qty=0xffffffff)
    emit(11); emit(8, token=a); emit(0); emit(10); inspect()
    return records


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--contexts', type=int, required=True)
    parser.add_argument('--orders', type=int, required=True)
    parser.add_argument('--tag', type=int, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    assert 1 <= args.contexts <= 16 and 1 <= args.orders <= 32 and 1 <= args.tag <= 32
    records = vectors(args.contexts, args.orders, args.tag)
    with args.out.open('x', encoding='ascii', newline='\n') as stream:
        stream.write(str(len(records)) + '\n')
        for record in records:
            stream.write(' '.join(format(value & ((1 << 112)-1) if index == 2 else value & ((1 << 64)-1), 'x')
                                  for index, value in enumerate(record)) + '\n')
    print(f'B47_A_ORACLE_PASS records={len(records)} contexts={args.contexts} orders={args.orders} tag={args.tag}')


if __name__ == '__main__':
    main()
