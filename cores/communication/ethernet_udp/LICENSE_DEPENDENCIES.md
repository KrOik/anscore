# Dependency/provenance audit (open)

This file is a reuse inventory, not a distribution license. Repository presence
does not establish ownership or permission. IP-00 must resolve applicable
licenses/rights before any release qualification; no L5 claim is made here.

| Canonical source | Use | Modification |
|---|---|---|
| projects/net_av_hdmi_20k/src/av_rmii_rx.v | Two-bank Ethernet receive/FCS | Unchanged |
| cores/system/stream_bus_library/rtl/sys_timestamp64.v | Dequeue metadata time | Unchanged |
| cores/system/stream_bus_library/rtl/sys_atomic_config.v | Atomic8-word shadow/snapshot | Unchanged |
| cores/system/stream_bus_library/board/sys_uart.v | Supplementary serial PHY | Unchanged |
| cores/system/ip_test_shell/rtl/uart_csr_transport.v | Supplementary CSR transport | Unchanged |
| cores/storage/buffer_dma/tools/run_uart.py | Host UartCsr | Imported unchanged |
| cores/storage/buffer_dma/tools/decode_metrics.py | Transport helper import | Unchanged |

Legacy `av_udp.v`, `av_async_fifo.v` and its testbench are used only in the
separately named canonical NV01 baseline test; they are not the generic UDP
subsystem. `av_phy.v` and official-example SMI logic are research/provenance
references, not part of the current internal-loopback board image. Their20K
physical result is not a25K link result and their license is not inferred.

New RTL under this project contains packet framing/checksum/control/replay
integration; it does not reclassify canonical receive RTL as original work.
Build manifests identify the exact sources. No third-party HDMI or vendor
PHY controller is incorporated into this image.

Yosys/ABC, nextpnr-himbaechel, Apicula/gowin_pack and Icarus are external tools
with independent licenses/device databases. Mapping uses vendor device cells,
which is not a grant to redistribute vendor materials. Host physical serial
uses pyserial; Python zlib is used for independent CRC reference testing.
