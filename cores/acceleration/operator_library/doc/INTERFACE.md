# Common interface: `enabled-ready-valid-32x3-v1`

Every core in this catalog is a `acc_<name>` module with exactly this port set:

| Port | Direction | Width | Meaning |
| --- | --- | --- | --- |
| `clk` | in | 1 | single clock domain |
| `rst_n` | in | 1 | asynchronous active-low reset |
| `clk_en` | in | 1 | clock enable; a beat happens only when it is high |
| `in_valid` | in | 1 | `a`, `b`, `c` carry an accepted operand triple |
| `in_ready` | out | 1 | `clk_en && (!out_valid \|\| out_ready)` |
| `a`, `b`, `c` | in | 32 | operand triple, interpreted per core |
| `out_valid` | out | 1 | `result`, `aux`, `fault` hold a response |
| `out_ready` | in | 1 | consumer accepts the response |
| `result` | out | 32 | primary response |
| `aux` | out | 32 | telemetry: echoes, flags, intermediate fields |
| `fault` | out | 1 | this response reports malformed input or a saturation it had to apply |

## Rules

- A transaction is accepted on a rising `clk` where `clk_en && in_valid && in_ready`.
- Only accepted transactions update state. Ignored or unaccepted beats change nothing.
- While `!clk_en`, outputs and state are frozen: no accept, no retire, no state update.
- Reset clears a pending response and all state, even while `clk_en` is low.
- Latency is declared in *enabled* edges (`latency_enabled_cycles` in the manifest) and
  is the number of enabled beats from accept to `out_valid` for that response.
- II is 1 enabled beat whenever `out_ready` is held high (`initiation_interval_enabled_cycles`).
- `fault=1` never means "hang": the core still returns a response, with `result`/`aux`
  defined by the core's own spec (usually zero for malformed input, clamped for saturation).

## Core specification conventions

- Signed fields are two's complement and are named by their bit slice, e.g. `a[11:0]`.
- Bits a core does not read are stated as don't care; bits a core *validates* are
  listed with the exact malformed rule (`result=aux=0, fault=1, state kept`).
- `c[31]` is the restart/seed control bit for stateful cores.
- Requantising shifts are runtime fields (`c[7:4]` and friends), so one core serves a
  family of formats instead of one hard-wired scale factor.

## Vector and coverage gates

Per core, `tools/generate.py` writes `<name>.mem` rows of
`(a<<129)|(b<<97)|(c<<65)|(r<<33)|(x<<1)|f` and fails closed unless the first 128 rows
(the board set) contain at least 96 distinct `(result, aux, fault)` responses, at least
two fault rows (unless the core is declared `faultless`), and for a stateful core at
least one `c[31]=1` restart row.

## Board harness

Groups of at most 8 cores share one bitstream; the harness selects the unit with
`addr[9:7]` and the row's low two address bits set a hold pattern, so back-pressure is
exercised on silicon. One report line per run, 115200 8N1:

```
A25 G=<group> M=<pass_mask> E=<errors> N=<count> D=<digest> L=<max_latency> S=<stalled_beats>
```

`count`, `digest`, `max_latency` and `stalled_beats` are computed analytically from the
declared latencies, so silicon, simulation and the independent Python model are three
separate checks of the same numbers.
