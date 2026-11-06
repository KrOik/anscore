# Delivery and offline use

Use `files.f` for `int4_sparse2of4_matvec`, or `example/files.f` for the actual
`four_feature_sparse_top2` integration, from this package root. The explicit
lists include the unchanged repository requantizer and Top-K dependencies.
All RTL, model, fixtures, testbenches, licenses, architecture and interface
contracts are local. No network fetch or source generation is needed to use
the production RTL.

Read `QUALIFICATION.md` for current evidence and limitations. The original
runner and `followup01` runner are immutable one-attempt records; their guards
prevent reuse of the recorded attempt. Future verification requires a newly
reviewed execution plan. Preserve both the original failed attempt and the
passing followup; the original testbench is historical evidence, while the
followup testbenches contain the qualified EOF checks.

The 2:4 representation stores a three-bit pattern and two signed four-bit
values per group. The architecture deliberately reuses one pipelined 9x4
multiplier and an exact requantizer. Default storage and maximum parameter
risks are source-level estimates, not synthesis measurements. Hardware remains
unverified.
