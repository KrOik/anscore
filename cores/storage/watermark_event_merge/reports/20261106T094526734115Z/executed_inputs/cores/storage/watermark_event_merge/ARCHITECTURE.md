# Architecture decision and boundaries

The target is modest-rate deterministic event replay/control, with full exact
metadata and safe silence handling. A comparator tree over wide resettable
payload registers would enlarge reset/mux paths and duplicate the existing
temporal-minimum service. A sorted fixed frame merge cannot represent unknown
future input from silent open feeds. The selected architecture time-shares the
existing exact keyed calendar and adds only source-safety ownership and RAM
payload retention. No multiplier, divider, DSP, CDC or vendor primitive is added.

Calendar rows are `{live1,feed32,time64,sequence64}`,161 bits/feed. Feed metadata
RAM stores `{previous_time64,previous_sequence64,watermark64}`,192 bits/feed.
Head payload RAM holds DATA_W exact bits/feed. Together declared RAM payload is
`FEEDS*(353+DATA_W)` bits:1924 default,6920 maximum. Four FEEDS-bit bitmaps guard
heads, closed feeds, previous metadata and watermark metadata; head count uses
clog2(FEEDS+1). RAM rows have synchronous reads and one read/write port, with
phases disjoint. Unknown write response old-data is ignored. No full RAM reset
or asynchronous array-wide read is required. Small memories may map to registers;
physical mapping/fit/frequency/power remain UNKNOWN. Structural risk is LOW at
default, MEDIUM at maximum due to wide payload routing/banking and serialized
calendar service. Scalar command, response and RAM pipeline registers are not
counted as RAM; wide scalar payload registers preserve the owned transaction.

EVENT validates existing scalar flags and one metadata read, writes metadata,
writes payload, then UPSERTs exactly the formerly absent feed ID into calendar.
Only a confirmed new insertion marks its head visible. A backend fault invalidates
the epoch because some private writes may already exist. WATERMARK only writes
metadata after a nondecreasing check. EOS changes one closed bit and retains its
head. CLEAR first drains the calendar's complete clear response, then invalidates
all metadata. Payload from invalid rows is never published or compared.

POP NEXT is read-only. Its exact feed/time/sequence are captured. A serial feed
scan skips feeds with heads or EOS; other feeds require a valid watermark read
strictly above candidate time. WAIT mutates nothing. After proof, the candidate
payload is read and captured, and TAKE uses the captured time as its inclusive
cutoff. The unchanged owner guarantees its minimum cannot change between NEXT
and TAKE. Returned ID/time/sequence and live/free counts are checked. Head removal
becomes public only after confirmed TAKE. A held result has no new source owner.

For fixed F, each calendar operation scans F rows in2F read/consume cycles plus
constant control. POP uses two scans and up to F serial metadata decisions, plus
one payload read. A conservative first-result-valid bound is **8*F+24** cycles
(56 default,88 maximum), excluding initial calendar reset erasure. Input/output
stalling and response retirement add separately; no unconditional retirement
deadline exists. This is a source-structural bound to be checked by the frozen
finite TB, not a measured hardware rate or claim of one event per cycle.

Safety proof: a candidate is the minimum of every currently buffered head.
For any missing open feed, every future accepted event has time>=W>candidate.
Closed feeds supply none. A present feed's future events follow its head in
nondecreasing timestamp and strictly increasing sequence order. Repeating this
argument after each POP yields globally nondecreasing time with deterministic
feed-ID tie priority. After popping a lower-ID tied head, that feed becomes
missing and blocks higher-ID ties until its next head, strict progress or EOS;
therefore arbitrarily many equal-time events do not invert the tie rule.

The watermark is a producer promise, not a fact inferred by the core. A producer
must not omit earlier events then advance its promise. Rejecting a late attempted
event preserves state but cannot recover something already released on a false
promise. No timestamp-only mechanism proves packet loss recovery, authentication,
exchange completeness, wall-clock pacing, fairness or distributed failure policy.
