# Sources and semantic deduplication

New RTL, wrapper glue, fixtures and TB are original repository work. Public
material was consulted for the functional distinction between recorded-time
replay, speed scaling and maximum-speed transmission. No external HDL/software
implementation, repository, model, capture or generated answer was copied,
downloaded for execution, imported or run.

Read-only primary sources (2026-11-07, native PowerShell Invoke-WebRequest):

* https://tcpreplay.appneta.com/concepts/timing-and-speed/ — HTTP200,
  51368 response bytes at inspection. Describes original timestamp gaps,
  multiplier scaling by1/N and no-delay topspeed as distinct choices.
* https://tcpreplay.appneta.com/reference/man/tcpreplay/ — HTTP200,
  68598 response bytes at inspection. Defines multiplier, pps, mbps, topspeed
  and oneatatime options. These software options are context, not a claim that
  this hardware supports every such mode.
* https://tcpreplay.appneta.com/concepts/replay-model/ — HTTP200,
  49494 response bytes at inspection. Separates replay transmission from a
  complete network stack or downstream reception measurement.

The old /wiki/tcpreplay-man.html is a362-byte meta redirect, not the current
technical content. The web search/open channel returned an unsupported-search
error; the primary documents above were obtained directly with read-only native
HTTP requests. No mutable service action was taken.

Local semantic inspection used standalone text/JSON reads, not imports, AST,
model, HDL or Git execution. Coverage:429 canonical source paths and196 package
READMEs from B49 snapshots, plus915 baseline noncanonical RTL candidates from
the retained NUL tree (54 lexical match files). The scan is a finite inventory
and the conclusion is bounded to it; name matching alone was not treated as
semantic evidence. Near equivalents inspected include:

| Existing implementation | Distinction |
|---|---|
| ram_deadline_scheduler README27–32 | Caller cutoff; expressly no autonomous clock/conversion |
| watermark_event_merge README22–45 and actual example | Safe ordered release; no pacing clock/rate |
| sys_capture_replay RTL19–40 | Opaque full-rate stimulus RAM |
| sys_timestamp64 RTL7–14 | Tags the pre-edge physical counter, no paced release |
| acc_pacing_wf2q RTL59–99,157–165 | Transaction-driven credit, not elapsed replay time |
| cyclic_gate_packet_scheduler README69–77 | Cyclic gate calendar and service reservation |
| motor_replay_owner / virtual_raw_source | Fixed cadence of samples/frames |
| ips_micro_sequencer16 RTL11–20 | Conditions/instructions, no timestamp record stream |
| ram_replay_window | Sequence anti-replay classification, no timed playback |
| event_interval_recorder | Measures intervals, does not schedule recorded events |

The complete offline example source closure references these existing files
without modification or aliases. SHA256 values are current read-only bytes:

| Path from repository root | SHA256 |
|---|---|
| cores/system/common_scaffold/memory/src/cip_sync_sp_ram.v | 04c0fe8416308c7e9a295d582dc7fee5fd8bbadf2fe4e745632543588c4f7619 |
| cores/storage/ram_deadline_scheduler/rtl/ram_deadline_scheduler.sv | 0c4b3a8dcacf8fd1bed1ddb7e2ffc41ed221bf025dd05de1d66ec10b6abaa62a |
| cores/communication/moldudp64_itch_rx/rtl/moldudp64_itch_rx.sv | d5ac572f9c0362a27c647aca96f7c189716eacbae2a7f5279fea448ec70ebd04 |
| cores/storage/watermark_event_merge/rtl/watermark_event_merge.sv | 6eec4997e7203160a0aaa4c85e07aa336a9c8c7725a502a37a8e08b88c4cb43e |
| cores/storage/watermark_event_merge/example/dual_itch_time_merge.sv | aa0bb3faa78cc5360c69710fd6192dc34e228f75e4c48249949a449dde345ff8 |

The core files.f has only the new standalone core. The example files.f includes
all five unchanged dependencies plus the new core/wrapper. Paths are resolved
from this package directory; no include path, network runtime, ROM or external
coefficient file is needed. B49 evidence/RTL and its unapproved workspace-only
revision files are frozen and are not part of this addition.

Formal package metadata adds an exact byte copy of the root Apache-2.0 LICENSE,
manifest, independent runner, exact plan/seal and a PENDING review control.
The package-local .gitattributes uses -text so every frozen source/license byte
is preserved as authored. The runner lifecycle source was copied and adapted
from the fully read known_phase_tone_fit runner (B50, after the reset-count19
source-only correction), itself derived from the frozen B49 runner. It does not
import or execute that sibling helper. No B49 or B50 sibling source is changed.
Only raw lifecycle source reuse is claimed; the timestamp-specific fixture and
marker validation is original and separately reviewable.
