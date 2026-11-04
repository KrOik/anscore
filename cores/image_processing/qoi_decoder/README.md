# Whole-file-validated QOI to RGBA decoder

`qoi_decoder` consumes an actual complete Quite OK Image file as bytes and
returns its exact8-bit RGBA raster. It implements the14-byte header, all six
chunk families,64-entry color history, wrapping channel differences, bounded
runs and the8-byte ending. It does not consume host-decoded pixels or prebuilt
image outputs. The whole file is validated before any pixel becomes public.
This adds a compact lossless image interchange codec, distinct from the existing
PNG/DEFLATE, JPEG/IDCT, RAW sample packing and binary-run token services.

## Accepted format and strictness

Header magic is `qoif`. Width and height are unsigned32-bit big endian, nonzero
and independently bounded by MAX_WIDTH/MAX_HEIGHT. The complete32-bit fields
are checked before narrowing; high bits cannot alias a small valid dimension.
Channels must be3 or4 and colorspace0 or1. Output always preserves four decoded
channels in `{R,G,B,A}` order. The channels field remains metadata: an RGBA chunk
in a channels3 file is accepted and its alpha retained. Colorspace is reported
without gamma/color conversion, and alpha is unpremultiplied.

The previous pixel starts `(0,0,0,255)`. The64 index entries start logically
`(0,0,0,0)`, including transparent alpha. Each committed decoded pixel updates
slot `(3R+5G+7B+11A) mod64`; hash collisions overwrite the old entry. An untouched
index entry returns transparent zero, regardless of unreset physical RAM bits.
INDEX uses its6-bit slot; DIFF applies three biased2-bit channel differences;
LUMA applies biased green and red/blue-minus-green differences. All RGB channel
arithmetic is exactly modulo256. INDEX loads all four channels from the selected
entry; RGB/DIFF/LUMA/RUN preserve previous alpha; RGBA replaces it explicitly.
The eight-bit FE/FF tags take
precedence over the two-bit classes. RUN expands1..62 copies of the previous
pixel. FE/FF are RGB/RGBA tags, never63/64-pixel runs.

Every declared pixel must be produced, no run may overrun that count, and exactly
the seven zero bytes followed by01 must remain after the pixel data. Missing,
extra, truncated or altered endings fail; chunk/literal fetches cannot consume
the reserved final eight bytes as payload. Consecutive INDEX chunks referring
to the same slot are rejected, following the format's valid-encoder restriction.
All256 opcode byte values have defined chunk meanings; there is no invented
unknown-opcode fallback. No checksum is part of QOI decoding.

The pinned C reference is deliberately more permissive about malformed/truncated
files, run completion and ending bytes. This package implements the explicit
acceptance rules above; it does not claim identical malformed-input acceptance
or reuse the upstream decoder's unchecked reads. Valid pixel decoding follows
the published QOI format exactly, without approximate arithmetic.

## Byte and raster transactions

One rising-edge clock, synchronous active-high `rst`, ordinary ready/valid and
no CE. A transfer occurs exactly on `valid && ready`. A CE-qualified neighbor
requires an explicit adapter; no CDC or clock gating is hidden in this core.
`s_byte` supplies one whole file, with `s_last=1` on its final byte. Every file
contains at least one token; a one-byte invalid file represents an empty/truncated
byte object at this interface. The first accepted byte's `s_tag` owns the whole
result, even if that byte is invalid. Subsequent tags are ignored. The source
holds byte, last and tag stable while valid and blocked. A missing last waits
for more bytes or reset; there is no input-length watchdog.

Capture accepts II1 and retains at most MAX_BYTES bytes. Excess bytes latch
overflow and drain through last, without wrapping memory. Parsing and output
block all further input. New input may transfer on the clock after the final
output token retires. One file owns the core through its complete result.

Success emits width*height pixels in row-major order. `m_x/m_y` are zero-based;
SOF marks pixel0, EOL each row end, LAST only the last pixel. Width, height,
channels, colorspace, status, captured byte count and first tag repeat on every
pixel. Width/height are32-bit values checked against the declared bounds; x/y
use max(1,clog2(MAX_WIDTH/HEIGHT)) bits. `m_bytes` is
clog2(MAX_BYTES+1) bits and equals the saturated retained byte count. Every result
field and valid remain stable under output backpressure. Fields are meaningful
while valid. Pixel replay has an always-ready II of3 clocks, not a camera-rate
one-pixel-per-clock promise.

