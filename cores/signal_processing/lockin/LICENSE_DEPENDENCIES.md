# Dependency and distribution audit (open)

This file records reuse; it is not a license grant. No project-level
distribution permission has been established for this assembled subsystem.
Do not label the package releasable until the owning parties and applicable
licenses have been confirmed in the IP-00 catalog.

| Canonical source | Use | Modification |
|---|---|---|
| cores/signal_processing/dsp/src/dds_nco.v | Two quadrature references | Unchanged |
| cores/signal_processing/dsp/src/cordic.v | Shared four-lane amplitude/phase | Unchanged |
| cores/system/stream_bus_library/rtl/sys_timestamp64.v | Common source clock counter | Unchanged |
| cores/system/stream_bus_library/rtl/sys_atomic_config.v |16-word shadow/snapshot configuration | Unchanged |
| cores/system/stream_bus_library/board/sys_uart.v | Supplementary serial PHY | Unchanged |
| cores/system/ip_test_shell/rtl/uart_csr_transport.v | Supplementary CSR wire protocol | Unchanged |
| cores/storage/buffer_dma/tools/run_uart.py | Host UART CSR implementation | Imported unchanged |
| cores/storage/buffer_dma/tools/decode_metrics.py | Imported transport helper | Imported unchanged |

The assembled control, measurement integration, virtual source and tests are
stored under this project. Reused algorithms are not presented as new original
IP. Sine/cosine memory images are generated from documented mathematical
expressions in tools/gen_vectors.py. Build manifests hash exact files.

Yosys, ABC, nextpnr-himbaechel, Apicula/gowin_pack and Icarus are external
build/test tools; their own licenses and device databases remain separate
from RTL ownership. The host uses pyserial for physical UART access. Mapping
emits Gowin device primitives; that does not establish rights to redistribute
any vendor collateral. No third-party HDMI/MIPI core is included here.
