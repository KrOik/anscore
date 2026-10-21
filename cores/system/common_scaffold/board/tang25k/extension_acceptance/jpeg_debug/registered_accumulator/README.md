# Registered JPEG timing candidate

Development candidate; not a board acceptance claim. Production baseline remains unchanged.

Symbols: accepted coefficient difference, magnitude, category/amplitude, and terminal/error/output commit use separate CE-gated states. Backpressure holds pending tokens. Terminal errors retain codes 1 through 5 with bounded pipeline latency.

DCT: exact signed partial-product multiplication is retained. The signed 48-bit accumulator uses independent 16-bit partial sums and registered carry propagation across MAC, MAC_MID, MAC_HIGH. STORE follows the complete accumulator commit. No golden values changed.

Verification commands: python -B test_symbols_regression.py; python -B test_dct_regression.py; python -B prepare_debug.py; python -B build_debug.py. All run from this directory or use absolute script paths. The build uses pinned official OSS runtime and corrected GW5A-25A chipdb at 50 MHz, <=15000 LUT, <=4 DSP. Root exclusively performs JTAG/UART after route handoff.
