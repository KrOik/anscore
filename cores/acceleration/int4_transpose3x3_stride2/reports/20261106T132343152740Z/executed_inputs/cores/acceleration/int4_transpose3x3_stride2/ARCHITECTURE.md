# Architecture before bounded qualification

A direct scatter engine needs wide partial-sum output rows and read/modify/write
hazard handling. The selected polyphase gather computes each final sum once,
with the resident packed matrix and its exact quantizer. At anchor(y,x), the
four source neighbours are current/left/upper/upper-left, and their four phase
weight rows reproduce every one of the nine scatter locations. Appending a
zero row/column supplies the right/bottom contributions; cropping only the last
odd coordinates preserves the full2H+1 by2W+1 result. There is no full-frame RAM.

The two synchronous8-bit input banks each hold W*Cin values. Capture and gather
are mutually exclusive at these banks. Each gathered scalar has one synchronous
read cycle and one held send cycle. A new source row starts only after the child
has retired the preceding anchor row and requests its next vector. This also
protects a held public output from malformed-input flush. Explicit first-row,
first-column and appended-row/column masks prevent reads of stale RAM. Runtime
channel count defines compact row stride, including non-power-of-two geometry.

Child input width is4*Cin<=64; child matrix rows4*Cout<=64. Weight storage,
validity,40-bit accumulation,57-bit scale product and final quantization are
unchanged. The front end adds no multiplication or division operator: pixel
base advances by Cin and left addresses subtract Cin. All legal neighbour
addresses are below W*Cin before AW truncation. No bulk RAM reset is required.

Input row memory is2*Wmax*Cinmax*8:4096bits default,261888bits maximum.
Child lower-row memory is2*(Wmax+1)*Coutmax*10:5200/327680bits. Child packed
weights are1024/16384bits, vector128/512bits, metadata976/3904bits and
validity48/576bits, plus scalar/control registers. Default architectural risk
MEDIUM; maximal aggregate memory risk HIGH. BRAM packing, DSP mapping, area,
Fmax and power have not been measured.

Every anchor sends4*Cin scalars and computes4*Cout rows, including explicit
zero taps. There are(W+1)*(H+1) anchors. The front end contributes at least
8*Cin clocks per anchor for read/send without stalls; matrix precheck/MAC,
quantizer and lower-row replay also impose service time and can overlap some
front-end work. This design makes no II1 or hardware FPS claim. Source gaps,
arbitrary output stalls and held completion have no bounded overall deadline.

Planned finite profiles cover a1x1 scalar shape, multi-channel non-power-of-two
frames,1023-column row fill/replay,16-channel and16-output mixing, all nine taps,
zero points, signed ties, extrema, held outputs/configuration/completion,
missing configuration, malformed markers and live reset/recovery. A direct
scatter-add integer oracle is independent of the RTL's polyphase algorithm.
No oracle or HDL tool has been run during source-only planning.
