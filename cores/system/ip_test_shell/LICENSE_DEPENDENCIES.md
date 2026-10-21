# Authorship and dependencies

New probe, width adapter, testbench and Python golden runner were authored in
this workspace. The adapter instantiates existing `sys_width_converter` from
production_system_ip_25k unchanged. Its provenance is documented in that
project's doc/PROVENANCE.md. No external RTL is embedded in these new files.

The workspace has not established an explicit distribution license for these
project paths. No right to redistribute is inferred from authorship metadata.
OSS CAD Suite/Yosys/nextpnr/Icarus and Python are build/test tools, not bundled
RTL. Vendor primitive and transport licensing must be reviewed when integrated.
No DVI netlist or cryptographic security claim is included in this component.

The new csr_capture_replay wrapper reuses canonical sys_capture_replay unchanged;
its provenance remains the production_system_ip_25k record. The wrapper is a
control/integration addition, not a new RAM/replay engine asset. Redistribution
licensing remains unresolved as above.

scan_csr_mailbox, scan_protocol and associated testbenches are new local
integration/control code. They embed no vendor primitive or third-party TAP.
Research copies of upstream apicula files under work/jtag_runtime_research
are attributed to YosysHQ/apicula and are not distributed as authored IP.