Every failure emits exactly one held response with RGBA, coordinates, dimensions,
channels and colorspace zero, SOF=EOL=LAST=1, nonzero status, retained bytes and
first tag. No provisional prefix pixels escape. Status codes are:

| Status | Meaning |
|---:|---|
|0|Complete validated image|
|1|Captured file exceeded MAX_BYTES; takes precedence over parsing|
|2|Bad magic, dimensions, channels or colorspace|
|3|Insufficient file/header/chunk/literal bytes while reserving the ending|
|4|Run exceeds the remaining declared pixels|
|5|Wrong ending bytes or wrong exact remaining/consumed file length|
|6|Consecutive identical INDEX chunks prohibited by the format|

Checks occur in the stated parser order, not by collecting all possible errors.
For example removing a final byte can make the preceding literal appear to lack
payload before an ending check is reached, giving status3. Success can have
transparent alpha, and even an all-transparent raster is not an error.

Reset immediately gates public ready/valid and markers low. At its rising edge
it cancels capture, parsing, expansion and held output, zeroing scalar/public
state and index validity. Byte/pixel/index RAM and their read registers are
unreset. Every byte read belongs to the freshly captured prefix, every replayed
pixel was decoded in this transaction, and valid bits guard index RAM use.
The next first-byte transfer initializes previous pixel and the whole ownership
state. A reset can cancel an already visible result; the caller discards the
aborted file's partial raster and replays it if required.

## Parameters, storage and cycle bounds

|Parameter|Default|Legal range|
|---|---:|---|
|MAX_WIDTH/MAX_HEIGHT|8/8|each1..16|
|MAX_BYTES|342|27..1302, independent of the geometry bounds|
|TAG_W|8|1..32|

Named elaboration rejections cover illegal public parameters. Let
P=MAX_WIDTH*MAX_HEIGHT, FCW=clog2(MAX_BYTES+1), PIW=max(1,clog2(P)),
PCW=clog2(P+1), XW=max(1,clog2(MAX_WIDTH)), YW=max(1,clog2(MAX_HEIGHT)).
All input/channel quantities are unsigned. There is no fixed-point scale,
resampling, quantization, saturating channel arithmetic or external memory.

Three clocked-read, unreset RAMs hold8*MAX_BYTES file bits,32P decoded pixel
bits and2048 color-index bits. Their logical sum is6832 default /20656 maximum
bits. Capture, parse/commit and replay use disjoint ownership phases; index
lookup and index writes occur on separate edges. Physical BRAM mapping is not
guaranteed. The64-bit validity map clears in one scalar control edge rather
than clearing the64 RAM words.

Declared scalar storage, including all three RAM read registers and public
output fields, is exactly `330+2FCW+2PCW+PIW+XW+YW+TAG_W` bits:
382 default /418 maximum. The330-bit constant includes128 pixel/read-data bits,
64 dimension bits,64 validity bits,16 byte/read bits,24 index/run/luma bits,
10 state/return bits,9 header/literal/tail bits,12 format/status bits and3 flags.
These are source-level logical RAM/scalar counts, not measured FF/LUT/BRAM/DSP
results. The only variable multiply is at most5x5 bits, deriving runtime pixel
count from already validated narrowed dimensions. It cannot exceed256, which
fits PCW. Hashing uses11-bit constant shifts/adds on low6 channel bits; its sum
is at most26*63=1638, and low6 bits are exactly the required mod64 hash.
Eight-bit channel slices intentionally retain modulo256 results. No data-width
divider, modulo network, external primitive or large arithmetic array is needed.

For a valid b-byte file with n pixels and i INDEX chunks, accepted-LAST to first
valid is exactly `5+3b+n+2i` active edges. Each consumed byte uses a synchronous
fetch, latch and dispatch; each pixel one commit, each index two extra read
edges; CHECK/header-finalize/end-verify and first replay add five edges. Thus
`5+3MAX_BYTES+3P` is a conservative whole-domain tail bound:1223 default /4679
maximum. Capture overflow or a file shorter than22 bytes gives first error
valid in one edge. Other errors stop at the failed check; frozen fixtures bind
their exact prefix work and first-valid edge. Source gaps and sink holds are
unbounded external waits and are excluded from this computational tail.
Risk is LOW default /MEDIUM maximum from RAM organization and valid/hash/operand
selection paths. No synthesis, fit, timing, power, board or Fmax claim is made.

## Offline closure and finite evidence

