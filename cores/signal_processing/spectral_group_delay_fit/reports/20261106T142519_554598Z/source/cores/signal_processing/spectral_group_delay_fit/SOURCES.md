# Sources and provenance

New implementation, oracle, testbench and documentation are original repository
Apache-2.0 work. No external source code was copied, executed or imported.
Repository-native dependencies are unchanged:

- cores/acceleration/stream_phase_unwrap/rtl/stream_phase_unwrap.sv
- cores/system/common_scaffold/image/histogram/rtl/img_hist_serial_multiply.v
- cores/acceleration/integer_divider/rtl/integer_divider.v
- cores/acceleration/stream_atan2/rtl/stream_atan2.sv (actual I/Q example)

Primary conceptual reference: SciPy official group_delay documentation,
https://docs.scipy.org/doc/scipy/reference/generated/scipy.signal.group_delay.html,
read2026-11-06 via official HTTPS after web-search service returned HTTP500.
It defines group delay as the negative phase derivative with units of samples.
This implementation instead estimates a finite-band least-squares slope and
does not claim arbitrary nonlinear phase has a single pointwise delay.
Read-only response33948bytes, SHA256
f0c98aed5783da5ddc3a3539b01124e08aa45e47444d1a7632a614d78501ec88.

SciPy v1.16.0 provenance: commit4d3dcc103612a2edaec7069638b7f8d0d75cab8b,
dated2025-06-22T01:57:22Z, official GitHub API response4231bytes SHA256
ca4b6d135c902773e73c84019245ccd096808fb440846440f253c673824055ca.
Official v1.16.0 LICENSE.txt is BSD-3-Clause; response1531bytes SHA256
221e59f5e910fd7f94e44f0dac77436a11338c285c6346232e4a850a50da0e94.
Only the mathematical concept was used; no SciPy code or implementation
algorithm is included. Oracle uses only Python standard-library arithmetic.

The new one-attempt runner uses the audited repository lifecycle structure
from the sibling B46 C package, with B-specific schema/gate/vector checks.
It does not import or execute that sibling runner. All relevant source and
tool bytes are pinned by SOURCE_SEAL and archived before any execution child.
