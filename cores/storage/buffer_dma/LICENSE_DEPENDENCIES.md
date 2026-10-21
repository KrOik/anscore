# Authorship and dependencies

The memory-port backend, arbiter, reference and tests were authored locally.
The canonical workspace sys_register_snapshot.v is now instantiated unchanged
by the CSR bank. The board wrapper also instantiates the existing workspace
sys_uart.v and uart_csr_transport.v unchanged; their canonical paths are recorded
in build source hashes. The 25K CST reuses the physically calibrated IP test
shell pin map. These reused files are not claimed as newly authored buffer RTL.
The existing capture_replay, packet FIFO and boundary/width cores were read for
reuse planning and remain unchanged. No external third-party RTL is embedded
in the newly written buffer/control modules.

Gowin RAM cells are inferred by Yosys; vendor primitive/tool conditions must be
reviewed before distribution. OSS CAD Suite and Python are build/test tools,
not included IP. Local authorship does not establish a distribution license;
the workspace has not assigned redistribution terms. Licensing is an open L5 gate.
