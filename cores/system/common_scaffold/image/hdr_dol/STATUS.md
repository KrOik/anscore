Changed only new image/hdr_dol files: RTL demux/merge, independent test/oracle, isolated synth runner, README/manifest/source list, small JSON results.
Commands: python -B cores/system/common_scaffold/image/hdr_dol/test_hdr_dol.py; python -B cores/system/common_scaffold/image/hdr_dol/synth_hdr_dol.py.
PASS: 12 cases, 972 exact pixels, random CE/backpressure/gaps, invalid cfg/parameters, marker diagnosis/reset abort. Synthesis 117+302 LUT1-4 and 0+4 DSP, 64x33 12bit. No P&R/board. Temporary artifacts auto cleaned. Shared manifests, crypto and accepted48 snapshots/JTAG untouched.
