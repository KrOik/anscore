# bank_alloc

best-fit allocator over 16 variable-size banks: configure sizes, allocate the smallest bank that fits the request, release space back, count no-fit faults

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Independent lanes per accepted beat: 1. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Hardware advantage: all 16 bank sizes are scanned in one parallel combinational pass so best-fit arbitration is deterministic and cycle-accurate in a single clock with no multiplier: the only arithmetic is a carry-free saturating add through a 33-bit extension and bank indexing is a shift by 3, so the bank table maps straight onto an inferred BRAM register file

Independent integer model: `step("bank_alloc", a, b, c, state)` in tools/fam_memsys.py. Vector rows: 320, of which 128 run on the board. Board-set coverage: 128 distinct responses, 24 fault rows.
