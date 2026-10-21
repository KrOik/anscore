# Boundary proof scope

Run from repository root:

```powershell
python cores/system/utility_library/tools/formal.py
```

Uses the local Yosys SAT engine; no SymbiYosys or solver installation is needed.
It elaborates each real RTL kernel, flattens it, converts asynchronous reset
for a discrete transition model, and proves assertions through **eight** steps
with initially zero registers. Inputs are unconstrained, including reset,
valid, ready, CE and operands. The harness asserts that in_ready requires CE,
and that an existing pending response cannot change under output backpressure
or a CE pause while reset remains inactive.

These are bounded handshake assertions. They are not induction, unrestricted
liveness, arithmetic functional equivalence, analog reset recovery, CDC,
glitch-safety, security, side-channel, or product certification proofs. Reset
clearing and functional results are covered by separate simulation tests.
The literal per-core harness, exact Yosys commands, full logs, source SHA256
and individual results are preserved in a timestamped evidence directory.
