# ECC scratchpad with read repair and whole-memory scrub

`ecc_scrub_scratchpad` provides 32-bit word storage with extended Hamming
SECDED protection. It composes the existing `stream_secded_encode` and
`stream_secded_decode` with synchronous 39-bit RAM and an original serialized
controller. Corrected reads repair the stored codeword; byte writes decode
before merging; a scrub command scans every word and reports exact counts.

Current status: **LINT_PASS / UNIT_SIM_PASS / INTEGRATION_CANDIDATE /
HW_UNVERIFIED**. Only the finite checks below were run. No synthesis, PnR,
STA, full regression or hardware test was performed for this composition.

## Parameters and data representation

| Parameter | Default | Legal range |
|---|---:|---|
| `DEPTH` | 256 | 1 through 4096 words, including non-powers of two |
| `TAG_W` | 8 | 1 through 32 opaque command tag bits |

Derived `COUNT_W=max(1,clog2(DEPTH+1))` represents every count from zero through
DEPTH exactly; it is internal, not a public override. Illegal public parameters
fail elaboration through a named unresolved parameter-error instance.

Addresses are unsigned **32-bit byte addresses**, aligned to four bytes.
The legal local range is `0 <= address < 4*DEPTH`. Bounds and alignment are
checked before truncating the internal word index. Raw data has 32 bits,
without signed/fixed-point meaning, rounding or saturation. Strobe bit `b`
selects bits `8*b +: 8`; there is no endian conversion.

Stored codewords contain 39 bits: positions 1..38 map to bits 0..37; powers
of two hold six Hamming parity bits and remaining positions hold data bits
in ascending order. Bit 38 is overall even parity. The code layout matches
the unchanged stream codecs. Zero data encodes as all-zero codeword.

## Clock, reset, CE and ownership

All ports use one rising-edge `clk`. `rst` is **synchronous active-high**, must
span a rising edge, and gates ready/valid low while asserted. There is **no
CE**. Reset cancels any command, pending response and both codec pipelines.
After deassertion the controller overwrites one RAM word with a valid zero
codeword per clock, blocking commands for DEPTH active edges. Thus reset
clears logical memory and discards previous data. The payload array has no
parallel reset tree, and no memory initialization file is required.

A command transfers on `c_valid && c_ready`; hold every command field until
acceptance. A response transfers on `r_valid && r_ready`; all response fields
remain stable while stalled. Exactly one command is active at a time and
commands complete in order. A new command waits for the previous response
to be consumed. There are no packets, stream-last markers, CDC, runtime
configuration registers, external memory transactions or other RAM masters.
Read/modify/write and scrub are atomic with respect to this command port.
Reset publishes no completion for a canceled command and restarts zeroing.

## Commands and responses

| Command | Behavior |
|---|---|
| `c_op=0` | Read one word, returning clean/corrected data and repairing a single error |
| `c_op=1`, strobe `4'hf` | Full overwrite through encoder; no read or old-error classification |
| `c_op=1`, strobe 1..14 | Decode, merge selected bytes, encode and write the complete codeword |
| `c_op=1`, strobe zero | Aligned/in-range no-op; no read, detection or repair |
| `c_op=2` | Scrub every word in ascending address order; address/data/strobe ignored |
| `c_op=3` | Invalid command without RAM access |

Read ignores data/strobe. Alignment and range are validated before a
zero-strobe no-op; an invalid no-op still returns invalid status. The scrub
command ignores even a misaligned/out-of-range address. `c_tag` is returned
unchanged as `r_tag`; it does not select memory or affect ECC.

| Response field | Meaning |
|---|---|
| `r_status=0` | Clean success, full overwrite or no-op |
| `r_status=1` | One or more single-bit errors corrected |
| `r_status=2` | One or more uncorrectable codewords detected |
| `r_status=3` | Invalid operation/address |
| `r_data` | Successful read data; zero for uncorrectable reads and every other command |
| `r_corrected` | Number of corrected codewords in this command |
| `r_uncorrectable` | Number of uncorrectable codewords in this command |
| `r_first_uncorrectable` | Lowest failing **byte address**, meaningful only when `r_uncorrectable!=0` |

Counts describe the current command; there are no lifetime counters. For read
or partial write, each count is zero or one. Scrub counts can reach DEPTH.
Its status is 2 if any uncorrectable word was encountered, otherwise 1 if
any word was corrected, otherwise 0. Invalid/no-op/full-overwrite responses
have both counts and first address zero.

A clean read does not rewrite RAM. A corrected read writes the decoder's
complete corrected codeword, including parity-bit-only repairs, **before its
response is presented**. A corrected partial write merges into corrected
payload, then encodes and commits once; status 1 reports that the old word
needed correction. An uncorrectable read returns zero and preserves raw RAM.
An uncorrectable partial write rejects every selected byte and preserves raw
RAM. A full overwrite always replaces the complete word and all ECC bits,
so it can recover a location without reading its damaged old value.

Scrub continues after uncorrectable words. It rewrites corrected codewords,
leaves uncorrectable codewords untouched, records the lowest uncorrectable
address and emits one summary after the entire sweep. Repeating scrub sees
previously corrected words as clean; uncorrectable errors persist until a
full overwrite or reset. Foreground requests cannot interrupt a sweep.

