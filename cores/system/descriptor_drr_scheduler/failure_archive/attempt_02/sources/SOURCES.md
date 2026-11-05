# Reference provenance and semantic review

Baseline: `548ecff2b34281ec7b6f3306ba1c8d3af07f246d` (B26 release).

The following repository was discovered through the public GitHub repository
search API and inspected read-only. No upstream build, executable, dependency
installer or numerical implementation was run. No C source is bundled or
translated into this RTL. The original implementation and event-level oracle
in this package are licensed under the complete Apache-2.0 text in `LICENSE`.

- Repository: https://github.com/felix-arnold/Scheduling-Algorithms-for-VPP
- Fixed commit: `4476ef3da0d4061dbd2e1c1cac6d2604edb0443b`
- Commit date: 2024-02-05T02:12:14Z
- Fixed tree: https://github.com/felix-arnold/Scheduling-Algorithms-for-VPP/tree/4476ef3da0d4061dbd2e1c1cac6d2604edb0443b
- License: Apache-2.0; complete 11,357-byte upstream license was read.
- No upstream `NOTICE` file is present in the complete recursive tree.

Raw upstream SHA-256 values (LF bytes, before any local rendering):

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| `LICENSE` | 11357 | `c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4` |
| `README.md` | 155 | `aa918eef6e1092e189b53b79f984db1a47b02de2922f38df069b85089af96a94` |
| `sch_drr/sch_drr.c` | 2637 | `313f848874ab4104e472e39809cadd832f2c291072fff3462a2087a0c7a95deb` |
| `sch_drr/sch_drr.h` | 1113 | `8c03bb555293ef3db8c99587a51f657130abfa37b8cfa97162997cc88ca305a8` |
| `sch_drr/sch_drr_node.c` | 5467 | `bfb7f6fe9f1c5229d8cb40eaef8b0fc68812e93156327a31fa8d889bb69db570` |

The reference node uses byte costs, visit quantum addition and repeated
departures while the current queue can afford its head. It is a software VPP
plugin, not a hardware golden model. Its worker/static-cursor and empty-queue
credit details are not adopted. This package explicitly resets credit on empty
and retains it only while backlogged.

Actual baseline README and RTL review distinguished these existing packages:

| Existing capability | Actual behavior | Difference from this package |
| --- | --- | --- |
| `storage/shared_packet_queues` | Shared cell pool; explicit caller-selected POP; global command owner; no head-cost peek | Storage alone does not select by visit credits |
| `system/multiflow_token_shaper` | One head per flow; refill on real clock quanta; eligible RR changes flow each descriptor | DRR has multi-entry queues, visit-based credit and repeated service within a visit |
| `storage/ram_deadline_scheduler` | Minimum `(deadline, ID)` and due cutoff | No quantum or cost fairness |
| `system/common_scaffold/stream_bus/rtl/sb_stream_rr_arbiter.v` | Frame-locked ordinary RR through accepted LAST | One frame per turn, independent of byte cost |

Direct SPQ reuse would require an additional complete cost shadow FIFO because
the required head cost is not visible before POP. It would also serialize all
producers and consumers through SPQ's command owner. For this small descriptor
service, a dedicated 1W1R RAM with per-flow rings avoids that duplicated queue
state. SPQ, token shaping, deadlines, old arbiters and shared files are unchanged.
