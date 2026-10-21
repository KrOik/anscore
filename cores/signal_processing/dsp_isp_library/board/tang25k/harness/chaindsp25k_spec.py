"""Core set for the 25K ROM build of the DC -> statistics delivery chain.

``board/dsp_chain_harness/run.py`` is the frozen 20K runner: it resolves its
source list inside ``main()`` and exposes no ``CORES`` table, so the 25K build
flow -- which selects RTL, model aliases and the netlist core set from
``runner.CORES`` -- reads this instead of editing the 20K file.  The lists mirror
run.py's own ``rtl``/staging exactly.  A drift here only changes what gets
compiled, never what a report has to contain, because grading still imports
``dsp_chain_harness/protocol.py``.

This chain is the second of the two ``requirements.json:integration_chains``
deliveries, and it differs from every other ROM family in packet geometry: one
signed16 sample per case word (2 payload bytes, so ``stim_25k`` runs with BPE=2)
and a 17-byte report entry per sample instead of a 4-byte word.
"""
import json

CORES = {
    'dc_stats': dict(
        core=0,
        rtl=['chains/dc_statistics/dc_statistics_stream.v',
             'dsp/dc/rtl/dc_stream.sv',
             'dsp/statistics/rtl/statistics_stream.sv'],
        models={'dsp/dc/models/dc_reference.py': 'dc_reference.py',
                'dsp/statistics/models/reference.py': 'reference.py'}),
}
# The two harness stores stay on the frozen block-RAM inference.  A fabric
# replacement (board/tang25k/harness/chain_ram_fabric_25k.v, kept for the record)
# was built and measured 2026-10-08: synthesis still forced the 64x136 store into
# 4 SDPX9B lanes, and nextpnr then died with "no BELs remaining for RAM16SDP4" --
# GW5A LUTRAM cannot hold both stores -- so the variant is unbuildable and the
# store shape is not a variable this dock can move.
SHARED_RTL = ['board/dsp_chain_harness/chain_ram.v']

# Bytes one case word occupies in the stimulus packet, and one result occupies in
# the report; both are read by build_rom_25k instead of assuming the 32-bit shape.
BYTES_PER_WORD = 2
REPORT_BYTES_PER_WORD = 17

# The pipeline model the frozen verify() replays: DC latency comes from the
# promoted DC manifest, statistics latency is the production stage count that
# run.py derives from the statistics source name.
_STATS_LATENCY = 17


def latencies(library_root):
    """(dc_latency, stats_latency) for verify(), guarded the way run.py guards it.

    ``expected_cycles()`` is exact, so a DC source that no longer matches the
    manifest would show up as a silicon mismatch rather than as a documented
    pipeline depth -- the same check the 20K chain runner makes before it builds.
    """
    import hashlib
    manifest = json.loads((library_root / 'dsp' / 'dc'
                           / 'ip_manifest.json').read_text(encoding='utf-8'))
    src = library_root / 'dsp' / 'dc' / 'rtl' / 'dc_stream.sv'
    want = manifest.get('source_sha256')
    if want and hashlib.sha256(src.read_bytes()).hexdigest() != want:
        raise AssertionError('DC source does not match the manifest whose latency '
                             'this build declares: %s' % src)
    return int(manifest['latency_cycles']), _STATS_LATENCY
