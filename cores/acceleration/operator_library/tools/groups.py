"""Balanced board-group layout shared by generation, board build and programming.

A group holds at most 8 cores (the harness selects the unit with addr[9:7]).
By default cores are spread as evenly as possible so no single bitstream is
much larger than another. tools/group_order.json overrides the deal: a bare
name keeps the even formula, a list is one explicit group. Explicit groups let
the seven silicon-proven groups stay frozen while later cores are appended.
"""
import json
from pathlib import Path

from catalog import CORES

ROOT = Path(__file__).resolve().parents[1]
MAX_UNITS = 8
ROWS_PER_CORE = 128
GROUP_COUNT = 20


def ordered_cores():
    """Name order plus per-group unit counts, from group_order.json if present.

    A list entry is one explicit group, so the silicon-proven groups stay
    byte-identically placed while later cores are appended. A bare entry is one
    name and the sizes then come from the even formula. Catalog cores the file
    does not name are appended after it in catalog order and dealt out in
    groups of MAX_UNITS, which lets family bring-up place new cores without
    touching the frozen prefix.
    """
    override = ROOT / 'tools' / 'group_order.json'
    by_name = {entry['name']: entry for entry in CORES}
    if not override.is_file():
        return list(CORES), None
    rows = [row if isinstance(row, list) else [row]
            for row in json.loads(override.read_text(encoding='utf-8'))]
    named = [name for row in rows for name in row]
    if len(named) != len(set(named)) or set(named) - set(by_name):
        raise ValueError('group_order.json must name each catalog core at most once')
    pending = [entry['name'] for entry in CORES if entry['name'] not in set(named)]
    sizes = [len(row) for row in rows]
    if pending:
        sizes += group_sizes(len(pending), -(-len(pending) // MAX_UNITS))
    return [by_name[name] for name in named + pending], sizes


def group_sizes(total, groups=GROUP_COUNT):
    base, extra = divmod(total, groups)
    # With no remainder the widest group is `base`, not `base + 1`; rejecting a
    # total that is an exact multiple of MAX_UNITS would rule out a perfect deal.
    if base + (1 if extra else 0) > MAX_UNITS:
        raise ValueError(f'{total} cores need more than {groups} groups of {MAX_UNITS}')
    return [base + (1 if g < extra else 0) for g in range(groups)]


def plan():
    cores, fixed_sizes = ordered_cores()
    sizes = fixed_sizes if fixed_sizes else group_sizes(len(cores), GROUP_COUNT)
    plan, index = [], 0
    for group, size in enumerate(sizes):
        if not 1 <= size <= MAX_UNITS:
            raise ValueError(f'group {group} asks for {size} units, limit is {MAX_UNITS}')
        members = cores[index:index + size]
        if len(members) != size:
            raise ValueError(f'group {group} wants {size} units, only {len(members)} left')
        index += size
        plan.append(dict(group=group, units=size, rows=size * ROWS_PER_CORE,
                         entries=members, names=[m['name'] for m in members]))
    assert index == len(cores)
    return plan


def group_index(name):
    for row in plan():
        if name in row['names']:
            return row['group']
    raise KeyError(name)
