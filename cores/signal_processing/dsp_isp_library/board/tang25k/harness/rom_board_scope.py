"""Which harness cores a 25K board sweep has to cover -- derived, not listed.

In scope is the intersection of two facts:

* the core's requirement is already board-verified on the 20K, i.e. requirements.json
  carries ``board_injection`` evidence for it.  A core that never made it onto a
  board is out of scope by the goal's own wording, and a 25K round would be its first
  board test rather than a port of a verified one.
* the core is instantiable inside one of the ROM-stimulus harness families
  (build_rom_25k.FAMS), which is read from each harness's own ``run.py`` CORES table.

That leaves the rate/Ethernet and chain/block families out: the dock has no Ethernet
PHY wired into the fabric, and those harnesses have no on-chip stimulus path.  The
resource ceiling is not filtered here -- a core that does not fit the 25K fails its
own build gate, which is the evidence that it was skipped for capacity.
"""
import json, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
BOARD = HERE.parents[1]
LIB = BOARD.parent
sys.path.insert(0, str(HERE))


def requirements():
    doc = json.loads((LIB / 'requirements.json').read_text(encoding='utf-8'))

    def walk(node):
        if isinstance(node, dict):
            if 'board_injection' in node:
                yield node
            for value in node.values():
                yield from walk(value)
        elif isinstance(node, list):
            for value in node:
                yield from walk(value)

    return list(walk(doc))


def core_table():
    """rtl path -> the cores instantiable at that path, from the harnesses.

    A list, not one entry: a leaf RTL file is reachable from several cores --
    ``morphology_stream.v`` builds both the morphology leaf and the
    morphology->median bundle -- and a bundle shares its leaves' files.  Keeping
    only the last write here would silently drop the leaf from the derived scope
    the moment a bundle is registered on the same file.
    """
    import build_rom_25k
    import importlib.util
    table = {}
    for fam, f in build_rom_25k.FAMS.items():
        hdir = BOARD / f['dir']
        # a family whose 20K runner exposes no CORES table keeps its table in the
        # 25K harness dir instead (build_rom_25k.FAMS[...]['spec']), so the frozen
        # 20K runner stays untouched.
        src = (HERE / f['spec']) if 'spec' in f else hdir / 'run.py'
        spec = importlib.util.spec_from_file_location('run_%s' % fam, src)
        mod = importlib.util.module_from_spec(spec)
        sys.path.insert(0, str(hdir))
        spec.loader.exec_module(mod)
        for name, sel in mod.CORES.items():
            for path in sel['rtl']:
                table.setdefault(path, []).append(
                    (fam, name, sel['core'], bool(sel.get('bundle'))))
    return table


def in_scope(bits=8):
    table = core_table()
    rows, seen = [], set()
    for req in sorted(requirements(), key=lambda r: r.get('id', '')):
        if not req.get('board_injection'):
            continue
        for impl in req.get('implementation', []):
            key = impl.split('dsp_isp_library/')[-1]
            for hit in table.get(key, ()):
                if hit[1] in seen:
                    continue
                seen.add(hit[1])
                rows.append(dict(family=hit[0], core=hit[1], core_id=hit[2],
                                 bundle=hit[3], requirement=req['id'], bits=bits))
    return sorted(rows, key=lambda r: (r['family'], r['core_id'], r['core']))


if __name__ == '__main__':
    print(json.dumps(in_scope(), indent=2))
