# gw2a_sig_hist256

256-bin histogram over 8-bit samples for Gowin GW2A-18. Counts live in one
BSRAM (18-bit x 256 simple dual-port) and are updated by a two-beat
read-modify-write. 0 DSP.

## Interface

| Signal | Dir | Width | Description |
|---|---|---|---|
| `clk`/`clk_en`/`rst_n` | in | 1 | clock, clock-enable, async reset |
| `start` | in | 1 | begin a new frame: clears all 256 bins and `total` (256 `clk_en` beats, `busy=1`) |
| `busy` | out | 1 | high during the clear sweep; ignore `in_valid` while busy |
| `in_valid`/`bin` | in | 1/8 | accumulate one sample per `clk_en` beat |
| `total` | out | 24 | number of samples accumulated since `start` |
| `rd_en`/`rd_addr`/`rd_data` | in/out | 1/8/CW | readout port; `rd_data` valid one `clk_en` beat after `rd_en` |

`CW` (default 16, max 18) sets the per-bin count width.

## Same-bin hazard

A bin write commits on the same edge that the next sample's synchronous read
captures, so a naive design would lose one count on back-to-back identical
bins. A 1-deep forwarding register replays the last committed `(addr,count)`
whenever the current bin matches; because it is always the most recent write,
forwarded data always equals RAM content. Arbitrary same-bin runs (including
fully back-to-back) count correctly — covered by the self-test stimulus.

## Readout latency

`rd_data` is the registered BSRAM output: drive `rd_en`+`rd_addr`, sample
`rd_data` on the next `clk_en` beat. `rd_en` may be pipelined with `in_valid`
(read address wins only when `in_valid=0`).

## Validation

- FNV-1a digest of the full 256-bin image vs golden dict model: `C4B4F3D5`.
- Verified in `sim/tb_sig_selftest.v` and on board.
