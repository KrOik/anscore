# Same-row optical-black calibration and crop

`raw_optical_black_rows` estimates black offset independently for the two physical column parities of every sensor row, crops the declared margins, and replays the active pixels with their measured black sideband. `example/raw_ob_black_frontend.sv` connects that stream to the **unchanged** resident `raw_black_level_stream`, which performs subtraction, target addition and saturation.

This adds row-local reference measurement and active crop. The existing common-scaffold `raw_black_level` uses a whole-frame ROI mean for four CFA planes; `raw_black_level_stream` accepts manually supplied offsets. Neither measures same-row margins. For ideal active signal 100 and row offsets 10/30, per-row correction gives 100/100; one frame mean of 20 would give 90/110.

## Sensor and command contract

One clock, ordinary ready/valid, no CE or CDC. A transfer occurs on a rising edge with `valid && ready && !rst`. Public reset is synchronous active-high and cancels the entire frame and any held DONE. The old correction instance internally retains its original asynchronous active-low reset driven by `!rst`; public transfer ports are masked during reset. Hold every source payload while valid and not ready. Payload and metadata remain stable while their valid is held. Unknown four-state inputs are outside the functional contract.

| Parameter | Legal range | Default |
| --- | --- | --- |
| WIDTH, HEIGHT | 1..512 each, product <=65536 | 128, 64 active pixels |
| BITS | 8, 10, 12 unsigned integer RAW | 10 |
| OB_LEFT | 2..32 sensor columns | 8 |
| OB_RIGHT | 0..32 sensor columns | 8 |
| TAG_W | 1..32 | 8 |

Each sensor row is `[OB_LEFT reference][WIDTH active][OB_RIGHT reference]`, starting at physical x=0. Input contains exactly `(OB_LEFT+WIDTH+OB_RIGHT)*HEIGHT` pixels in raster order. SOF is true only on the first sensor pixel; EOL on the last sensor pixel of each row; LAST only on the final sensor pixel. All three are checked on accepted pixels. The caller guarantees that the declared reference margins are **physically shielded optical-black pixels**. Merely selecting dark image columns does not establish that condition.

A command snapshots `c_low`, `c_high`, `c_min_count`, `c_target`, `c_pattern` and full-width `c_tag`. Reference pixels qualify in the inclusive range `[low,high]`. Legal minimum count is 1..32 for **each physical parity in each row**; a legal but unattainable minimum produces a reference-count error. Pins may change after command acceptance. No new command is accepted until terminal DONE is consumed.

Pattern uses the same two-bit Bayer phase convention as the resident correction: plane index is `{y[0] XOR pattern[1], x[0] XOR pattern[0]}`. Cropping removes no rows and changes the phase to `c_pattern XOR {0,OB_LEFT%2}`. Physical-even/odd means are also swapped when OB_LEFT is odd so row_black0/1 correspond to active x even/odd. Metadata x/y are 16-bit active coordinates; tag is never truncated at the public interface.

## Exact arithmetic and row ownership

For parity p, collect qualified references in the current row only. `black[p] = floor((sum[p] + floor(count[p]/2))/count[p])`, nearest-half-up for nonnegative values. Target is not included in reference qualification or estimation. The core outputs **uncorrected** active RAW plus the selected mean; the actual frontend outputs `clamp(raw-black+target,0,(1<<BITS)-1)` with the same mean sideband.

The core has three ordered interfaces for each row:

1. `row_valid/row_ready` transfers black0/black1/target/y/pattern/tag before any active pixel is replayed. The consumer must configure the correction epoch before acknowledging.
2. `m_valid/m_ready` transfers exactly WIDTH cropped raw pixels, with regenerated active SOF/EOL/LAST, coordinates, mean, pattern and tag.
3. `row_end_valid/row_end_ready` is a drain barrier after the final core raw pixel transfers. The consumer acknowledges only after all results derived from that row have been consumed. Only then may the next sensor row enter capture.

The supplied actual frontend implements those handshakes. It programs the old module with pattern0 and `{black1,black0,black1,black0}`, sends a synthetic SOF on each row, and restores public full-frame markers. Configuration commits on the first old raw input. Its owned count includes the old elastic output until final public acceptance; row config and the fence require both count0 and old output empty. Held old output cannot cross a row configuration. The old 16-bit frame ID is explicitly the low16 bits of the tag and is checked by the TB; the wrapper retains full tag independently.

Input capture and active replay do not overlap. Replay can transfer an II=1 burst when ready; this is not sustained one-sensor-pixel-per-clock service. With always-valid sources and always-ready consumers, a conservative source-derived row budget is `sensor_width + WIDTH + 48` clocks, including the shared divider, RAM read and drain boundaries. Unbounded backpressure gives no finite unconditional latency. This budget is an RTL schedule property, not a measured hardware frequency or image rate.

## Terminal status and provisional frames

`d_valid/d_ready` holds error, full tag, completed-row count and raw replay transfer count. A row completes only after the drain fence. In the actual frontend, terminal DONE therefore follows all public pixel results. Clip counters are per-command modulo-32 differences of the unchanged module's counters and are meaningful at DONE; at most 65536 pixels per frame makes that difference exact even across a global counter wrap. During execution they can include corrected results still held downstream.

| d_error | Meaning |
| --- | --- |
| 0 | Complete frame |
| 1 | low>high, minimum0 or minimum>32; no sensor pixels accepted |
| 2 | Accepted sensor marker does not match exact raster position |
| 3 | Too few qualified physical-even references in a row |
| 4 | Too few qualified physical-odd references in a row |
| 15 | Illegal internal state |

**All emitted rows remain provisional until error0 DONE. Any error or reset requires the caller to discard the entire frame**, including earlier emitted rows. There is no frame buffer or rollback. On a terminal error the source must abandon the remaining sensor samples, consume DONE, and restart with a new command/frame. Markers are validated as samples arrive; an error can therefore follow earlier successful rows. If both parity counts fail, error3 has priority. The core's replay count excludes the failed row.

## Offline use and verification boundary

Compile from this package directory using `-f files.f` for the estimator or `-f example/files.f` for the actual frontend. No external memory, coefficients, vendor primitives, firmware or network build steps are needed. The row RAM is fully overwritten before replay and has no reset loop. New local code is Apache-2.0. LibRaw0.21.2 was inspected as a read-only technical comparison; its decoder is not an equivalent per-row estimator and no upstream code is copied or translated. See SOURCES.md and references.json.

This README is a frozen pre-execution specification. The completed RTL/docs/model/TB/runner and finite plan need independent B review and explicit root first-run authorization before oracle import/preparation or HDL. Evidence and maturity will be recorded separately in STATUS.md, QUALIFICATION.json and B42_DELIVERY.json. A missing receipt means NOT_RUN. No synthesis, PnR, STA, board, image-quality, old or combined regression is included.
