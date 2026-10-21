"""Fold Tang Primer 25K dock rounds into requirements.json evidence lists.

The ledger already carries 20K board evidence under ``board_injection`` (per-case
reports read off the board) and ``board_reprogram`` (a second, independently
loaded image reproducing them).  The 25K rounds are the same kind of evidence on
the other dock, so they are appended into those keys rather than into a parallel
schema -- and a 25K round *is* injection-shaped: the cases enter the harness from
the on-chip ROM because the dock's USB-UART bridge cannot drive pad B3.

Nothing is rewritten or removed: existing 20K paths stay verbatim, entries are
added only when absent, and a core is touched only if its round verdict says
PASS for every declared case with no resync skip and no trailing bytes.  The
file is re-serialised with the same one-space indent it already uses, so the
diff is exactly the added lines.

The two rows whose requirement is a *composed delivery* rather than a single IP
(``chain_isp`` = CSC -> morphology, ``chain_dsp`` = DC -> statistics) are folded
twice: into their own requirement, and into ``integration_chains``, which is the
only place this repository records a delivery.  There the round verdicts join the
existing evidence list and a ``tang25k_dock`` block states the device, the clock,
the stimulus path, one entry per independent SRAM program and whether every
program returned the same report digests -- the same claim shape the 20K text in
that field makes about its own board.  Both folds need two fully-passing rounds,
because one program is a measurement and two are a result.

A delivery can also be a *core* of a single-IP family (``BUNDLE_DELIVERIES``):
the composed image is one extra row of that family's CORES table, so the family
name alone cannot say which composition a round evidenced and the fold keys on
``(family, core)``.  Those rounds prove the wiring between verified IPs, not a new
IP, so they reach ``integration_chains`` only and never a leaf requirement's
evidence list.

    python apply_25k_ledger.py --dry-run
    python apply_25k_ledger.py
"""
import argparse, json, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent            # board/tang25k/harness
LIB = HERE.parents[2]                             # dsp_isp_library
ROOT = LIB.parents[1]                             # repository root
sys.path.insert(0, str(HERE))

import rom_board_scope                           # noqa: E402

# ROM family -> the integration_chains key that names the delivery it composes.
# A single-IP family has no entry here and only reaches its own requirement.
DELIVERIES = {'chain_isp': 'ISP', 'chain_dsp': 'DSP'}

# (family, core) -> delivery, for the bundles that are *cores of a single-IP
# family* rather than a family of their own: the family name cannot tell which
# composition a round evidenced, so the pair has to.
BUNDLE_DELIVERIES = {('isp', 'morph_median'): 'DENOISE',
                     ('dstream', 'agc_power'): 'STEREO_METER'}

# What a brand-new delivery row says before any dock clause is appended to it.
DELIVERY_SEED = {
    'DENOISE': 'morphology (ISP-05) -> median (ISP-03) delivered as one bundled '
               'stream core, chains/morph_median/morph_median_stream.v',
    'STEREO_METER': 'stereo AGC (DSP-07, I and Q lanes) -> complex power '
                    'mag_squared (DSP-05) delivered as one bundled stream core, '
                    'chains/agc_power/agc_power_stream.v',
}


def passing_rounds(core):
    """Repo-relative verdict paths for every 25K round that fully passed."""
    rows = []
    for camp in sorted(ROOT.glob('artifacts/ds25k_board_*')):
        top = camp / core / 'verdict.json'
        if not top.exists():
            continue
        t = json.loads(top.read_text(encoding='utf-8'))
        if t.get('status') != 'PASS':
            continue
        for r in sorted(p for p in (camp / core).iterdir()
                        if p.is_dir() and p.name.startswith('round_')):
            v = json.loads((r / 'verdict.json').read_text(encoding='utf-8'))
            complete = (v.get('status') == 'PASS'
                        and v.get('failed') == 0
                        and not v.get('resync_skipped')
                        and not v.get('trailing_bytes')
                        and v.get('captured_bytes') == v.get('expected_bytes'))
            if complete:
                rel = ('artifacts/' + str(r / 'verdict.json')
                       .replace('\\', '/').split('artifacts/', 1)[-1])
                rows.append((rel, v))
    return rows


def digests(verdict):
    return [c.get('report_sha256') for c in verdict['cases']]


