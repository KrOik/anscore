# APB register adapter (additional integration module)

`integration/prod_apb3_adapter.v` connects a single selected kernel to a 32-bit,
zero-wait-state APB3 register bank. This adapter is additional integration code,
not one of the 56 functional cores. Tie kernel `clk_en=1` and share `clk/rst_n`.
Wire the same-named request/response ports together.

| Offset | Access | Meaning |
|---|---|---|
| 0x00 | R/W | read bit0=busy, bit1=complete, bit2=kernel fault; write bit0=start, bit1=clear completion |
| 0x04 | R/W | a operand |
| 0x08 | R/W | b operand |
| 0x0c | R/W | c operand / per-core restart control |
| 0x10 | R | result, stable until next completion |
| 0x14 | R | aux, stable until next completion |
| 0x18 | R | kernel requests accepted modulo2^32 |
| 0x1c | R | kernel responses retired modulo2^32 |
| 0x20 | R | interface identifier 0x50323501 |

Software writes a,b,c, then writes 1 to 0x00. One request stays pending until
the kernel accepts it. On response the bridge latches all fields, clears busy,
sets complete, and raises the level `irq`. Writing 2 to 0x00 acknowledges it.
Starting another request also clears the previous completion/fault status.

All writes while busy, unaligned/unmapped accesses, writes to read-only
registers, and command reserved bits return PSLVERR and have no side effect.
PSLVERR is asserted only during an APB access phase. A kernel fault is a
completed result, not an APB bus failure. Reset cancels pending transactions.
This adapter makes one command outstanding; it does not preserve kernel II=1
throughput under software register accesses. Use native ready/valid for that.
