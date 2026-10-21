# Supplementary host acceptance

```
. ./scripts/env.ps1
python cores/image_processing/video_compositor/tools/test_host.py
python cores/image_processing/video_compositor/tools/run_uart.py --help
```

video_host.py provides banked CSR adaptation, bounded one-frame profiles,
independent integer OSD/zlib reference and save-before-ACK verification.
The host checks magic/build fingerprint, clean idle,empty ownership, applied
version,frame0 CRC/pixel count/error/version,capture serial/timestamp,
one produced frame per lane,unchanged drop counters,and coherent rereads.
Only a fully verified result set is explicitly ACKed. Failure retains results;
no automatic retry/ACK. Existing held results require explicit operator handling.
No host read can prove the FPGA's entire loaded image hash: the runtime build
fingerprint and supplied image SHA256 are recorded as separate evidence.

The runner validates a completed50MHz25K P&R/packed image, both current and
frozen source hashes, and the build manifest fingerprint before opening UART.
It then runs two finite three-lane internal source profiles:
320x240/160x120/80x60 and640x480/320x240/160x120,with dividers1/2/3.
Those profiles are prepared commands, not measured throughput or board passes.

```
python cores/image_processing/video_compositor/tools/run_uart.py --port COMx --build-summary artifacts/video_compositor_25k/<completed-build>/summary.json --output artifacts/video_compositor_25k/<new-capture>
```

Use only after the matching25K image is loaded on25K. No programming is done by
this command. The current connected board was confirmed20K; this runner has
not been invoked against hardware. Output preserves partial per-run captures,
host source hashes and raw UART exchanges even when verification fails.

Host test CRC/count/error/version values come from the actual bitserial RTL
test; auxiliary mailbox timestamp/serial state in its mock transport is
synthetic and is separately covered by the CSR RTL tests. Ten negative cases
exercise wrong frame/CRC/length/error/version/sequence/timestamp/produced
count,wrong loaded fingerprint and bounded timeout. This host-level test does
not replace live transport,25K/hardJTAG/LA or a physical display acceptance.