def dock_block(core, rounds):
    """What the 25K dock measured about one delivery chain, from its verdicts."""
    first, last = rounds[0][1], rounds[-1][1]
    build = last['build_25k']
    return dict(
        board=last.get('board', 'tangprimer25k'),
        stimulus=last.get('stimulus', 'rom'),
        uart=last.get('uart'), baud=last.get('baud'),
        device=build['device'], family=build['family'],
        clk_mhz=build['clk_mhz'],
        core_name=core,
        programs=len(rounds),
        cases=last['case_count'], passed=last['passed'], failed=last['failed'],
        bytes_per_program=last['captured_bytes'],
        util=build['util'], fmax_mhz=build['fmax_mhz'], gates=build['gates'],
        bitstream=build['bitstream'],
        bitstream_sha256=build['bitstream_sha256'],
        report_digests_identical=all(digests(v) == digests(first) for _, v in rounds),
        verdicts=[rel for rel, _ in rounds],
    )


def dock_clause(core, rounds):
    b = dock_block(core, rounds)
    return ('tang25k dock (%s, %d MHz, on-chip ROM stimulus -> %s): %d independent '
            'SRAM programs of %s, %d/%d cases byte-exact and the per-case report '
            'digests identical across programs'
            % (b['device'], b['clk_mhz'], b['uart'], b['programs'],
               b['bitstream'], b['passed'], b['cases']))


def fold_delivery(doc, key, core, rounds):
    """Append a chain's 25K rounds into integration_chains[key]; return the count."""
    chain = doc['integration_chains'].setdefault(
        key, dict(status=DELIVERY_SEED.get(key, key), evidence=[]))
    added = 0
    for rel, _ in rounds:
        if rel not in chain.setdefault('evidence', []):
            chain['evidence'].append(rel)
            added += 1
    chain['tang25k_dock'] = dock_block(core, rounds)
    clause = dock_clause(core, rounds)
    if clause not in chain['status']:
        chain['status'] = chain['status'].rstrip('.') + '; ' + clause + '.'
        added += 1
    return added


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--dry-run', action='store_true')
    p.add_argument('--bits', type=int, default=8)
    a = p.parse_args()

    doc = json.loads((LIB / 'requirements.json').read_text(encoding='utf-8'))
    by_id = {r['id']: r for r in doc['requirements']}
    plan = []
    for row in rom_board_scope.in_scope(a.bits):
        rounds = passing_rounds(row['core'])
        delivery = (DELIVERIES.get(row['family'])
                    or BUNDLE_DELIVERIES.get((row['family'], row['core'])))
        if row.get('bundle'):
            # A bundle round measures the *composition* behind one port contract,
            # so it is not evidence about a leaf IP and stays out of that
            # requirement's board_injection list; it lands on the delivery row.
            entry = dict(core=row['core'], requirement=row['requirement'],
                         added=0, rounds=len(rounds), bundle=True)
            if not rounds:
                entry['note'] = 'no passing 25K round yet'
            elif not delivery:
                entry['delivery'] = 'unmapped: no integration_chains key'
            elif len(rounds) < 2:
                entry['delivery'] = '%s held: 1 passing round' % delivery
            else:
                entry['delivery'] = delivery
                entry['added'] = fold_delivery(doc, delivery, row['core'], rounds)
            plan.append(entry)
            continue
        if not rounds:
            plan.append(dict(core=row['core'], requirement=row['requirement'],
                             added=0, note='no passing 25K round yet'))
            continue
        req = by_id[row['requirement']]
        added = 0
        for rel, _ in rounds:
            for key in ('board_injection',):
                if rel not in req.setdefault(key, []):
                    req[key].append(rel)
                    added += 1
        last = rounds[-1][0]
        if last not in req.setdefault('board_reprogram', []):
            req['board_reprogram'].append(last)
            added += 1
        entry = dict(core=row['core'], requirement=row['requirement'],
                     added=added, rounds=len(rounds))
        key = DELIVERIES.get(row['family'])
        if key:
            # the delivery claim needs the same two-program bar as the IP one
            if len(rounds) < 2:
                entry['delivery'] = '%s held: 1 passing round' % key
            else:
                entry['delivery'] = key
                entry['added'] += fold_delivery(doc, key, row['core'], rounds)
        plan.append(entry)
    print(json.dumps(plan, indent=1))
    total = sum(x['added'] for x in plan)
    if a.dry_run or not total:
        print('dry run: %d entries would be added' % total)
        return 0
    (LIB / 'requirements.json').write_text(
        json.dumps(doc, indent=1, ensure_ascii=False) + '\n', encoding='utf-8')
    print('requirements.json updated with %d entries' % total)
    return 0


if __name__ == '__main__':
    sys.exit(main())
