# Integration

Compile rtl/mem_port_bram.v, rtl/mem_port_arbiter4.v and
examples/25k/bsram_reference.v. The reference is an internal subsystem with
wide ports, not a pin-constrained board top. Connect it behind stream/DMA
controllers and the IP-01/IP-04 control transport before board compilation.

All ports share clk/rst_n. Provide stable byte addresses/data/strobes until
request handshake. Wait for the response before reusing an application buffer.
Keep downstream ready high when possible; per-master response storage allows
other masters to progress while a consumer stalls. Requests accepted before
reset may already have modified memory; software must not assume rollback.

Commands from repository root:

```powershell
. ./scripts/env.ps1
python cores/storage/buffer_dma/tools/test_memory.py
```

The regression creates a unique source-hashed evidence directory, compile/run
logs and full readback binaries checked against an independent Python model.
Its frame publication/free-slot flags are TESTBENCH variables. They are not
a synthesizable descriptor/ownership implementation or a board DMA test.

Reuse audit: canonical capture_replay owns separate fixed stimulus/response
RAMs and exposes direct host access; it does not implement a shared byte-masked
transaction backend or a four-client arbiter. It is left unchanged. Existing
packet FIFO/width converters and address_boundary4k/burst_split4k are candidates
for the later stream/block-mover integration, not duplicated in this foundation.

Ownership/descriptor tests:

```powershell
python cores/storage/buffer_dma/tools/test_descriptors.py
python cores/storage/buffer_dma/tools/test_slots.py
python cores/storage/buffer_dma/tools/test_slots.py --shared
```

Compile frame_descriptor_ring.v with frame_slot_manager.v. The latter manages
four external data slots and two consumer queues, but does not drive memory
transactions itself. Pair SLOT_WORDS with backing mem_port DEPTH>=4*SLOT_WORDS.
The original bsram_reference is a memory/arbiter reference only; it has not yet
integrated this manager or an automatic stream block mover. See frame_descriptor.md.

Synthesizable on-board test runner: rtl/buffer_dma_selftest.v composes actual
hardware producers/checkers and the full buffer. See SELFTEST.md for start/reset,
seed/gap policy, watchdog and probe semantics. Verify with:
python cores/storage/buffer_dma/tools/test_selftest.py
Include cores/system/stream_bus_library/rtl/sys_register_snapshot.v unchanged
when building the integrated buffer/runner, as the CSR uses that canonical core.
The runner still needs a narrow physical control/transport wrapper before P&R.

The narrow UART/control top and25K pins are documented in BOARD_CONTROL.md. Run test_control.py before build_board.py; do not program its25K image into the currently connected20K. The hard-user-JTAG gate remains separate.
