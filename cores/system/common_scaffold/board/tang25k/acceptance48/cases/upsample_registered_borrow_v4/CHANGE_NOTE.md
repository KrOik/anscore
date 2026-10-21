# Registered byte divider candidate

The original upsample_v2 route fails at42.60MHz with a29-bit subtract critical path. Combination-only v3 was optimized back into a long LUT chain (44.58MHz FAIL), and its failed artifacts are retained. This v4 changes only img_geo_inverse_map.v, preserving the exact shared58-bit restoring divider and two enabled cycles per quotient bit.

In LOW state, eight independent byte differences and byte less/equal bits are registered along with the shifted remainder. In HIGH state, explicit borrow prefixes use these registered bits, subtract the incoming borrow within each byte, and select the exact58-bit remainder and quotient bit. Widths are8/8/8/8/8/8/8/2. The existing240/241-cycle mapping latency remains unchanged. No test golden, output, marker, opcode, or public interface changes.

Seven UART normal/fault/watchdog regressions PASS. Full-range independent58-bit subtraction including final borrow:100000random records PASS. Original6-width upsample reference PASS:348commands,42528outputs,12reset cases. OSS attempt upsample_regborrow_20261019 running. No production file or JTAG modified. Temporary binaries/fixtures automatically cleaned; original failed evidence retained. Hold timing remains unqualified.
