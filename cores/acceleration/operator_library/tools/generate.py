"""Generate release files from authored kernels and the independent family models.

Run from any directory. Generation never imports or reads build evidence.
Use --family/--core to restrict writes while families are authored in
parallel; per-core files never overlap, so concurrent runs are safe.
"""
import argparse
import hashlib
import json

from catalog import CORES
from golden import step, vectors, tables
from generate_lib import ROOT, RTL, TB, kernel_of, write
from groups import plan, ROWS_PER_CORE

TARGET_CORES = 150


def model_home(name):
    for entry in CORES:
        if entry['name'] == name:
            return f'tools/fam_{entry["family"]}.py'
    raise KeyError(name)


def coverage_gate(rows, entry, results):
    """Fail closed on a board vector set that cannot distinguish right from wrong."""
    board = results[:ROWS_PER_CORE]
    distinct = len({(r, x, f) for r, x, f, _ in board})
    faults = sum(1 for _, _, f, _ in board if f)
    assert len(rows) >= ROWS_PER_CORE, f'{entry["name"]}: needs >= {ROWS_PER_CORE} vectors'
    assert distinct >= 96, f'{entry["name"]}: only {distinct} distinct board responses'
    if entry['faultless']:
        assert faults == 0, f'{entry["name"]}: declared faultless yet model faults'
    else:
        assert faults >= 2, f'{entry["name"]}: fewer than 2 fault rows in the board set'
    if entry['stateful']:
        restarts = sum(1 for a, b, c in rows[:ROWS_PER_CORE] if c >> 31)
        assert restarts >= 1, f'{entry["name"]}: stateful core never restarts in the board set'
    return dict(distinct_responses=distinct, fault_rows=faults)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--family')
    ap.add_argument('--core')
    args = ap.parse_args()
    selected = [e for e in CORES
                if (not args.family or e['family'] == args.family)
                and (not args.core or e['name'] == args.core)]
    if not selected:
        ap.error('nothing selected; check --family against catalog.FAMILIES')
    placement, positions = {}, {}
    for row in plan():
        for unit, name in enumerate(row['names']):
            placement[name] = (row['group'], unit, row['units'])
            positions[name] = row['group'] * 8 + unit
    generated = []
    for entry in selected:
        name = entry['name']
        rtl = kernel_of(entry)
        write(f'rtl/acc_{name}.v', rtl)
        rows = vectors(name)
        state, packed_rows, results = 0, [], []
        for a, b, c in rows:
            r, x, f, state = step(name, a, b, c, state)
            results.append((r, x, f, state))
            packed_rows.append(f'{(a << 129)|(b << 97)|(c << 65)|(r << 33)|(x << 1)|f:041x}')
        image = '\n'.join(packed_rows) + '\n'
        write(f'vectors/{name}.mem', image)
        write(f'sim/tb_{name}.sv', TB.replace('@@NAME@@', name)
              .replace('@@COUNT@@', str(len(rows))).replace('@@LATENCY@@', str(entry['latency'])))
        cover = coverage_gate(rows, entry, results)
        group, unit, units = placement[name]
        manifest = dict(schema='production-accel-v1', ip_name=name, core_module='acc_'+name,
                        family=entry['family'], version='1.0.0',
                        interface='enabled-ready-valid-32x3-v1',
                        source=f'rtl/acc_{name}.v', dependencies=entry.get('sim_extra', []),
                        stateful=entry['stateful'], description=entry['spec'],
                        clock_domain='single', latency_enabled_cycles=entry['latency'],
                        initiation_interval_enabled_cycles=1,
                        lanes_per_beat=entry['lanes'], hardware_advantage=entry['advantage'],
                        reference_model=model_home(name) + ':step',
                        testbench=f'sim/tb_{name}.sv', vector_count=len(rows),
                        board_vector_count=ROWS_PER_CORE,
                        vector_sha256=hashlib.sha256(image.encode()).hexdigest(),
                        rtl_sha256=hashlib.sha256(rtl.encode()).hexdigest(),
                        board_group=group, board_unit=unit, board_group_units=units,
                        board_position=positions[name],
                        coverage=cover,
                        validation=dict(simulation='run-required', synthesis='run-required',
                                        board='run-required'),
                        provenance='original source authored in this workspace; no third-party RTL imported',
                        qualification='engineering candidate; not certified production or side-channel protection')
        write(f'ip/{name}/manifest.json', json.dumps(manifest, indent=2) + '\n')
        write(f'ip/{name}/files.f', '../../rtl/acc_' + name + '.v\n')
        write(f'ip/{name}/SPEC.md',
              f'# {name}\n\n{entry["spec"]}\n\n'
              'See [common interface](../../doc/INTERFACE.md). '
              f'Latency: {entry["latency"]} enabled edge(s); II=1 when output ready. '
              f'Independent lanes per accepted beat: {entry["lanes"]}. '
              'Only accepted transactions update state. Reset clears pending output and '
              'state, even while CE is zero.\n\n'
              f'Hardware advantage: {entry["advantage"] or "not stated"}\n\n'
              f'Independent integer model: `step("{name}", a, b, c, state)` in '
              f'{model_home(name)}. Vector rows: {len(rows)}, of which '
              f'{ROWS_PER_CORE} run on the board. Board-set coverage: '
              f'{cover["distinct_responses"]} distinct responses, {cover["fault_rows"]} fault rows.\n')
        generated.append(manifest)
        print(f'GEN {name}: {len(rows)} vectors latency={entry["latency"]} '
              f'lanes={entry["lanes"]} group={group}', flush=True)
    if not args.family and not args.core:
        assert len(CORES) == TARGET_CORES, (
            f'catalog holds {len(CORES)} cores, release expects {TARGET_CORES}')
        # The release promise is a core that states why hardware beats software,
        # not only one that passes numeric gates. Checked once, here, over the
        # whole catalog, so a family cannot ship an empty or copied claim.
        offenders, seen = [], {}
        for m in generated:
            spec, why = m['description'].strip(), m['hardware_advantage'].strip()
            if len(spec) < 40:
                offenders.append(f'{m["ip_name"]}: spec is {len(spec)} chars')
            if len(why) < 60:
                offenders.append(f'{m["ip_name"]}: advantage claim is '
                                 f'{len(why)} chars, needs a real argument')
            key = ' '.join(why.lower().split())
            if key in seen:
                offenders.append(f'{m["ip_name"]}: copies the advantage claim of '
                                 f'{seen[key]}')
            else:
                seen[key] = m['ip_name']
        assert not offenders, 'value-proposition gate failed:\n  ' + '\n  '.join(offenders)
        write('catalog.json', json.dumps(dict(
            count=len(generated), device='GW5A-LV25MG121NES',
            budget=dict(lut_class=18000, dsp_class=32, bram_blocks=48),
            groups=[dict(group=row['group'], units=row['units'], rows=row['rows'],
                         cores=row['names']) for row in plan()],
            cores=generated), indent=2) + '\n')
        write('doc/CATALOG.md', '# Accelerator IP catalog\n\n'
              '| # | Group/unit | Family | Core | Lanes/beat | Lat | Function | Why hardware wins |\n'
              '|---|---|---|---|---|---|---|---|\n' +
              '\n'.join(f'| {m["board_position"]+1:02d} | {m["board_group"]}/{m["board_unit"]} | '
                        f'{m["family"]} | [{m["ip_name"]}](../ip/{m["ip_name"]}/SPEC.md) | '
                        f'{m["lanes_per_beat"]} | {m["latency_enabled_cycles"]} | '
                        f'{m["description"]} | {m["hardware_advantage"]} |'
                        for m in generated) + '\n')
    print(f'Generated {len(generated)} accelerator cores (RTL, vectors, benches, manifests)')


if __name__ == '__main__':
    main()
