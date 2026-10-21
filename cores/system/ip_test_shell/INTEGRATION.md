# Integration

Compile `rtl/stream_width_adapter.v` together with the canonical dependency
`../production_system_ip_25k/rtl/sys_width_converter.v`. Do not copy or modify
that source for integration. Parameterize IN_WIDTH and OUT_WIDTH independently
over 8,16,24,32; keep widths are width/8. Supply common clk/rst_n.

The probe module is optional and only observes caller-provided vectors. It
adds one output register stage. Page configuration is synchronous to clk.
It is not a CDC sampler, clock forwarder or pulse stretcher.

The test runner requires Python, iverilog and vvp on PATH. From the repository:

```powershell
. ./scripts/env.ps1
python cores/system/ip_test_shell/tools/test_width_adapter.py
```

Each invocation creates a unique timestamped evidence directory, retaining
inputs, independent expected outputs, compile/run logs and source SHA256.

This is an in-development component of IP-01/IP-04. Runtime JTAG access,
same-image three-case board
acceptance and external protocol observations have not been implemented here.

`stream_fabric4` combines the existing four-source arbiter (all destinations 0),
32->24 adapter and existing store-and-forward asynchronous packet FIFO.
Compile with canonical sys_frame_switch4, sys_width_converter and
sys_packet_async_fifo. s_user has four packet-constant 8-bit fields; metadata
travels with keep/data through the FIFO. Reset is common to both domains;
system integration must synchronize its release to each clock domain.
The dual-clock fabric does not yet include reset-release synchronizers.

`ip_test_shell_core` connects `test_shell_csr` to the four-source runner and
full response trace readback; see csr_map.md. The example runs both fabric
domains from one clock. A genuine dual-clock system must synchronize reset
release and snapshot cross-domain metrics safely.

`csr_capture_replay` adds a separate host-loaded RAM endpoint using canonical
`sys_capture_replay` unchanged. Compile both files. See CAPTURE_REPLAY.md for
the aperture and integration limits. It is now integrated into the board
decoder at 0x40..0x64 and source 0 of a separate packet fabric; physical
hard-JTAG transport remains open. Generated four-source mode is preserved.

The primitive-independent scan mailbox is tested separately:
`python cores/system/ip_test_shell/tools/test_scan_mailbox.py`. Connect its
CSR master only through an explicit arbiter if sharing a core with UART; never
wire multiple masters directly together. The board example still uses UART
alone and does not instantiate this mailbox. SCAN_PROTOCOL.md defines scan
framing, clock/reset and CDC constraints required before primitive integration.

RGB888 integration uses video_line_packetizer/video_line_depacketizer;
see video_stream_contract.md. Compile video_line_packet_codec.v and run
`python cores/system/ip_test_shell/tools/test_video_codec.py`. The integrated
simulation uses source0, a 24/32 input adapter and FIFO_DEPTH=1024 to hold a
complete 640-pixel line. The board example has not integrated this video path.
