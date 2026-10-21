# Binary descriptor set matcher

`descriptor_match.sv` implements exhaustive query/reference Hamming matching for
128 or 256-bit binary descriptors. This is a descriptor-set matcher, distinct
from raster Census stereo. Every valid reference is compared to every query.
Best and second-best are distinct reference entries; equal distances count as
the second-best. Best ties select the lowest insertion index deterministically.
No crosscheck or rotation estimation is implemented or claimed.

## Transaction and interfaces

All handshakes are `rst_n && ce && valid && ready`, on rising edges. Reset is
synchronous and overrides CE. Load query (`load_reference=0`) and reference
(`=1`) entries in any interleaving, each with descriptor, opaque 48-bit metadata
and an invalid flag. Each table has `CAPACITY` entries (1..65535, default 16).
The counts include invalid entries, preserving insertion indices. Invalid
references are excluded from ranking; invalid queries still produce a result
with the invalid-query reason set.

Assert `start_valid` to freeze the tables and snapshot all filtering controls.
Start wins over simultaneous load and deasserts `load_ready`. Tables cannot be
modified during computation or while results await release. Busy load/start/
release attempts are backpressured and have no effect. There is one transaction
storage bank, with separate synchronous query and reference RAMs; there is no
concurrent-frame double buffer. Consume all results and observe `done`, then
handshake `release_valid` to clear counts and begin a new transaction. Old RAM
contents cannot be read after release without new accepted loads.

Every query yields one result, preserving query order. `m_valid` and every
result field hold through backpressure and CE pauses. `done` is a one-enabled-
cycle pulse after the final output transfer; an empty query set emits done
immediately after start with no output. With no CE pauses or stalls, first
result valid appears `3*reference_count + 3` enabled edges after start (minimum
3 for an empty reference table); subsequent result-valid presentations are
`3*reference_count + 4` enabled edges apart when immediately consumed.

`m_best` and `m_second` are 9-bit distances; sentinel **511** means absent.
`m_reference_index=65535` and reference metadata zero mean no valid reference.
Actual distances 0..256 cannot collide with the sentinel. A one-reference set
has valid best but absent second. `m_reason` is a bitmask:

| Bit | Meaning |
| --- | --- |
| 0 | Query marked invalid |
| 1 | No valid reference |
| 2 | Best distance exceeds snapshot `max_distance` |
| 3 | Ambiguous according to gap and/or ratio |

A usable match has reason zero. The maximum distance accepts equality.
`min_gap=0` disables gap filtering; otherwise at least two valid references are
required and `second-best >= min_gap` must hold. Ratio filtering, when enabled,
also requires two references and uses the **strict** condition
`best*ratio_den < second*ratio_num`. Products are unsigned 25-bit, covering all
9-bit distances and 16-bit coefficients without truncation. A tie at distance
zero fails ratio filtering. No-second never passes enabled ratio/gap checks by
treating the sentinel as infinity. Runtime ratio numerator may be zero; ratio
denominator zero with ratio enabled rejects start with error code 2.

`error` pulses on an enabled edge. Code 1 means a load to a full table: request
is consumed but the table and count stay unchanged. Code 2 retains the entire
load transaction so software may correct controls and retry start. Code 3 is
an illegal internal state. `error_code` remains sticky until reset/release.
Overflow is never silent or a wrapping write. Reset aborts any pending
transaction/output, clears counts/valid/errors, and gates all ready outputs.

## BRIEF mapping and tests

Map BRIEF `m_descriptor` without changing bit order; metadata is `{m_id,m_y,m_x}`
and `load_invalid=m_invalid`. An upstream arbiter routes descriptors to query
or reference table and connects BRIEF ready to matcher load-ready only when
that source is selected. Producer outputs must be held until the selected
load handshake. The matcher uses indices for correspondence and does not
reinterpret metadata as coordinates.

Run from repository root:

```powershell
python cores/system/common_scaffold/image/descriptor_match/test_descriptor_match.py
python cores/system/common_scaffold/image/descriptor_match/test_brief_chain.py
python cores/system/common_scaffold/image/descriptor_match/synth.py
```

The Python oracle uses independent `int.bit_count()` ranking. Both lengths
cover random multiquery/multireference tables, invalids, zero/max distance,
ties, no/one reference, exact ratio boundaries, absolute gap, metadata, runtime
configuration snapshot, busy isolation, CE pauses, result stalls, overflow,
invalid configuration, empty queries, and reset in load/compute/output phases.
There are 168 primary transactions and 686 oracle-checked outputs. Additional
real BRIEF RTL chains configure alternating sample pairs, capture a ramp frame,
produce a nonconstant descriptor, and load that exact RTL output into matcher
query/reference entries for both lengths. The BRIEF source is read-only.
The main `test_descriptor_match.py` entry also runs `test_brief_chain.py`, so
integration requires only the main test command.

Isolated `synth_gowin -noalu -nodsp; check` passes both lengths at capacity 16.
128-bit: 1432 LUT1..4, 860 FF, 90 RAM16SDP4; 256-bit: 1786 LUT1..4, 1244 FF,
154 RAM16SDP4. These small memories map to distributed RAM in this configuration;
read behavior is synchronous. Ratio cross multiplication is combinational LUT
logic. No DSP cells were inferred. This is synthesis evidence only, without
timing closure, place/route, or board validation. Temporary simulator and
synthesis intermediates are automatically removed; compact logs are retained.
