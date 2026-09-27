"""Completion audit for the 150-core release: prove or refute every stage of
the bar in one read-only pass, so the final report is not assembled from
impressions.

Checks, per board group 0..19:
  build  - a build evidence dir reports synthesis PASS, route PASS,
           under_budget true and max_frequency_mhz >= 50
  board  - the newest board evidence dir reports that group PASS with errors=0,
           count == units*128, mask FF, a digest equal to board/expected.json
           and a bitstream hash equal to the one the build accepted
  frozen - groups 0..6 still hold the round-1 core order (compact digest
           c95ea971...) and still emit the round-1 UART digests, so the retired
           50-core contract is covered rather than silently replaced
Exit code 0 only when all 20 groups pass all three columns.
"""
import glob
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FROZEN_DIGEST = 'c95ea971'
ROUND1 = ['9FA8F0B7', '11E44BE2', '80C3B385', '39CF2ACC', '5553C641', 'F654D246',
          '0D08E887']


def sha256_file(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def builds():
    """group -> newest accepted build record, across every build evidence dir."""
    best = {}
    for summary in sorted((ROOT / 'evidence').glob('build_*/summary.json')):
        try:
            data = json.loads(summary.read_text(encoding='utf-8'))
        except (ValueError, OSError):
            continue
        for row in data.get('groups', []):
            key = row['group']
            stamp = str(data['timestamp'])
            if key not in best or stamp >= best[key][0]:
                best[key] = (stamp, row, summary.parent)
    return {k: v[1:] for k, v in best.items()}


def board_rows():
    dirs = sorted(glob.glob(str(ROOT / 'evidence' / 'board_*')))
    if not dirs:
        return None, {}
    newest = dirs[-1]
    data = json.loads(Path(newest, 'summary.json').read_text(encoding='utf-8'))
    return newest, {row['group']: row for row in data.get('groups', [])}


def main():
    order = json.loads((ROOT / 'tools' / 'group_order.json').read_text(encoding='utf-8'))
    expected = {row['group']: row for row in
                json.loads((ROOT / 'board' / 'expected.json').read_text(encoding='utf-8'))}
    built = builds()
    board_dir, boarded = board_rows()
    frozen = json.dumps(order[:7], separators=(',', ':'), sort_keys=True)
    frozen_ok = hashlib.sha256(frozen.encode()).hexdigest().startswith(FROZEN_DIGEST)

    print(f'groups in order file: {len(order)}  cores: {sum(len(r) for r in order)}'
          f'  frozen 0-6 order: {"OK" if frozen_ok else "CHANGED"}')
    print(f'expected.json groups: {len(expected)}  build dirs: {len(built)}'
          f'  board dir: {Path(board_dir).name if board_dir else "NONE"}'
          f'  board groups: {len(boarded)}')
    print(f'{"grp":>3} {"units":>5} {"lut":>6} {"dsp":>4} {"bram":>4} {"mhz":>7}'
          f' {"build":>6} {"board":>6} {"digest":>9} {"expected":>9} {"bshash":>7}')

    bad = []
    if not frozen_ok:
        bad.append('frozen groups 0-6 order changed')
    for group, cores in enumerate(order):
        exp = expected.get(group)
        b = built.get(group, (None, None))
        row, bdir = b
        br = boarded.get(group)
        why = []
        if exp is None:
            why.append('no expectation row')
        if row is None:
            why.append('not built')
        if br is None:
            why.append('not programmed/verified')
        if row is not None:
            if row.get('synthesis') != 'PASS':
                why.append(f"synth={row.get('synthesis')}")
            if row.get('route') != 'PASS':
                why.append(f"route={row.get('route')}")
            if not row.get('under_budget'):
                why.append('over budget')
            mhz = row.get('max_frequency_mhz') or 0
            if mhz < 50:
                why.append(f'{mhz}MHz')
        if br is not None and exp is not None:
            if br.get('status') != 'PASS':
                why.append(f"board={br.get('status')}")
            if br.get('digest') != exp['digest']:
                why.append(f"digest {br.get('digest')}!={exp['digest']}")
            if br.get('errors') != exp.get('errors'):
                why.append('errors')
            if br.get('count') != len(cores) * 128:
                why.append(f"count={br.get('count')}")
            if str(br.get('mask', '')).upper() != 'FF':
                why.append(f"mask={br.get('mask')}")
            if row is not None:
                want = row.get('bitstream_sha256')
                if not want and row.get('bitstream'):
                    path = ROOT / row['bitstream']
                    if path.exists():
                        want = sha256_file(path)
                if want and br.get('bitstream_sha256') != want:
                    why.append('bitstream hash differs from build')
        if group < 7 and br is not None and br.get('digest') != ROUND1[group]:
            why.append(f'round-1 contract digest lost ({ROUND1[group]})')
        if row is not None:
            print(f'{group:>3} {len(cores):>5} {row.get("lut_class", 0):>6}'
                  f' {row.get("dsp_class", 0):>4} {row.get("bram_blocks", 0):>4}'
                  f' {row.get("max_frequency_mhz", 0):>7} '
                  f'{str(row.get("synthesis"))[:6]:>6} '
                  f'{(str(br.get("status"))[:6] if br else "-"):>6} '
                  f'{(str(br.get("digest")) if br else "-"):>9} '
                  f'{exp["digest"] if exp else "-":>9} '
                  f'{"same" if not any("hash" in w for w in why) else "DIFF":>7}')
        else:
            print(f'{group:>3} {len(cores):>5} {"-":>6} {"-":>4} {"-":>4} {"-":>7}'
                  f' {"-":>6} {(str(br.get("status"))[:6] if br else "-"):>6} '
                  f'{(str(br.get("digest")) if br else "-"):>9} '
                  f'{exp["digest"] if exp else "-":>9} -')
        if why:
            bad.append(f'group {group}: ' + '; '.join(why))
    integrate = [Path(p) for p in glob.glob(str(ROOT / 'evidence' / 'integrate_*'))
                 if Path(p).is_dir() and Path(p, 'summary.json').exists()]
    integrate.sort(key=lambda p: p.stat().st_mtime)
    if integrate:
        data = json.loads((integrate[-1] / 'summary.json').read_text(encoding='utf-8'))
        print(f'latest integrate run {integrate[-1].name}: status={data.get("status")}'
              f' phases={[p["phase"] + ":" + p["status"] for p in data.get("phases", [])]}'
              f' reason={data.get("reason", "")}')
        if data.get('status') != 'PASS':
            bad.append(f'integration {data.get("status")}')
    for line in bad:
        print('NOT DONE:', line)
    if bad:
        print(f'AUDIT INCOMPLETE: {len(bad)} problem(s)')
        return 1
    print('AUDIT PASS: 20 groups built within budget at >=50 MHz and byte-exact'
          ' on silicon, with the 50-core contract still covered')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
