# Contrast autofocus controller

`contrast_af_controller.v` implements a real bounded contrast-based autofocus
search using an external per-frame focus metric and lens actuator adapter.
It is a controller, not just a focus statistic calculator. No equivalent
controller was found by searching existing image/ISP RTL; existing focus
statistics can supply its metric input. It does not implement PDAF, image
statistics extraction, sensor transport, or a lens electrical driver.

## Search policy

A `start_valid && start_ready && ce` transfer atomically latches all settings.
The coarse scan visits cfg_min, cfg_min+cfg_coarse_step, ... and cfg_max
exactly (the upper boundary is always included). Every position is commanded
and acknowledged before frame measurement. After the coarse scan, the fine
range is [coarse_best-coarse_step, coarse_best+coarse_step], clipped to lens
bounds. Fine sampling starts at its lower bound with cfg_fine_step, always
including its upper bound. The best **coarse** measurement is retained while
fine measurements compete, so a fine lattice that misses the coarse peak
cannot make the result worse. Higher score wins; exact ties choose the lower
lens position. Flat scenes therefore terminate deterministically. The winner
is commanded once more to park the lens; completion waits for its actuator
acknowledgment and configured settling frames.

Each position discards cfg_settle_frames accepted frame metrics after lens
ack, then sums cfg_samples accepted valid metrics. Every candidate uses the
same sample count, so sum comparison is exactly mean comparison without a
hardware divider. `result_score` is this **sum**, width METRIC_W+8;
`result_samples` supplies the divisor for a host mean. A noise-sensitive
scene may require a larger sample count. Coarse/fine contrast search can
miss narrow peaks between coarse samples; this is an explicit search
resolution choice, not a guaranteed global continuous optimum.

## Interfaces and sequencing

Parameters POS_W=2..16 (default 12), METRIC_W=2..32 (default 24).
Configuration legality:

- cfg_min <= cfg_max, inclusive actuator range; singleton ranges are legal.
- coarse_step and fine_step are nonzero; fine_step <= coarse_step.
- cfg_samples=1..255, settle_frames=0..255.
- cfg_metric_min <= cfg_metric_max, inclusive acceptable measured metric.
- cfg_timeout_cycles counts enabled waiting clocks; zero disables timeout.

`act_valid/act_ready/act_position` is a held lens move request. After its
transfer, the actuator must return exactly one ack_valid/ack_ready response
with ack_position equal to the requested position, or ack_error. It should
ack only once the commanded mechanical move is complete. Frame pipeline
latency after that event is handled by settle_frames. Old metrics received
while waiting for a command or acknowledgment are drained and counted as
dropped; they cannot contribute to a position score. The input metric is
one complete-frame statistic per transfer, never an individual pixel. Its
producer must obey backpressure and preserve frame ordering. A pipeline
with extra old frames must configure enough settling drops.

`busy` covers search, final parking, and pending result. start_ready is low
throughout busy; mid-search start/config changes cannot alter the active
search. `result_valid` holds position, score, sample count, and error until
result_ready. `positions_measured` counts scored coarse/fine visits (including
repeated positions); `frames_dropped` counts drained and settling metrics.
No new search starts until the prior result drains.

All transfers use **ce && valid && ready**. CE=0 freezes state/output payload;
act_valid/result_valid may stay high. Upstream/downstream must observe this
CE-qualified contract. Both request and result payloads stay stable under
backpressure. Active-high synchronous rst overrides CE, aborts work and
clears outputs/errors/counters. `abort` cancels a busy search and produces
error 5; a canceled actuator valid may deassert without a transfer. An
actuator already moving must be stopped/handled by its external adapter.
Results already pending are preserved; abort while idle does nothing.

Terminal error codes (result_valid always follows an error):

| code | cause |
|---:|---|
| 0 | completed and parked successfully |
| 1 | illegal configuration; no lens command issued |
| 2 | actuator reported an error |
| 3 | acknowledgment position differs from command |
| 4 | a scored metric is outside configured bounds |
| 5 | aborted |
| 6 | enabled-clock timeout waiting for request acceptance, ack, or metric |

Timeout restarts on each accepted command/ack/metric as applicable; it is
not an overall search deadline. Consumer stalls on result never time out.
Scores/positions on failed runs are diagnostic only; error_code is required.

## Verification and isolated resources

```
python -B cores/system/common_scaffold/image/autofocus/test_autofocus.py
python -B cores/system/common_scaffold/image/autofocus/synth_autofocus.py
```

The independent Python oracle enumerates physical lens scan coordinates,
evaluates external curves, and chooses peaks. The SV loop models actuator
command acceptance, delayed acknowledgments, two frames of stale statistics
after each move, and position-specific noisy metric samples. Nine cases cover
parabolic, flat, double-peak, left/right boundary, noisy, singleton, unaligned
bounds and a sharp coarse winner absent from the fine lattice. It checks the
entire command sequence, score, parking position and measured-count against
the oracle, with random CE/actuator/metric stalls. Busy config mutation,
held result stability, invalid range/steps/sample/metric settings, all six
terminal errors, reset abort and illegal static parameters are exercised.
Small JSON results remain; temporary binaries/fixtures are automatically
removed.

Isolated `synth_gowin` (no family/P&R):

| POS_W / METRIC_W | LUT1-4 | ALU | FF | DSP / RAM |
|---|---:|---:|---:|---:|
| 6 / 16 | 427 | 315 | 331 | 0 / 0 |
| 12 / 24 | 551 | 414 | 419 | 0 / 0 |

MUX5 counts are separate in synthesis_result.json. This is simulation and
isolated mapping evidence; no physical camera/lens or board timing validation
has been performed.
