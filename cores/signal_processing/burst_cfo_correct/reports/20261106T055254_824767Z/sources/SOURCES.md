# B39 sources and provenance

Baseline `1e9e9130cef71127d2c8d2762affe815b067b9f5`. New core/controller, actual
service example, direct mathematical oracle, finite TB and metadata are original
ANSCORE contributions under root Apache-2.0 LICENSE/NOTICE. New directory uses
`* -text` from its first write. All existing dependencies remain byte unchanged.
The complete root Apache-2.0 text is copied byte-for-byte as package LICENSE
for offline distribution.

| Active original path | Role | SHA-256 |
| --- | --- | --- |
| `cores/signal_processing/repeated_half_sync/example/sync12_phase.sv` | Actual prefix qualifier-to-atan2 composition, fixed D12/L16 | `0148279fd97eabc528de75679c1484ff5edd4608c2fea8b5b9fd37b4e3745b0e` |
| `cores/signal_processing/repeated_half_sync/rtl/repeated_half_sync.sv` | Exact P/energy and normalized qualification | `1e07b1dcbc653a0ea03cb4d8b58ee7b55a64c1e2e666df03c3aaa0a4724add15` |
| `cores/signal_processing/dsp_isp_library/infra/fixedpoint/rtl/cplx_mac.sv` | Existing exact prefix complex products | `21f17250725762362f70e9d9c3f7165a6c3bc52326c45696bccafb097e37f4fd` |
| `cores/acceleration/stream_atan2/rtl/stream_atan2.sv` | Existing full-circle angle, P24/ITER24 | `525dd5d06816b7120492dc50fd117f34e14027bf3ec2c811cb8dba77748d230a` |
| `cores/acceleration/stream_sincos/rtl/stream_sincos.sv` | Existing coefficient generator, P32/W18/ITER24 | `b0945b83dded63e7eee0b3beb87c93bf4787f862273915f0f5193336efd8a2cf` |
| `cores/system/common_scaffold/image/histogram/rtl/img_hist_serial_multiply.v` | Existing exact unsigned multiply, prefix and replay instances | `40e6dffb4b0c87a5ee71e414ced900cd2ebf6019013a043261c7a2a47a9de60f` |

All except sincos were already tracked/canonical before B39. The sincos source
is pre-existing workspace original ANSCORE code, untracked at this baseline.
B39 exports only that exact source and a root-created scoped
`/stream_sincos.sv -text` attribute. No other legacy sincos asset is imported.
The source header identifies the full-circle fixed-point function and has no
third-party notice. Original repository provenance is corroborated by
`docs/STREAM_SINCOS_DEVELOPMENT.md` (development record), legacy manifest's
source path/hash, and the repository README license declaration at lines209–211.
Root LICENSE/NOTICE explicitly cover authors' original contributions; NOTICE's
enumerated third-party exclusions do not identify this original algorithm.
No specific personal author is asserted when none is recorded in its header.

Read-only provenance hashes: LICENSE
`3ddf9be5c28fe27dad143a5dc76eea25222ad1dd68934a047064e56ed2fa40c5`;
NOTICE `a40afad65a282abd2951e84f948c1cab839c12bc354bd9c1c0235fe653b589a3`;
development record `fa5e6246c7b889e870caadef222f30ae09c027752d6cb4deb764252448b38804`;
legacy manifest `efd97d0e6f9ca308148d02a6e0b8e45c25f4478bba04d7da70977dd0bca38dad`.
These are provenance-only documents, not new qualification evidence. No old
helper simulation, formal, synthesis, route or board result is inherited.

The existing prefix ordinary ready/valid sync-high interface is used directly.
Its N32/tag0 transaction is internal and independent of outer burst length/tag.
The replay sincos also uses ordinary ready/valid sync-high reset. The unsigned
serial multiplier uses CE-qualified transfers and asynchronous-low reset:
constant CE1 and registered synchronous-origin reset adapt these semantics.
Executed archives are evidence copies, not active alternative module paths.
Offline compilation needs no downloaded RTL, external coefficients, ROM files,
vendor primitive or code generator.

## Capability deduplication

`system/stream_bus_library/rtl/sys_trigger_window.v` already provides triggered
pre/post ring capture, and `system/extended_library/src/ila_core.v` implements
masked level/edge acquisition. `sys_capture_replay.v` handles host capture.
These were rejected as duplicate candidate directions.

Existing `ddcduc/ddc_stream.sv` performs caller-programmed NCO mixing with
CIC/FIR, and `recovery/carrier_loop.sv` supplies BPSK Costas PI/NCO tracking.
`repeated_half_sync` qualifies repetitions and exposes P/angle but neither
buffers nor corrects/replays the complete burst. This package adds that bounded
feed-forward acquisition/correction service with phase alignment at sample0;
fixedD12/L16 is actual composition with B37, not a width-variant contribution.

## Official fixed upstream read-only references

GNU Radio v3.10.12.0 annotated tag object
`522b220f24cbf0df9789a2d8eff57ee3d3f58f52`, commit
`ec7a3239645162ffea1925e6f1e6e62bf1349d03`. Official fixed HTTPS source text
was inspected read-only after web.run returned HTTP500. No external code was
saved, copied, translated into RTL, imported or executed.

| Official file | Mathematical/context reference | UTF-8 SHA-256 |
| --- | --- | --- |
| [gr-digital/lib/ofdm_sync_sc_cfb_impl.cc](https://github.com/gnuradio/gnuradio/blob/ec7a3239645162ffea1925e6f1e6e62bf1349d03/gr-digital/lib/ofdm_sync_sc_cfb_impl.cc) | Delayed conjugate correlation, two-half energy normalization, sampled angle | `bb199194e7535c69a47f2d31cfe72f721e4ae4fc1a9cf68f3a2e8089b0c655ae` |
| [gr-digital/python/digital/ofdm_txrx.py](https://github.com/gnuradio/gnuradio/blob/ec7a3239645162ffea1925e6f1e6e62bf1349d03/gr-digital/python/digital/ofdm_txrx.py) | Actual sync output feeds frequency_modulator_fc(-2.0/fft_len), then mixer; negative arg(P)/L direction | `c69d63448463d76866996442ba2332ed95ae8e353d265aa54c594d995e354618` |
| [COPYING](https://github.com/gnuradio/gnuradio/blob/ec7a3239645162ffea1925e6f1e6e62bf1349d03/COPYING) | GPLv3 license text | `8ceb4b9ee5adedde47b31e975c1d90c73ad27b6b165a1dcd80c7c545eb65b903` |

The upstream source identifies GPL-3.0-or-later. It supplies formula/context
only. This original finite capture/replay service does not implement or claim
equivalence to the GNU Radio streaming OFDM synchronizer/receiver. The finite
runner reuses the original Apache-2.0 B38 timeout/atomic-receipt pattern, with
B39-specific archived inputs, model preparation and finite check sequence.
