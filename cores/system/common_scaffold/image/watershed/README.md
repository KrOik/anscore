# Marker-controlled watershed tile

`watershed_priority_frame.v` implements marker-controlled priority flooding,
not threshold segmentation. Input is a grayscale elevation tile, positive
seed labels and domain mask; output is a raster label tile. This is a bounded
serial engine, **at most 4096 pixels**, not full-HD or video-rate watershed.
Defaults are 32x32, BITS=8, LABEL_BITS=8. BITS=8..12, LABEL_BITS=1..16.

## Exact algorithm

All nonzero in-domain seeds reserve labels before flooding. Queue key is
`(raw pixel elevation, entry age)`. Initial seed age is its raster address;
discoveries receive consecutive ages starting at N. Pop the smallest key;
visit up,left,right,down, then UL,UR,DL,DR for 8-way connectivity. An in-domain
unlabeled neighbor immediately receives the popped label and is enqueued
exactly once with its own raw elevation. No minimax elevation update,
decrease-key, threshold or duplicate queue entries. Duplicate positive seed
labels are legal. Equal-height initial seeds use raster order; subsequent
equal-height discoveries use FIFO order.

This follows scikit-image's compactness=0, watershed_line=False push-label
algorithm with an explicit deterministic initial seed tie rule. Skimage
initial seeds all have age zero, so tied seed heap behavior may differ.
Do not claim universal bit equivalence for tied initial elevations. There
are no artificial zero-valued watershed dividing lines. A domain component
without seeds remains label zero/invalid; this is not a global error if a
valid seed exists elsewhere.

Actual source references consulted:

- https://raw.githubusercontent.com/scikit-image/scikit-image/v0.24.0/skimage/segmentation/_watershed.py
- https://raw.githubusercontent.com/scikit-image/scikit-image/v0.24.0/skimage/segmentation/_watershed_cy.pyx

## Interface

Accept exactly WIDTH*HEIGHT input handshakes (`ce && s_valid && s_ready`).
SOF marks only the first pixel, EOL each row end. First accepted pixel
snapshots cfg_connect8. Geometry is static. Seed zero means unseeded;
s_domain=0 excludes the pixel. The engine captures, floods, emits the full
tile, then holds done_valid until `ce && done_ready`.

Output handshakes require `ce && m_valid && m_ready`. Label, coordinate,
domain and markers stay stable on stalls including CE=0. m_invalid marks
excluded/unassigned pixels or every pixel on global error. m_sof/m_eol/
m_last follow raster geometry. Counters/error_code remain fixed through
output and held DONE. Synchronous active-high reset overrides CE and aborts
the frame without clearing RAM; fresh capture overwrites all RAM first.

| Error bit | Meaning |
| --- | --- |
| 0 | Malformed SOF/EOL |
| 1 | Nonzero seed outside domain |
| 2 | No valid domain seed |
| 3 | Internal frontier/capacity invariant failure |

Input errors consume the complete fixed-size frame, skip flooding and emit
original seed candidates with all pixels invalid. Discard that frame,
acknowledge DONE, then submit a fresh frame. Internal invariant errors emit
the current candidate, also globally invalid. Legal geometry and enqueue-once
make queue overflow unreachable. Invalid static parameters cause `$fatal`.
seed_count counts valid domain seeds; assigned_count counts labeled domain
pixels; popped_count counts consumed entries. A successful frame has
assigned_count=popped_count. CW represents N, age width represents 2*N.

## Architecture and evidence

Two synchronous RAMs hold terrain `{domain,elevation}` and flood
`{open,age,label}`. A serial full raster scan selects each priority minimum,
O(N²) total work and O(N) storage. Static geometry address arithmetic needs
no DSP. No production/NTT source is changed.

```powershell
python -B cores/system/common_scaffold/image/watershed/test_watershed.py
python -B cores/system/common_scaffold/image/watershed/synth_watershed.py
```

The unified test invokes test_watershed_protocol.py too. 132 frames/2288
pixels exactly match an independent heapq oracle. Covers smallest, single
row/column, plateaus, random masks, multiple/all seeds, last-raster minimum,
4/8 connectivity, unseeded components, no seeds, seed outside domain,
malformed markers and recovery, configuration snapshot, CE/stalls, held
OUT/DONE validity and payload/status. B12/L16 tests use labels over 60000.
Real skimage0.25.2: 99 exact valid frames, 15 documented tied-seed difference
frames; 18 error frames excluded. Unique-elevation comparisons assert exact.
Separate protocol test resets at CE=0 during capture, scan, push, held
output and DONE, then proves full-frame recovery.

Isolated synth_gowin/check-assert PASS: B8 32x32 uses 354 LUT1..4, 164 ALU,
182 FF, 3 RAM blocks; B12 64x64 uses 394 LUT1..4, 196 ALU, 213 FF, 10 RAM.
MUX2_LUT5 counts are 59/58. Both 0 DSP. No placed timing or board proof.
Small JSON evidence is retained; generated builds use TemporaryDirectory.
An initial superseded TB pulsed DONE-ready at CE0 and could hang; its
handshake was corrected and all tests rerun. Its dedicated residual temp
directory was explicitly removed. No DUT expected values were changed.

**Not board verified.** No side-channel or cryptographic claim.
