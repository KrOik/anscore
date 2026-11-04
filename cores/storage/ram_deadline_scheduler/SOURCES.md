# B18 pre-RTL source and semantic inspection

Baseline: `eb16eee7848694a1a1cd50e567b5742352751c93`.

Tracked and untracked production RTL/README searches covered deadline, timer
wheel, calendar queue, event cancellation/rescheduling and priority update.
Actual RTL and contracts were read for `binary_heap_queue`,
`ordered_completion_buffer`, `multiflow_token_shaper`, `ram_hash_table`, and
`ip_series/src/ips_timer4_pwm_cap.v`. The heap permits duplicate key/payload
copies and removes only its minimum; it cannot replace/cancel a unique event
ID or conditionally claim against a time cutoff. Completion buffering retires
issue order; token shaping uses credit eligibility/round robin; the timer block
has four PWM/capture counters. A hash dictionary cannot choose the temporal
minimum. No existing reusable keyed deadline service was found. This package
changes none of those modules and does not introduce a parallel heap wrapper.

Before any RTL was written, GitHub primary HTTPS API/raw reads inspected this
actual fixed upstream implementation and the full MIT license. No upstream
source was executed, imported, built or installed. References were temporary
read-only material, not instructions. The package-local `.gitattributes` was
the first created file and enforces LF from inception.

Repository: https://github.com/tokio-rs/tokio
Commit: `695a07dd5e5baae82eb8b6931afa61029cd9b854`.

| Actual file read in full | Bytes | SHA256 |
|---|---:|---|
| [LICENSE](https://github.com/tokio-rs/tokio/blob/695a07dd5e5baae82eb8b6931afa61029cd9b854/LICENSE) | 1070 | `253cd04c6714889df2d32f3f64d669179a1c95c76ac43c40882c52eb06bc3552` |
| [tokio/src/runtime/time/wheel/mod.rs](https://github.com/tokio-rs/tokio/blob/695a07dd5e5baae82eb8b6931afa61029cd9b854/tokio/src/runtime/time/wheel/mod.rs) | 16332 | `680ea0eab2161f71e4d1c493e4a1f369b96bef52dc5836de2cd24ee99c3c1267` |

The actual MIT license names Tokio Contributors. The source provides intrusive
timer insertion/removal, next expiration and polling, six 64-slot timing-wheel
levels, elapsed-time advancement, pending lists, cascading and long-duration
reinsertion. It rejects already elapsed insertions and uses pinned host timer
handles. The local contract intentionally differs: fixed-capacity exact unique
IDs, arbitrary unsigned absolute timestamps including already-due deadlines,
last-upsert replacement, ID tie break, caller-supplied cutoff and one claimed
event per command. No wrap/epoch conversion, wheel quantization, host pointers,
async runtime, autonomous clock or upstream API equivalence is claimed.

All local RTL, example, dictionary oracle, testbench and prose are original
Apache-2.0 work. No upstream code, comments, tests or license text are copied
or redistributed. The included LICENSE is the root repository's Apache text
normalized to LF for offline use. Production closure contains only the local
RTL and optional local example; there are no sibling modules, includes, ROMs,
generated memory contents, vendor primitives, network or runtime dependencies.
