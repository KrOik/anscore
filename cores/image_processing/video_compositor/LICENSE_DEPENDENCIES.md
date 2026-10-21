# Dependency and release status

License audit OPEN. No independent redistribution license or L5 readiness is
asserted by this project. All paths below are in the shared repository and
their authoritative licensing/provenance must be resolved before release.

| Canonical dependency | Reuse |
|---|---|
| common_ip_scaffold/image/multiframe/img_mf_rgb_blend_pipe.v | Unchanged, two ordered blend stages per output |
| common_ip_scaffold/image/video_scanout/video_timing_generator.sv | Unchanged per-output runtime raster |
| production_system_ip_25k/rtl/sys_atomic_config.v | Unchanged atomic parameter banks |
| production_system_ip_25k/rtl/sys_frame_switch4.v | Unchanged frame-locked router |
| production_system_ip_25k/board/sys_uart.v | Unchanged supplementary physical UART |
| ip_test_shell_25k/rtl/uart_csr_transport.v | Unchanged UART CSR framing |

Project-local wrappers,passive video CRC,mailbox/control and test/host code are
new development; this is a code boundary statement, not proof of ownership or
permission to sublicense. OSS tools/Gowin device databases are build dependencies
with their own licenses. No third-party DVI or vendor display IP is included or
claimed as original. No physical display or hard user-JTAG implementation is
present in the supplementary UART top.
