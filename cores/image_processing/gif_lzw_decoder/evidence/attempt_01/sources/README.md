# GIF-LZW image-data decoder

This core accepts the actual GIF image-data section: the minimum-code-size
byte, every sub-block length and payload byte, and the final zero-length block.
It emits real 8-bit color indices in decoded stream order. GIF interlace pass
order is preserved. Palette interpretation, image geometry and container
records belong to the caller.

Current status: **RTL_CANDIDATE, HW_UNVERIFIED**. Numerical preparation,
oracle verification, lint and simulation are NOT_RUN until separately
authorized. No synthesis, PnR, STA or board evidence is claimed.

## Packet and completion

One clock, synchronous active-high reset, ordinary ready/valid, no CE or CDC.
The first accepted byte is the minimum code size, legal from2 through8.
`s_last` must be asserted exactly on the final zero sub-block length byte.
Every other byte has `s_last=0`. The first byte's tag owns the complete packet;
later tags are ignored. `s_bad` marks an upstream byte error. A source holds
all input fields until acceptance or reset.

The index stream has no LAST signal. A separate held completion carries
`done_errors`, the number of **retired** indices, the original minimum-size
byte and the first tag. All index transfers retire before completion becomes
valid. The caller commits a complete image only after a successful completion
and a count matching its expected pixel count. An error can follow an already
published prefix; that prefix must not be treated as a complete image.

Output fields remain stable while stalled. Pending data and completion block
new input. Following completion retirement, the next packet can first accept
on the following edge. Reset immediately masks input ready and both output
valids, then cancels ownership on its edge. RAM and invalid payload registers
are not reset. A canceled packet may be dropped and a complete fresh packet
starts with a new minimum-size byte.

Missing input or missing `s_last` waits without a protocol timeout. External
source/sink stalls have no unconditional wall-clock bound.

## Exact GIF behavior

Codes are packed least-significant-bit first across sub-block boundaries.
Codes start at minimum+1 bits and grow through12. CLEAR is read using the
current width, then resets dictionary allocation, previous-word ownership and
width; it preserves the unconsumed bits of that payload byte. Initial dictionary
state also permits a first literal without an initial CLEAR. Repeated CLEARs
and an empty decoded stream ending at EOI are supported.

Each new word is previous-word plus the current word's first byte. The only
not-yet-allocated data code accepted is `code==next_code`, with a previous word
and available dictionary space: the exact KwKwK case. EOI ends code decoding;
unused bits and remaining payload bytes are ignored. The decoder still checks
sub-block lengths until a zero terminator carrying `s_last`. Arbitrary padding
bits, remaining bytes in that sub-block and further nonempty sub-blocks after
EOI are allowed. EOI is required before the zero terminator.

At next_code4096 the dictionary remains frozen and code width stays12 until
CLEAR. A full dictionary does not require immediate CLEAR. No hidden answer
table, host dictionary or predecoded code is an input.

## Errors and bounded count

|Bit|Meaning|
|---|---|
|0|Minimum code size outside2..8|
|1|Unallocated/illegal LZW data code|
|2|Premature block terminator, packet truncation or misplaced s_last|
|3|Accepted upstream s_bad|
|4|Output count would exceed the COUNT_W representation|

The first detected error stops new code expansion and output publication;
remaining packet bytes drain until `s_last`. Later `s_bad` is still accumulated.
Other syntax checks do not continue in this drain mode. On the first byte,
minimum, last and upstream violations are recorded together. In byte-fetch
and post-EOI skip states, upstream error takes precedence over format checks
on that same byte. On the final byte its upstream bit is registered before
the held completion becomes valid.

COUNT_W is1..32, default32; TAG_W is1..32, default8. A maximum count is legal.
Attempting to publish the next index sets LIMIT without wrapping the count or
publishing that index. Already retired indices remain counted; a held index
is never canceled by a later input error because input acceptance is blocked
through its retirement. Default32 can represent every GIF image pixel count
through65535*65535. Smaller widths deliberately bound the accepted index count.

## Architecture and verification plan

Two independent single-port synchronous memories hold4096 packed20-bit
prefix/suffix entries and4096 reverse-stack bytes:114688 logical RAM bits.
Neither memory nor read-q is reset. Each CLEAR changes only ownership scalars;
every dictionary entry read belongs to the newly allocated prefix range.
See COST.md for prefix/stack proofs, widths and paper work counts.

The finite plan uses three (COUNT_W,TAG_W) profiles: (4,1),(16,8),(32,32).
It fixes38 main packets, each run with continuous and stalled consumers,
and24 reset predicates, each followed by a complete fresh packet and summary.
Twenty child slots cover the independent stored-fixture oracle, tool version,
two lints, three compiles, six main simulations, three reset simulations and
four named invalid-parameter rejections. Every child has a20-second process-tree
limit; the first failure or timeout stops with later slots NOT_RUN. No adaptive
split, automatic retry or relaxed numerical comparison is permitted.

Two hand-derived bit-width boundary certificates are retained independently
of the encoder and decoder. Source sealing and all numerical/tool execution
require the root's separate exact-source authorization.
