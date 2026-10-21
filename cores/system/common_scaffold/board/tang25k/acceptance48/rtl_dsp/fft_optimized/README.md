# Isolated FFT timing candidate

Production DSP RTL and public adapter are unchanged. Candidate preserves signed fixed-point radix-2 forward/inverse results, natural order, original widths, synchronous frame RAM and CE/backpressure/error behavior.

Candidate v3 splits each signed IW x17 multiplication into four IW x5 partial products: unsigned low nibbles and signed upper five bits. Products, pair joins, final join, complex sum/difference and arithmetic scaling have separate registers. This adds 18 enabled clocks per butterfly relative to production. The block FFT interface never promised streaming II1.

Regression: `python cores/system/common_scaffold/board/tang25k/acceptance48/rtl_dsp/fft_optimized/run_candidate_tests.py`. Unmodified core tests and independent references cover N=2..256 (eight configurations); unmodified public adapter tests cover N=2..256 (eight more). All 16 PASS, including forward/inverse numerical comparisons, CE, output stalls, malformed recovery and reset. Fixtures/binaries use temporary directories.

Stage: `python cores/system/common_scaffold/board/tang25k/acceptance48/rtl_dsp/fft_optimized/stage_candidate.py --output cores/system/common_scaffold/board/tang25k/acceptance48/rtl_dsp/fft_optimized/case_v3 --verify`. Normal, corrupted-output FAIL, forced-command-timeout UART simulations PASS. Original golden digest 7587C122 is unchanged.

Build: `python cores/system/common_scaffold/board/tang25k/acceptance48/build_case.py cores/system/common_scaffold/board/tang25k/acceptance48/rtl_dsp/fft_optimized/case_v3 --attempt frozen_seed3 --no-lutram`. LUT RAM is disabled because the baseline mapping used unavailable RAM16SDP4 BELs. See actual summary JSON for setup/resources. Hold remains UNPROVEN with the local open-source model; no timing signoff or board claim is made here.

Preserved case_v1: 2652 LUT, 661 FF, 4 BRAM, 0 DSP; 47.68/44.17 MHz, setup FAIL. v1 and v2 frozen sources and build evidence remain separate.

Final case_v3: {'lut4': 2486, 'dff': 765, 'bsram': 4, 'mult12': 0}; fmax [56.03, 54.58] MHz. Setup/resource PASS; hold UNPROVEN, so build returns 1 and does not pack. Internal arithmetic registers have no reset because every operand/product is overwritten before use. Control and observable output reset behavior is retained and all original reset tests pass. case_v2 retained: 2622 LUT/765 FF/4 BRAM/0 DSP, 47.07/46.64 MHz setup FAIL.
