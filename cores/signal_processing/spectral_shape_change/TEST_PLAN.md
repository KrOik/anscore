# Prospective finite qualification

Status SOURCE_ONLY / NOT_RUN. Nothing in this file authorizes execution.

| Profile | MAX_BINS | TAG_W | Actual input | Planned model cases |
|---|---:|---:|---|---:|
|core_min|1|1|unsigned32 power|25|
|core_odd|7|8|unsigned32 power|49|
|core_max|256|32|unsigned32 power|49|
|iq64|64|8|signed16 real+imaginary through real mag_squared instance|41|

The model directly normalizes each spectrum into Python Fraction masses, sums
absolute differences and divides by two. It derives raw U from this independent
rational result and the unrounded total product. Python's Fraction rounding
provides the independent nearest-even reference. The model maintains logical
adjacent reference state rather than emulating banks, RAMs, helper handshakes,
multiplier products, divider iterations or controller states.

Every profile has one isolated archived model preparation, with no runner model
import and no regenerated numerical data during HDL. Four preparations precede
three syntax children (minimum core, maximum core, actual example) and eight
compile/simulation children. Commands are explicit and fully pinned in the plan.
No inherited regression, synthesis, placement, timing or hardware tool is planned.

Fixture sequences cover:

- First zero frame, both zero, zero-to-positive, positive-to-zero and recovery;
  successful zero frames remain genuine references.
- Independent per-frame gain, uniform/impulse and disjoint supports, identical
  powers, explicit restart, changed length and returning length.
- Zero/over-capacity/full32-bit length rejections and proof that old history
  survives command rejection.
- Early LAST, missing LAST, invalid-input priority and required WARMUP afterward.
- Every unsigned32 extremum and actual signed16 I/Q minima; deterministic full
  input-range pseudorandom spectra.
- For power profiles with capacity>=2: exact half-LSB ties0.5/1.5/2.5, both sides
  of half-LSB and a distance below one that rounds to unity.
- For capacity>=4: AABB versus ABAB, exposing temporal-order differences hidden
  by per-bin first/second moment summaries.
- Actual I/Q phase-invariant powers and both signed real/imaginary lanes.

The TB parses immutable prepared tuples, compares every result field, mutates
command fields after actual command acceptance and inserts deterministic input
gaps. Drivers hold payload until a real rising-edge handshake. Every command,
input, result and internal-state wait is bounded with case/state context, plus
a finite global watchdog. It verifies consecutive input fires for capacity>1.

Each summary is held for five clocks while command/input are offered. Full output
bundle, reference bank, total and length must remain stable; neither input may
transfer. Only actual summary retirement switches the bank. The TB checks commit,
bad-command preservation and damaged-frame invalidation immediately afterward.

Eight cancellation probes reset during partial capture, RAM response, first and
second per-bin multiplication, denominator multiplication, division, held result
and error flush. Each probe has one prepared-by-construction constant reference,
one cancelled command and two exact constant recovery frames. An additional
forced divide-zero response checks ARITH flushing followed by WARMUP and valid
normal recovery. These constant reset/recovery checks do not call the model or
generate additional numerical fixtures.

Expected per profile: `results=cases+28`, `holds=5*results`, resets9,
cancellations8, arithmetic-fault recoveries1. Core minimum has no multi-bin
continuous-input requirement; other profiles must exercise at least one pair of
consecutive accepted inputs. Four profile case totals are164; numeric+recovery
results total276, held observations1380, cancellations32 and resets36. These
are planned counts and are not execution evidence.

Every started child uses20s including spawn and PID persistence. A live tree is
terminated by an independently bounded5s taskkill helper, followed by the sole
2s target-exit observation. BaseException paths still issue independent nonwaiting
helper/target kills. Child raw files, immutable initial record and terminal record
are retained before interpretation; failure stops all later launches and retains
images and partial outputs. No automatic retry exists. Before a simulation Popen,
the initial record contains the just-rehashed compiled image SHA256 and explicit
execution_image_prechecked=True; this record is fsynced and indexed durably.
