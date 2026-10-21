# Authorship and dependency boundaries

New stream BLC,frame/control wrappers and tests were authored in this project.
Canonical window,Bayer,AWB,CCM,Gamma and AWB statistics cores remain at their existing paths in
cores/system/common_scaffold/image and are instantiated unchanged. They are
dependencies,not newly duplicated assets. Test/build source hashes identify the
exact dependency revisions. REUSE_AUDIT.md distinguishes inspected capabilities
from claims not yet qualified for this work order.

No external reference source was copied into these new wrappers. Existing
assets' provenance and license records still apply; this note is not a grant
of redistribution rights. RAM/DSP primitive/tool obligations must also be
reviewed before release. The workspace has not assigned a release license for
this combined product. Licensing and physical qualification remain L5 gates.

The ISP CSR adapter additionally instantiates the unchanged canonical
`cores/system/stream_bus_library/rtl/sys_atomic_config.v` with16words.
This remains an existing dependency,not a newly copied atomic-config asset.

The runtime subsystem also reuses unchanged sys_register_snapshot,
ip_test_shell_25k logic_probe8/uart_csr_transport,production_system_ip_25k
sys_uart and buffer_dma_25k frame_stream_monitor. Source hashes identify the
exact dependencies;their existing provenance/release gates remain applicable.
