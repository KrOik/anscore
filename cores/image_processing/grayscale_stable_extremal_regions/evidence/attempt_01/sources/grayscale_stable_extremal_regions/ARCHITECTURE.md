# Architecture and numerical widths

The unchanged B29 grayscale_max_tree receives g, emits N dense tree records,
and is always ready during collection. The new module stores every record in
one packed node bank, computes each numerator, independently cancels local
pair losers, applies area/root/strict-threshold filters, and replays N outputs.
This is one whole frame of ownership; capture, computation and replay do not
overlap with another accepted frame. The public source/sink handshakes are
fully forwarded by the default8x8 example.

N<=256, IW=max(1,clog2 N), CW=max(1,clog2(N+1)). The single node bank has N words
of `NW=10+IW+2*CW` bits: level8,parentIW,areaCW,canonical1,numeratorCW,selected1.
Its one clocked-read port performs exactly one read or one write per edge.
The RAM and node_q have no reset; collection overwrites every index before use.

| Phase | Read edge | Following logic/write edges |
|---|---|---|
| Collect | none | COLLECT writes tree_index only on child valid |
| Numerator | V_READ(scan), then T_READ(walk) as needed | V_LATCH, T_EVAL, V_WRITE(scan) |
| Pair | P_READ(scan), PP_READ(parent) | P_LATCH, PP_LATCH, multiplier, LOSE_READ(loser), LOSE_WRITE(loser) |
| Filter | F_READ(scan) | F_LATCH saves own_word, multiplier if eligible, F_WRITE(scan) |
| Replay | O_READ(output_index) | O_LATCH copies result registers, HOLD until accepted |

No read/write collision behavior is required. Read data is consumed on the
next edge, and loser updates affect only the selected bit. Pair comparisons
always use the unchanged stored numerator/area, so prior loser writes do not
change any subsequent comparison's numerical inputs. Filter read-modify-write
uses own_word held across the multiply. Output HOLD accesses no RAM and permits
arbitrary sink backpressure while every result field is stable.

The only new multiplier is one unsigned9x9 shift/add unit:18-bit shift,
accumulator and first-product registers,9-bit factor,4-bit step. It performs9
MUL edges and1 MUL_DONE edge for each product. Local comparison evaluates two
products; strict filtering evaluates n*Q and P*a. Maximum relevant product is
255*256=65280, represented exactly in18 bits. No divider, saturation, variable
runtime multiply or combinational ancestor search is introduced. A9-bit
unsigned level subtraction represents every gray difference0..255 without
underflow because canonical parent levels strictly decrease.

State encodings are frozen for reset observation and work receipts:
CAPTURE0,COLLECT1,V_READ2,V_LATCH3,T_READ4,T_EVAL5,V_WRITE6,P_READ7,P_LATCH8,
PP_READ9,PP_LATCH10,MUL11,MUL_DONE12,LOSE_READ13,LOSE_WRITE14,F_READ15,
F_LATCH16,F_WRITE17,O_READ18,O_LATCH19,HOLD20. Invalid static parameters keep
the child inside an unselected generate branch, leaving only the new named
unresolved marker. Invalid first dynamic configuration deliberately clears
the child's first SOF to invoke its existing error drain path; public errors
are calculated separately from the caller's actual SOF/EOL/configuration pins.

Serial arithmetic and one port favor bounded storage and a simple control
path at the cost of whole-frame latency and output II3. This package targets
small bounded images, not continuous full-frame video throughput. Resource
counts are source-level estimates; memory mapping, Fmax, power and device PPA
remain unmeasured until separately authorized implementation work.
