"""Core set for the 25K ROM build of the CSC -> morphology delivery chain.

``board/image_harness/run.py`` is the frozen 20K runner: it builds its source list
inside ``main()`` and exposes no ``CORES`` table, so the 25K build flow -- which
selects RTL, model aliases and the netlist core set from ``runner.CORES`` -- reads
this instead of editing the 20K file.  The lists mirror run.py's own ``files``
and staging exactly; a drift here only changes what gets compiled, never what a
report has to contain, because grading still imports ``image_harness/protocol.py``.
"""

CORES = {
    'csc_morph': dict(
        core=0,
        rtl=['chains/csc_morphology/csc_morphology_stream.v',
             'isp/csc_stream.v',
             'isp/morphology/morphology_stream.v',
             'isp/morphology/morph_reduce.v'],
        # csc_coeffs.vh is `included by csc_stream.v, so it has to sit beside it
        extra=['isp/csc_coeffs.vh'],
        models={'isp/csc_model.py': 'csc_model.py',
                'isp/morphology/model.py': 'model.py'}),
}
SHARED_RTL = ['infra/window/stream_window.v',
              'infra/window/stream_window_padded.v',
              'board/block_harness/block_ram.v']
