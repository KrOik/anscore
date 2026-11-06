# Top-K dependency provenance correction

The executed SOURCES.md described both dependencies as unchanged at baseline.
The current Top-K bytes are unchanged, but that wording incorrectly implied
the Top-K path was already committed. Root and worker_a independently inspected
the retained final B47 `ls-tree` raw record (36,325 paths, SHA256
`2a9cbca7b0ea4b983606310afbbb1dcb6f7b1c99194b728cc2fa8355206a3811`):
`cores/acceleration/stream_topk/rtl/stream_topk.v` is absent from that tree.

It is a pre-existing original workspace RTL contribution, as identified by its
local manifest, covered by the repository Apache-2.0 license. B48 explicitly
admits only this unchanged source as a new support dependency, at its original
path. Its 3,665 bytes have SHA256
`3eb348a790ed8b59fb6d0bc73aebd7e18684c9b314898feb861d686e38707a53`;
the computed Git blob OID is `4740a91e72910a44559e7020420561b09b4959c7`.
That computed OID is not a claim of prior baseline inclusion.

The full source was reviewed with the actual K=2 integration before execution.
The passing followup simulation tests that exact source as part of the wrapper.
No other Top-K package source, script, report, historical physical result or
manifest is admitted or requalified by this batch. No existing file is changed.
The snapshot and commit explicitly record the one newly admitted support path;
the requantizer remains a proven unchanged baseline alias.
