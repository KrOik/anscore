# Source, license and semantic preflight

Baseline: fcd2beef77f998da54801b91d74ce47946bee17c.
Original ANSCORE Apache-2.0 contribution; no third-party implementation is
copied, translated, vendored, executed or imported. No runtime dependency,
table generator or sibling RTL is required. Local LICENSE is the root
Apache-2.0 text normalized to LF; repository NOTICE applies.

Before authoring RTL, repository semantic searches and actual SPEC/RTL reads
covered acc_cam_match, acc_lpm_trie_step, tlb8_lookup and ram_hash_table.
The six-entry CAM uses slot-addressed16-bit parallel matching without canonical
identity deletion/capacity management. The trie-step kernel loads a generated
immutable16-slot image and consumes8 key bits per accepted beat. TLB lookup is
exact VPN tagging/permissions. The RAM hash dictionary is exact-key probing,
without MSB-prefix identity or longest containing result. Their interfaces and
storage contracts do not supply this persistent serialized prefix service.
Existing code and shared metadata were left unchanged.

The web search endpoint failed HTTP500 (`channel does not support
/v1/alpha/search`). Read-only GitHub API resolved v1.0.2 to the fixed commit
below and supplied exact tree blobs. Fixed raw files were retrieved using
PowerShell Invoke-WebRequest with TLS1.2, HTTP1.1 and15-second network limit.
Responses were inspected as untrusted text; no fetched module/build was run.

Repository: https://github.com/yl2chen/cidranger
Fixed commit: `7ff5a0e84593dad6fbd50551343618d7956b3c71`.

| Actual full file inspected before RTL | Bytes | Git blob | SHA256 |
|---|---:|---|---|
| trie.go | 10601 | 938d6256e3b8835f04525ba7a9fe5b190539372d | eee3264cd4dbeecaf71a193fc068b4827072d7bff1e9f0d3f3381b8a2a2e3a0e |
| LICENSE | 1062 | c41c62239374c93cd74b35213c7d0da42a7c2647 | 00364c787e5b510a6ea5b863092925d931a76464715c24129c2d01a3279ce6ef |

Fixed source:
https://raw.githubusercontent.com/yl2chen/cidranger/7ff5a0e84593dad6fbd50551343618d7956b3c71/trie.go
Fixed complete license:
https://raw.githubusercontent.com/yl2chen/cidranger/7ff5a0e84593dad6fbd50551343618d7956b3c71/LICENSE

The complete MIT text identifies Copyright2017 Yulin, grants use/copy/modify/
distribution/sublicensing/sale subject to retaining notice, and disclaims
warranties/liability. It was a feasibility preflight; no upstream code or
license-dependent portion is redistributed here.

The actual trie.go defines dynamic path-compressed parent/child networks,
Insert with exact-network replacement and root size accounting, Remove with
compression, Contains and ContainingNetworks in ascending prefix order.
The latter supplies containing entries rather than this RTL's single LPM
response. Local RTL independently scans synchronous row RAM, canonicalizes
MSB prefix identities, serializes mutations and returns exact occupancy and
held tagged responses. No Go API compatibility, trie complexity, upstream
execution or upstream test coverage is claimed. The interval-dictionary
oracle is original local Python and needs only the standard library.

Offline source closure is files.f (core only) and examples/files.f (core plus
fixed wrapper). No external generated image, network resource, package manager
or untracked dependency is needed for instantiation and finite checks with
installed tools. SHA-bound verification and HW_UNVERIFIED limits are explicit.
