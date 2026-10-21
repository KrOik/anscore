# External design checks

Read on 2026-10-18:
https://raw.githubusercontent.com/scipy/scipy/v1.14.1/scipy/signal/_signaltools.py

The lfilter documentation explicitly defines numerator feed-forward terms minus
denominator feedback terms, divided by a[0]. The biquad here follows that sign
convention with implicit a0=1. SciPy uses direct form II transposed; this RTL
uses direct form I and quantized, saturated feedback, so floating-point SciPy
results are not a bit-exact reference. No SciPy implementation code is copied.
The independent Python integer model defines the actual fixed-point contract.

Local read-only references: cores/signal_processing/dsp/src/fir16.v and
cores/signal_processing/transforms/src/cic_dec8.v. These implement a fixed unsigned folded FIR
and fixed three-stage RATE=8 CIC respectively. New cores add signed/runtime
coefficient FIR and biquad, parameterized CIC, and explicit stall/packet rules.

CORDIC reference read on 2026-10-18:
https://github.com/ZipCPU/cordic/blob/master/rtl/cordic.v

Checked its signed shift/add rotation recurrence and phase-sign direction.
Its angle convention uses full-turn binary phase; this new module uses Q14
radians and independently generated atan constants, with iterative execution
and vectoring as well as rotation. No upstream RTL is copied. Local read-only
reference `cores/signal_processing/dsp/src/cordic.v` uses Q14 radians in a pipelined design;
the new entry has widened outputs and explicit CE/backpressure semantics.

Rational resampling reference read on 2026-10-18:
https://raw.githubusercontent.com/scipy/scipy/v1.14.1/scipy/signal/_upfirdn.py

Checked its documented zero-insertion, FIR, decimation definition and polyphase
factorization discussion. RTL uses phase-relative coefficient indices, whereas
the Python oracle explicitly inserts zeros and performs full convolution. No
SciPy implementation code is copied; fixed-point rounding and packet metadata
are defined locally. Filter coefficients remain user-supplied rather than
claiming universal anti-alias performance from arbitrary coefficients.

FFT definition reference read on 2026-10-18:
https://raw.githubusercontent.com/numpy/numpy/v2.1.0/numpy/fft/__init__.py

Checked the negative forward exponent and default backward normalization:
forward unscaled, inverse divided by N. No NumPy code is copied or required by
the tests. The accuracy oracle computes the direct complex DFT using Python's
standard library. Read-only local reference `cores/signal_processing/transforms/src/fft64.v`
demonstrates synchronous RAM sequencing, but has a different scaling/rounding
contract and is not used as the new core's golden model.
