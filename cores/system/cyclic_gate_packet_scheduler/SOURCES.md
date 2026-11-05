# Provenance and functional increment

The scheduler, example, TB, independent model and finite runner are original
Apache-2.0 ANSCORE code. No external RTL was imported/adapted/executed. Full
repository license is included. Reused production source remains canonical:
`../common_scaffold/memory/src/cip_sync_fifo.v`, SHA-256
`450ea3b252a83e2a214a94cb8c4ade54436c046175880eb31e9f3e2713a71ba6`.
Internal FIFO CE is tied1 and standard FIFO ownership is preserved.

Before implementation, deep RTL/README/SPEC/catalog searches compared gate
control, TDMA, time-aware scheduling, guard bands, packet schedulers and credits:

- `multiflow_token_shaper` replenishes per-flow elapsed-time token buckets;
  it does not enforce cyclic gate lists, remaining-window fit or link occupancy.
- `descriptor_drr_scheduler` and `acc_pacing_wf2q` update visit-based deficit
  credits; they have no independently ticking runtime gate schedule.
- `shared_packet_queues` stores payloads but POP explicitly selects a queue;
  it has no time-window arbitration or service reservation.
- `ram_deadline_scheduler` holds keyed absolute events and uses a captured
  cutoff; it does not buffer FIFO packet flows against cyclic gate masks.
- `acc_ctl_credit_arb8` makes small credit-arbitration updates, without packet
  FIFOs, stage/commit schedule management, guard fit or non-preemptive service.

The increment is complete bounded cyclic launch authorization combining those
missing behaviors over reusable FIFO storage, rather than a counter or renamed
arbitration kernel. No full Ethernet/IEEE protocol compliance is claimed.

Read-only primary open-source/embedded license review before authoring:

- Repository: https://github.com/corundum/corundum
- Pinned commit:`1ca0151b97af85aa5dd306d74b6bcec65904d2ce`.
- File:`fpga/common/rtl/tx_scheduler_ctrl_tdma.v`, inspected for queue enable
  controls driven by active time slots. Its SPDX license is BSD-2-Clause-Views.
- The pinned root LICENSE was read, including its redistribution conditions
  and views disclaimer. No source was copied or local bit equivalence claimed.

GitHub commit/tree API and pinned raw HTTPS GETs were used read-only. No remote
script, installer or build system was executed. This standalone relative-clock
core does not depend on Corundum's AXI-Lite, PTP, NIC driver or generated files.
