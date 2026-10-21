"""Family plug-in registry for the 50 accelerator cores.

Each family lives in exactly one file (tools/fam_*.py) so independent authors
never share a write target. A family module exports:

    FAMILY            short family id (str)
    CORES             list of core dicts (see keys below)
    step              step(name, a, b, c, state) -> (r, x, f, new_state)
    vectors           vectors(name, count) -> [(a, b, c), ...]
    tables (optional) tables(name) -> {suffix: [int, ...]}   ROM/coeff images
    selftest (optional) selftest() -> int                    reference checks

Core dict keys:
    name      str, unique, lowercase
    family    str, == FAMILY
    spec      one-line exact semantics (widths, fault rules, restart bit)
    body      Verilog statements for the combinational kernel  (template cores)
    module    complete module text, must define module acc_<name> (custom cores)
    decl      optional module-level localparam/wire/function/generate text
    stateful  bool, reads or writes state
    latency   enabled-edge response latency, default 1, max 8
    faultless bool, core has no fault condition (coverage gate waiver)
    lanes     int, independent data lanes processed per accepted beat
    advantage str, why hardware beats a serial instruction here
"""
import importlib
import sys

FAMILIES = ['fam_simd', 'fam_dsp', 'fam_comm', 'fam_memprot', 'fam_packet',
            'fam_table', 'fam_image', 'fam_control',
            'fam_crypto', 'fam_fft', 'fam_fec', 'fam_netio', 'fam_motor',
            'fam_video', 'fam_audio', 'fam_memsys', 'fam_arith', 'fam_sensing']

CORES = []
MODELS = {}
VECTOR_SOURCES = {}
TABLE_SOURCES = {}
SELFTESTS = {}
LOADED_FAMILIES = []
MISSING_FAMILIES = []

for fname in FAMILIES:
    try:
        module = importlib.import_module(fname)
        cores = module.CORES
        assert all(isinstance(c['name'], str) for c in cores)
        # An author file that is still being written can import fine yet have no
        # model yet. Classify that as a missing family instead of raising here,
        # because this import is shared by every other family's tool run; the
        # generator's core-count assert is what fails closed at integration.
        assert callable(getattr(module, 'step', None)), 'needs a callable step()'
        assert callable(getattr(module, 'vectors', None)), 'needs a callable vectors()'
    except Exception as exc:  # bring-up tolerance: other families may not exist yet
        MISSING_FAMILIES.append(fname)
        print(f'WARN family {fname} skipped: {exc.__class__.__name__}: {exc}',
              file=sys.stderr)
        continue
    LOADED_FAMILIES.append(fname)
    for entry in cores:
        entry.setdefault('decl', '')
        entry.setdefault('stateful', False)
        entry.setdefault('latency', 1)
        entry.setdefault('faultless', False)
        entry.setdefault('lanes', 1)
        entry.setdefault('advantage', '')
        entry.setdefault('module', None)
        if entry['family'] != module.FAMILY:
            raise ValueError(f'{entry["name"]}: family must be {module.FAMILY}')
        CORES.append(entry)
        MODELS[entry['name']] = module.step
        VECTOR_SOURCES[entry['name']] = module.vectors
        if hasattr(module, 'tables'):
            TABLE_SOURCES[entry['name']] = module.tables
        if hasattr(module, 'selftest'):
            SELFTESTS[entry['name']] = module.selftest

names = [c['name'] for c in CORES]
assert len(names) == len(set(names)), 'duplicate core name across families'
assert all(1 <= c['latency'] <= 8 for c in CORES), 'latency must be 1..8'