`files.f` lists one production source. `example/files.f` adds only the complete
local default direct instance. There are no includes, ROM coefficients, sibling
HDL, initialization files, vendor libraries or network/runtime decoder needed.
Root LICENSE/NOTICE apply to this original implementation; SOURCES gives the
pinned upstream read-only inspection and semantic dedup boundary.

`TEST_PLAN.json` freezes exact sources, fixtures, profiles, reset IDs and21 child
checks before the first HDL tool: version, two syntax checks, five numeric
compile/simulation pairs and eight named parameter rejects. Numeric profiles
are MAX_WIDTH/HEIGHT/BYTES/TAG=1/1/27/1,3/2/52/3,4/4/102/8,8/8/342/8,
16/16/1302/32. Maximum geometry and exact maximum byte capacity are exercised
numerically with all-RGBA images, not only compiled. The16x16 RGBA image includes
every8-bit value in all four channels. No B19 tools or inherited matrix is run.

An independent original pixel-to-file encoder selects shortest legal chunk
candidates from known RGBA pixels. Expected rasters are those original pixels,
not a decoder emulating hardware states. Hand-derived one-pixel files anchor all
six chunk families, wrap extremes, transparent untouched index slots and RGBA
under channels3. Larger files exercise hash replacement, index reuse, all62-run
boundaries, RGB metadata and deterministic random/repeated pixels. Explicit
malformed files cover every reachable status, high header bits, zero geometry,
all truncated/more-than-exact endings, literal shortage and overflow drain.

TB compares every public output bit, exact prefix fetch/commit/index work and
first-valid time, all state/chunk families, clocked RAM images, current-prefix
ownership, every full arithmetic color hash, initial-zero/hit index selections,
input II1/gaps and every output hold. Each next file's actual first frozen byte
stays offered throughout processing and all output pixels through its own real
acceptance. Immediate observed-state reset probes cover parser, literal subfields,
tail boundaries, valid/invalid index reads, run iterations, capture full/overflow
and held first/final/error output. Every probe is followed by a complete fresh
27-byte RGBA file, exact87-edge decode, all fields, held output, retirement and
no-stale checks. The fixture loader uses scalar fscanf temporaries from its first
version. Single-pixel profiles omit only states/contexts that require2,6 or62
pixels; every basic state and all six chunk families remain covered.

Authoritative status/raw child records are in `verification.json`; hardware
always remains HW_UNVERIFIED. Every compiler/simulator child has a20-second hard
limit. A timeout is terminal: no retry, smaller fixture or larger limit. Ordinary
failure repair must preserve exact original source/plan/receipt and keep the
same matrix. The first attempt stopped at an ordinary core-syntax failure because
the ternary question mark touched a hexadecimal literal. Its exact original
plan, receipt and all nine nonfixture source texts, all14 source hashes and the
complete21-child disposition (two actual records,19 NOT_RUN) are preserved in
`history/attempt_01.json`. The repair adds whitespace and the explicit archived
same-matrix repair gate; it also clarifies the INDEX alpha wording above. No
fixture byte, parameter, check scope or time limit changed in that repair.
The second attempt passed both syntax checks and the smallest-profile compile,
then exposed two incorrect smallest-profile expected records: their28-byte input
exceeds the27-byte capacity, so the documented capacity status1 takes precedence
over ending status5. `history/attempt_02.json` retains the exact failed receipt,
plan and all14 normal source/fixture texts, with the prior history hash. The
coordinator authorized correcting only frames46/47 expected status, work and
latency, their generator branch and related plan statistics/hashes. The complete
input token sequence, length, frame order and output count of every one of the
252 files /12911 input bytes is unchanged across all five profiles. The smallest
fixture's full hash changes because its two expected annotations change; the
other four fixture files remain byte-identical. No RTL behavior changes for this
oracle repair. `TEST_PLAN.json` records the per-profile stimulus hashes and exact
annotation correction. Existing receipt
files block automatic reruns; `--run --repair` requires the exact archived FAIL
receipt and matching immutable matrix, and cannot authorize a timeout retry.
There is no synthesis,
PnR, STA, board run or expanded regression. Owner-only `python run_tests.py
--freeze` prepares/finalizes the matrix before the first attempt; `--run` consumes
it. Repair never regenerates fixtures or reruns the oracle. Read-only peer review
does not invoke either path or the oracle. Any postqualification change must
preserve the tested/current hashes and original evidence rather than silently
reattributing tests.
