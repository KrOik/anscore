# Status

PASS: real finite-segment extraction, independent oracle, actual OpenCV comparison, complete protocol recovery and isolated synthesis. No board test claimed.

27 main image fixtures compare all endpoints/support counts/squared lengths exactly. OpenCV PPHT is invoked on every image; known support and exact-match flags are recorded honestly, including probabilistic interior-endpoint differences. Every RTL endpoint is a real original edge pixel. Eleven distinct short segments are emitted in a single case; output truncation at one segment is tested separately. Equal-residual tie handling and 11 additional random angles cover both normal signs and every tolerance value.

Protocol PASS: six marker errors, ten invalid runtime configurations, twelve CE-low reset stages and 29 healthy recovery frames, including successful frame -> invalid START -> healthy frame without reset. Four invalid dimension configurations return explicit errors. Snapshot configuration, CE input pauses, computation pauses, backpressure, held output and held completion are covered.

Full isolated Gowin mapping plus check -assert PASS at 7x9,16x16,32x32. 32x32: 598 LUT1..4,33 MUX2_LUT5,403 ALU,379 FF,64 RAM16SDP4 and one SPX9; zero DSP. This core has no dependency on the upstream full Hough accumulator, and no combined system synthesis or integration is claimed.

All generated large simulation and synthesis artifacts are automatically removed. The source/ROM/scripts/docs freeze index excludes mutable test reports. Only the new hough_segments directory was edited; no shared runner, original core, password-related RTL, board or JTAG was touched.
