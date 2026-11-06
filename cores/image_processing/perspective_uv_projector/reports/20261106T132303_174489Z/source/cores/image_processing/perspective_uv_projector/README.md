# Perspective UV projector

Exact perspective-correct triangle UV interpolation for positive, quantized
reciprocal-W vertex values. This fills the gap between the repository's affine
triangle/texture path and full-frame inverse projective image warp.

Status: **RTL_CANDIDATE / INTEGRATION_CANDIDATE / HW_UNVERIFIED**.
The new source, reference and tests have not executed. `PRECHECK_PLAN.json` is a
finite proposed check, not a PASS claim. No synthesis, PnR, STA, board or PPA data.

For pixel centre `(x+1/2,y+1/2)`, let `E_i` be the signed opposite-edge value,
flipped together when vertex winding is negative. For a covered query:

```
D = sum(E_i*q_i)
U = RNE(sum(E_i*q_i*U_i)/D)
V = RNE(sum(E_i*q_i*V_i)/D)
```

`q_i` is a positive unsigned integer representing reciprocal W at an arbitrary
common scale; that scale cancels. Results are exact for those quantized q values.
The host must perform any perspective transform and clipping before this module.
There is no reciprocal approximation or intermediate UV rounding in the core.
The only rounding is nearest with ties to even at the final integer UV output.

The core accepts closed-triangle queries, including centres exactly on edges.
An outside query produces one held result with `m_covered=0`, `m_u=m_v=0`.
The actual wrapper retains the unchanged raster's top-left edge ownership.

| Input | Domain |
|---|---|
| Vertex x/y | signed 10-bit, -512..511 |
| Vertex U/V | unsigned 8-bit integer texel coordinate, 0..255 |
| Reciprocal W | unsigned Q_W-bit integer; positive for a valid configuration |
| Query x/y | unsigned 8-bit pixel position, 0..255 |
| Q_W / TAG_W | 1..16 / 1..32, default 16 / 8 |

`rtl/perspective_uv_projector.sv` has one configuration command/response and one
query/result channel. Transfers occur only on a rising edge with valid and ready
both high. Synchronous active-high reset cancels all owned work and configuration;
public valid/ready/configured/busy signals are masked while reset is high. There
is no CE. Input payload may change immediately after its handshake. Output and
response payload remain stable while valid is held without ready.

Configuration has priority over a simultaneous query offer. Acceptance immediately
invalidates the previous configuration. Response status is 0 success, 1 zero area,
2 any q=0 (q validation precedes area validation). No query is admitted until a
successful response has retired. Bad configuration stays unconfigured. Configuration
tag belongs to its response; each query supplies its own preserved tag and first bit.
One query is owned at a time; configuration is blocked until its result retires.

Source-derived service counts, pending execution: response first becomes valid
15 rising edges after successful acceptance, 3 for zero area and 0 for q=0.
An inside query result first becomes valid 47 subsequent edges after acceptance;
outside takes 10. Earliest result retirement is one edge later. With always-ready
consumers the corresponding minimum new query intervals are 49 and 12 cycles.
Unbounded backpressure means unbounded completion time. These counts are cycle
contracts to be checked by the supplied TB, not measured clock-frequency claims.

`example/perspective_indexed_triangle.sv` is a real composition:

```
unchanged triangle_rgb_raster -> perspective_uv_projector -> unchanged indexed_texture_sampler
```

The raster's RGB vertices are zero and its computed RGB is ignored; coverage,
clipping, fragment order, top-left rule and count remain its real unchanged RTL.
The wrapper first validates/publishes projective configuration, then starts that
raster. Each raster fragment is owned until the final public texture result retires.
The next fragment and completion cannot pass it. Public completion waits both
projector and sampler to drain, and is held until `d_ready`.

Texture management mirrors the original sampler: op0 begins runtime index/palette
loading, op1 publishes only after all `TEX_WIDTH*TEX_HEIGHT` indices and 256 palette
entries, other ops fail. Commands and their responses take priority over triangle
offers. A triangle requires resident texture. Texture management and writes are
locked from accepted triangle through held public DONE; offered triangles do not
block loading. Reset also discards sampler residency, requiring a full reload.

Every covered raster fragment returns an RGBA lookup result, including transparent
and UV-out-of-range results; DONE count includes all of them. RGB, alpha, visible,
xy, tag and first are held under backpressure. `m_reason` is 0 visible, 1 UV outside
texture bounds, 2 zero-alpha texel, 4 unexpected projector coverage rejection.
Reason4 emits RGB/alpha zero and preserves fragment metadata rather than silently
dropping it. DONE status is 0 normal, 1 degenerate, 2 raster bounding-box clipped,
3 invalid q. Fully clipped status follows the original raster's bbox semantics;
a bounding box that intersects the screen may complete normally with zero fragments.

Wrapper canvas and texture dimensions are 1..256. Default64x64 texture storage
is 40,960 logical bits, maximum256x256 is 532,480 logical bits, inherited from the
original sampler. The new projector contains no pixel/frame RAM. See
`ARCHITECTURE.md` for arithmetic, storage and service limitations.

`reference_model.py` uses independent unbounded integer area/edge/divmod equations.
`sim/tb_perspective_uv.sv` checks exact UV, latency, configuration priority/ownership,
held responses/results, bus mutation and nine reset checkpoints. The real wrapper
TB checks exact ordered RGBA, transparent/OOB samples, clipping, two adjacent
top-left triangles, command lock through held DONE, runtime loading and seven
reset checkpoints. Four once-only preparation children and ten HDL children are
proposed, all with20s child /5s tree termination /one2s exit+drain bounds.

Execution requires complete independent root source review and a separately issued
`B45_PERSPECTIVE_UV_ONCE_01` gate bound to the final plan and seal. The runner has
no planning/model-import mode, never retries, retains original execution images,
and records durable process/raw evidence before parsing output. The maximum
simulation uses small sparse triangles on maximum dimensions. No near-plane
clipping, generic3D transform, mipmaps, filtering, depth buffering, frame output,
full-screen frame deadline or physical resource/throughput guarantee is provided.
