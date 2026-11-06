# State and resource argument

The hash index is the only ID lookup owner. Payload rows contain
`{padding,next_valid,next_slot,order64,sell,price,remaining}`. An ORDERS-bit live
bitmap owns physical RAM slots; head_valid/head/tail own global admission order.
Each live slot appears once in the singly linked chain and once in the hash.
No payload row is observed without live ownership. Reset/CLEAR empties all
three domains before another command is admitted.

A legal NEW first checks positive quantity, absent ID, then a free slot. That
reserved slot stays unavailable to no other actor because no other command can
enter. The active taker lives in registers; its ID is installed only if a
positive residual must rest. Matching chooses an opposite-side crossing row
and replaces the candidate only for strictly smaller ask price (buy) or larger
bid price (sell). Scanning oldest-to-newest gives same-price FIFO without any
timestamp numeric limit. Partial makers keep their original link position.

The filled quantity is min(taker_remaining,maker_remaining). A partial maker
is overwritten with its positive remainder. A depleted maker is removed from
the hash, predecessor/head link, live bitmap and count before FILL is exposed.
The controller does not scan again until that fill retires. Cancellation uses
the same removal path after ID lookup and predecessor discovery. Tail removal
updates the tail; an empty chain's stale pointer bits have no owner. A residual
is written, old-tail link patched and new live/head/tail/count committed before
the final response. All expected rejections occur before mutation.

The shared single-port RAM uses registered request/response ownership; reads
and writes never compete. The hash and RAM subtransactions each drain their
reply before returning to the next phase. Asynchronous reset cancels the outer
owner and RAM response; the shared hash sees synchronous `!rst_n`, hence reset
must include a rising edge. Hash metadata initialization gates public admission.

Worst storage at N32 is4352 order bits+2272 hash bits=6624 array bits. Default
N16 is2176+1120=3296 array bits. Scalar/candidate/row/output registers are
additional; no measured BRAM/LUT/FF/Fmax/PPA figure follows from those totals.
One match can require a complete chain scan, a bounded hash deletion and one
predecessor RAM patch. Repeating up to N makers gives a bounded O(N^2) schedule.
The output sink may pause forever, so only always-ready internal work is bounded.
