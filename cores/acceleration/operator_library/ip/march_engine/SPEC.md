# march_engine

March C- memory BIST engine: one address-cell operation per beat over an 8-cell shadow array with ascending and descending elements, mismatch counting, first-failing-address capture and a done/refuse contract

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Independent lanes per accepted beat: 1. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Hardware advantage: A March C- sweep needs 80 address-cell operations and every one of them is read-compare-write against a known pattern, so the fabric runs the whole test at one operation per cycle with a 64-bit cell array in registers: the compare is an 8-bit XOR reduction and the only arithmetic left is saturating counters, which is what lets the BIST engine sit beside a BRAM and test it in place

Independent integer model: `step("march_engine", a, b, c, state)` in tools/fam_memsys.py. Vector rows: 320, of which 128 run on the board. Board-set coverage: 120 distinct responses, 3 fault rows.