## Fault boundary and architecture

For a valid stored codeword, any one flipped physical bit among the 39 bits
is corrected; any two distinct flipped physical bits are detected and left
unmodified. Three or more errors can be missed or miscorrected. The controller,
address/control registers and codecs themselves are not fault-tolerant.
This does not provide ECC for an external RAM or coherent shared memory.
There is no production fault-injection port; tests alter RAM hierarchically
only while the controller is idle.

One selected word address drives a synchronous RAM read and all RAM writes.
Initialization, encoded writes and read/scrub repairs share that write path.
The payload array is not expanded into a combinational multiword operation.
The reused encoder has one elastic register stage; the decoder has two.
The wrapper keeps at most one codeword in flight and resets both with its
own controller. No vendor primitive, multiplier, external memory, ROM, package
or generated table is needed. BRAM inference and physical device fit are
unmeasured.

Default RAM capacity is **9,984 logical bits** (256 x 39); maximum is
**159,744 bits** (4096 x 39), excluding controller and codec registers.
Qualitative resource risk is **LOW** by default and **MEDIUM** at maximum
because of memory size/39-bit packing and long sweep occupancy. These labels
are structural estimates, not resource or clock measurements.

From the command-accepting edge, with no reset, a read presents its response
after four periods, a full write after two, and a nonzero partial write after
six when clean/correctable or four when rejected as uncorrectable. Invalid
commands and zero-strobe writes present their response just after acceptance.
Scrub presents its summary after `4*DEPTH` periods, independently of the error
mix. RAM commits occur before/with response presentation. Response backpressure
adds occupancy; the next command additionally waits for response consumption
and return to idle. These are RTL cycle schedules, not measured hardware
rates or an unconditional end-to-end deadline with a stalled consumer.

## Offline use and example

From this package directory:

```text
iverilog -g2012 -Wall -tnull -s ecc_scrub_scratchpad -f files.f
iverilog -g2012 -Wall -tnull -s ecc_ram256 -f examples/files.f
```

`files.f` is the production dependency closure. It references the existing
encoder and decoder RTL in `cores/acceleration`; neither is modified or
downloaded at use time. `examples/ecc_ram256.sv` exposes a 256-word instance,
with its complete closure in `examples/files.f`. The core's finite TB actually
exercises the composed old codecs and new RAM controller. Existing codec
physical/formal history is not a validation claim for this composition.
The two old files have no explicit timescale; Icarus reports this warning
without affecting their delay-free RTL. All testbench delays use 1ns/1ps.

## Finite verification

From the repository root:

```text
python -B cores/storage/ecc_scrub_scratchpad/check.py
```

The standard-library runner prefers the local OSS CAD Suite, supports
IVERILOG/VVP overrides and caps **each child process at 20 seconds**. It
removes its task-specific temporary vectors/images after use. Evidence
records actual commands, outputs, vector hashes and current source/dependency
SHA256 hashes. No synthesis, physical flow or broad regression is started.

| DEPTH / TAG_W | Records including injection/reset | Responses | Stored codewords compared |
|---|---:|---:|---:|
| 1 / 1 | 408 | 353 | 408 |
| 3 / 4 | 6,246 | 5,460 | 18,738 |
| 16 / 8 | 854 | 739 | 13,664 |
| 256 / 16 | 598 | 515 | 153,088 |
| 4096 / 32 | 470 | 403 | 1,925,120 |
| Total | **8,576** | **7,470** | **2,111,018** |

Every profile tests all 39 single-error positions; the depth-3 profile tests
all **741** distinct double-error pairs. The other profiles use 12/64/32/16
deterministic sampled pairs. In total there are 195 single-position trials
and 865 double-pair trials, plus mixed-word and whole-memory injected faults.
Whole-memory single and double faults verify count=DEPTH and lowest address
at maximum parameters. Data patterns, every byte mask, invalid/masked commands,
nonpower-of-two addressing, last local word, tag extremes, source gaps,
response stalls, repeated scrub and reuse without reset are covered.

The independent Python oracle generates parity arithmetically, then classifies
received words by searching for a valid codeword within Hamming radius one;
it does not use the RTL syndrome decoder or controller states. The TB compares
every response and **every raw stored codeword after every vector record**,
including rejected/no-op writes. This checks persistent repair and unchanged
unrecoverable words as well as returned data. Bulk and individual fault
injection and reset are TB vector actions, not hardware commands.

Each profile also interrupts all eight controller states (initialization,
idle, RAM read, decoder send/wait, encoder send/wait, stalled response).
Reset is asserted at the observed current boundary without an extra active
edge. It resets the codec pipelines, verifies the complete zero sweep and
checks a fresh clean read. These are eight finite phase probes per profile,
not exhaustive timing/fault proofs. Four illegal public parameter settings
are rejected. The report has **17** recorded tool invocations.

Provenance, local reuse, external license checks and architecture risks are
recorded in [SOURCES.md](SOURCES.md). All text in this package is LF.
