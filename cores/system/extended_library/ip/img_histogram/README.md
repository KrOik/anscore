# gw2a_w2_img_histogram

256-bin image histogram with backpressured clear.

- Wraps `st_img_histogram` (selftest cell; core `img_histogram`)
- Sources: `src/img_histogram.v, src/st_img_histogram.v, src/w2_dpram.v, src/w2_img_stim.v`
- Golden digest (FNV-1a): `F14561DD`
- Limitation: Histogram clear introduces backpressure between frames.

## Protocol

unit selftest contract: pulse start (1 clk_en beat) after rst_n; cell runs its internal stimulus against the embedded DUT and raises done; pass==1 iff the FNV-1a digest equals the golden value and all output bytes matched the golden dump.  Verdicts use === so X cannot fake PASS.  Tie clk_en=1 for full rate.

## Ports

| port | dir | width | note |
|---|---|---|---|
| clk | in | 1 | system clock |
| rst_n | in | 1 | active-low async reset |
| clk_en | in | 1 | step enable; tie 1 |
| start | in | 1 | 1-beat run pulse |
| done | out | 1 | selftest finished |
| pass | out | 1 | digest + dump matched golden (=== checked) |
| digest | out | 32 | FNV-1a of DUT output stream |
| cycles | out | 16 | elapsed clk_en beats |
