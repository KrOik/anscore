# Current verification scope

Run tools/test_dual_osd.py,test_frame_config.py,test_multi_timing.py,
test_parallel_crc.py,test_video_route.py,test_results_csr.py,test_raster_osd.py,
test_control.py and test_uart.py with Python after sourcing scripts/env.ps1.
Every run preserves source SHA256,logs and JSON in artifacts/video_compositor_25k.
Independent Python integer blending/raster and zlib CRC models check numerical
results; directed RTL assertions check ownership,backpressure and error paths.

Latest board-top UART simulation: uart_20261020T204400456257Z PASS four exact
CRC/version snapshots across all banks,invalid bank rejection,ACK and repeat run.
Integrated CSR: control_20261020T204159595099Z PASS12frames/six held snapshots.
Raster: raster_osd_20261020T203856310025Z PASS2622ticks/51frames and fixed6clock
sync/pixel alignment. These are intentionally small geometries,not full-resolution
continuous display throughput or evidence of a physical sink.

25K build board_20261020T204424990768Z terminal FAIL125: synthesis passes,
but17664LUT4/2848ALU/7294DFF cannot be legally placed. No routed Fmax or
packed image exists for that attempt. No bitstream has been downloaded. Conditional
Booth build board_20261020T205207679560Z also terminal FAIL125 at legal
placement,17458LUT4/2794ALU/7290DFF. The isolated arithmetic saving did not
close full-top placement; both failed builds are preserved. Conditional
physical display,hard user-JTAG,LA,full-resolution throughput,external-stream
frame buffering and license/release acceptance remain open. Host runner now
exists (HOST.md),with host_20261020T204810174143Z PASS actual UART numerical
fixture,ten negative guards,no ACK on failure and bank mapping. No hardware
runner invocation has occurred; prepared larger profiles are not board passes.
