# Architecture and numeric budget

The required result is one fractional peak per frame. A standalone three-bin
operator would require the caller to find and supply the peak; a running
argmax with retained neighbors would duplicate existing search behavior.
This implementation reuses canonical `peak_search` for the actual selection,
stores the frame once, and fetches the selected triplet through one synchronous
RAM read port. Candidate powers outside the configured band are masked to zero.
When the returned maximum is zero, the configured low endpoint supplies the
earliest in-band zero. Positive ties inherit the old earliest-index semantics.

Collection accepts one power per clock. Readback uses separate issue/capture
states for L,C,R. One arithmetic state registers D=R-L (signed33), K=2C-L-R
(signed34) and denominator2K (signed35). A qualifying local maximum satisfies
K>0 and |D|<=K, hence |D/(2K)|<=1/2. Unchanged `fp_div_iter` AW33/BW35/FB16/
OUT18 performs a single RNE quotient; maximum numerator shift uses49 bits.
No intermediate power or difference truncates, and no output saturation is
reachable for a qualified peak. One offset addition forms the Q16 position.
Nonqualifying cases skip division and preserve the integer location.

There is one logical32-bit-wide RAM:1KiB at default256 bins and16KiB at4096.
No payload reset, simultaneous read/write or multiple read ports are required.
The power core contains no multiplication operator. The real I/Q chain adds
the old two signed16 squares and four-stage globally stalled pipeline; these
operators may map to DSPs, and no DSP count or removal has been measured.
The divider costs49 recurrence clocks and one transaction slot; it is shared
over the frame rather than replicated per bin. A conservative always-valid,
always-ready command-to-response-transfer budget is N+80 clocks for the power
core and N+84 for I/Q. Gaps and unbounded response stalls add elapsed cycles;
the next frame waits for response retirement and configuration. An upstream
FFT unable to honor ready requires a separate frame buffer.

Qualitative resource/timing risk is MEDIUM: RAM inference, signed35 trial
subtraction, curvature add/subtract and ready routing require implementation
evidence. This is an architecture budget, with no LUT/FF/DSP/Fmax/power, STA,
board-fit or measured sustained-sample-rate claim.
