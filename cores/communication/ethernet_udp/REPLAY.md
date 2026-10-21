# Finite synthesizable RMII loopback replay

`rtl/udp_replay.v` owns the actual UDP packetizer, RMII serializer, FCS frame
receiver and IPv4/UDP parser. All run on the same core clock. The serializer
dibits feed the receiver internally; probe outputs expose that looped path.
No actual PHY or external cable is involved in this controlled-input mode.

Command valid/ready latches packet count1..65535, payload length4..1472,
32-bit seed, timeout clocks and two fault bits. Only one run is owned.
Payload bytes0..3 encode the zero-based packet sequence little-endian;
later bytes are `(seed_low8+packet_low8*17+index_low8*29) mod256`. All seed
bits initialize a nonzero LFSR controlling receive stalls. The pattern is a
deterministic test vector, not a cryptographic random generator.

Every accepted receive byte is compared with the expected packet/index,
keep/last, source address/port and delivered-frame sequence. Cumulative
reflected CRC32 runs over accepted TX and RX payload bytes (including sequence
prefix). Registers expose raw running CRC initializedffffffff; complement
the result for comparison with standard zlib.crc32. Empty UDP is covered by
generic core tests; this sequence-prefixed replay intentionally requires4bytes.

A packet advances only after actual RMII TX/IFG completion and complete RX
payload comparison. `tx_packets` therefore counts completed paired packets,
not all wire frames emitted before a failure. `rx_packets` counts validated
receive last beats. `tx_bytes` counts submitted payload bytes; `rx_bytes`
counts accepted receive payload bytes, including any byte that triggers an
integrity error. Failed runs can contain partial, unequal counters/CRCs.
Do not report such data as a successful throughput or integrity result.

Fault bit0 flips one body dibit per frame without modifying FCS. Fault bit1
blocks receive payload acceptance. Error bits are exclusive first terminal
causes:0 invalid command,1 timeout,2 receiver/FCS/header/checksum error,
3 payload/boundary/source/sequence mismatch,4 transmitter error. Timeout has
priority, then receiver error, then transmitter error. The timeout counts
COMMAND/LOAD/WAIT clocks, excluding initial core clear and abort/result hold.
The Nth active clock expires when timeout=N; zero is an invalid command.

Each valid run starts with one cycle clearing submodule state/counters.
An error abort resets submodule ownership before publishing the result;
owner counters and error remain held until explicit done_ready. No retry
occurs. Global reset also clears the owner and discards a run without a
completion. A later valid command can recover after timeout, corruption or
global reset. Command changes after acceptance have no effect.

```
. ./scripts/env.ps1
python cores/communication/ethernet_udp/tools/test_replay.py
```

Current test covers four exact independent cumulative-CRC successes (including
1472byte packets), four error completions (FCS injection, blocked sink timeout,
exact5clock timeout, invalid config), held results, mutated command pins,
posterror recovery and global reset during input loading. It does not yet
exercise every terminal payload/transmitter error branch. The result is digital
simulation, not25K controlled board acceptance or continuous wire throughput.

Remaining integration: CSR/runtime configuration and coherent snapshots,
bounded board harness,25K build/PPA, hard-user-JTAG readback, LA captures,
and optional real-PHY adapter/continuous tests.
