# Runtime hard-JTAG gate: OPEN

The work order requires changing stimulus/parameters and reading results in
one programmed 25K image through physical JTAG. SRAM programming and IDCODE
reads alone do not meet this requirement. UART is a separate optional path.

## Current measured hardware

After the board swap the connected target is Primer 20K, confirmed by the
user and CMSIS-DAP IDCODE 0x081B. All eight LA channels were recalibrated;
evidence is artifacts/tang20k_la_calibration_20261020T153612484609Z. During a
one-second 2 MS/s capture, CMSIS-DAP read the ID successfully while capture
remained live. This proves concurrent IDCODE access and sampling on 20K only.
It does not prove runtime user-data transfer or concurrent image downloads.
Current SRAM on this board remains the reverse frequency-signature image.

## Tool support investigation

Local Yosys Gowin cells_sim.v has no user-JTAG primitive declaration. Local
apycula chipdb.py/gowin_pack.py have no GW_JTAG or fse_create_jtag support.
The upstream files retrieved from YosysHQ/apicula master are retained under
work/jtag_runtime_research with source attribution; they are research copies,
not modifications to the installed toolchain or authored RTL.

Upstream chipdb.py fse_create_jtag explicitly returns unless device is
GW2A-18C. It maps a GW_JTAG resource with ER1/ER2 controls. The upstream packer
contains GW_JTAG fuse support for the GW2A path. This is an implementation lead
for 20K, not evidence of a working local flow or GW5A-25 support.

Next required work: establish a compatible primitive declaration, chipdb,
packer and nextpnr route support (or a supported vendor implementation), then
integrate the scan-to-CSR mailbox and physical host transactions. Its
primitive-independent RTL, host codec, asynchronous-clock regressions and
serial-scan-to-real-fabric simulation now pass; see SCAN_PROTOCOL.md.
For 25K, device-specific support must be established separately.
No software GPIO JTAG replacement is counted as this hard-JTAG gate.

Meanwhile the transport-neutral loaded replay aperture is integrated into the
test shell, allowing its real stream data path and response routing to be
verified independently of the missing physical transport. See
CAPTURE_REPLAY.md and csr_map.md. Physical 25K gate remains open.
