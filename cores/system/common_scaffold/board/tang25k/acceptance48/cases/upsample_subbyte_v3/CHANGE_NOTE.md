# Exact divider borrow-prefix candidate

Only `source/img_geo_inverse_map.v` differs from the frozen upsample_v2 RTL. The original route failed50MHz at42.60MHz; its critical path was the29-bit low divider subtraction (23.47ns). Both29-bit halves now use independent8/8/8/5-bit subtraction with explicit parallel borrow propagation. Full58-bit restoring-divider state transitions and enabled-cycle latency are unchanged. No numerical golden or public interface changes.

Verification: all seven normal/fault/watchdog UART simulations PASS. Original independent upsample reference passes6width profiles (8,16,24,32,7,12),348commands,42528outputs,12reset cases. Additional100000 full-range random29-bit subtraction checks, including input borrow, PASS. Binary/fixture temporary directories are removed automatically. Original sources and failed build evidence remain preserved.

Build attempt `upsample_subbyte_20261019` running. No JTAG performed by this agent. Hold timing remains unqualified by the open-source flow.
