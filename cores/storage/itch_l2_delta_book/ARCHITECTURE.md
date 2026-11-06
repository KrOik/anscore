# B37 pre-implementation decision

Baseline46630205095a13ab95e1b5bebea0094c2a390390. The missing operation is an
atomic old/new price-level delta with full-width aggregate shares and a complete
post-update BBO. The old price_level_order_book handles single SET/ADD/SUB/DELETE
plus BEST/DEPTH, but maxes at32 quantity bits and32 levels per side and exposes
no exact GET or paired mutation. ram_ordered_dictionary caps K/V and capacity
at32; a quantity sidecar would add slot allocation and remain limited to32
levels. ram_hash_table can hold38-bit quantities but has no public iterator or
extremum operation to recover BBO after deleting its best. IOC matcher consumes
price levels rather than reconstructing them. Actual RTL, public operations,
README and file lists were read before selection. Common-scaffold/operator RTL
searches found no equivalent pair/BBO service. This is not a width-only fork.

Choose a single72-bit synchronous RAM with1..64 unordered live price levels,
one bitmap and a sequential scan. Default32/max64 payload is2304/4608 bits.
Scalar row comparisons find both legs and free space while accumulating BBO of
untouched rows. Validate removal before addition, including same-key pairs.
Compute final quantities/capacity before every write. At most two positive rows
change; metadata and externally visible quote commit after the final confirmed
write. A completely removed old row supplies capacity for a new key at full
occupancy. A partial reduction does not. Shared RAM responses are always drained.

This sacrifices ordered depth queries and logarithmic lookup for simpler bounded
storage and atomic pair semantics. One scan is2*LEVELS clocks; source-derived
worst successful response-valid bound is2*LEVELS+10. This is serialized service,
not one event per clock. Inputs32-bit price/quantity, retained quantity38, cover
64 maximal ITCH order quantities. Arbitrary repeated additions may overflow and
are rejected. No arithmetic truncation, rounding or saturation is used.

Resource risk MEDIUM: wide RAM mapping, per-row compare/control routing and O(N)
latency. Live metadata is at most64 bits and no payload RAM is reset. No DSP,
CAM, duplicate hash/dictionary, external memory or vendor primitive is added.
All implementation choices remain HW_UNVERIFIED without new synthesis/PnR/STA.

The real example composes unchanged B36 order-ID state through one outer owner.
Normal default-eight-order deltas always fit eight L2 levels. Deliberately
smaller L2 can reject after state mutation; explicit upstream INVALIDATE makes
this divergence visible before result retirement, and recovery clears/reseeds
both epochs. This failure is not represented as rollback.
