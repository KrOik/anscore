# B21 semantic and fixed-source preflight

Initial HEAD `ed4eda4fe213da6f6fec793ef911daaabfeba2cc` (B20), old40 stable
refs, original15 tracked changes/diff, goal, complete21000 untracked inventory,
development branch and empty index were independently checked before work.

Whole-core production RTL and README/SOURCES searches covered anti-replay,
replay/sequence windows, packet duplicates and Chinese sequence/window terms.
The complete actual `prod_sequence_window32.v` and its TB were read: it only
computes a supplied32-bit modular difference and range flags, without retained
seen history or contexts. Actual complete contracts of `ordered_completion_buffer`,
`ram_hash_table` and `atomic_scratchpad` were also read. Those retire allocated
work in order, store arbitrary bindings or perform word RMW respectively; none
classifies historical sequence numbers against an independently aging window.
This package adds a persistent exact window service rather than renaming the
stateless sequence comparator or changing a width.

Before the first local RTL write, GitHub's commit API resolved WireGuard's
wireguard-go master to fixed commit
`b3bc704ef0ee21a36298601a9e1e5ff90377ac52`. Both complete files below were then
retrieved through their fixed raw HTTPS URLs, hashed and strictly UTF8 decoded,
and all their source/license content was read without truncation:

| Complete fixed upstream file | Bytes | SHA256 |
| --- | ---: | --- |
| [replay/replay.go](https://raw.githubusercontent.com/WireGuard/wireguard-go/b3bc704ef0ee21a36298601a9e1e5ff90377ac52/replay/replay.go) |1720|`40abe148dfb29aef0b52dd4b8d6690873d906063900823b92f6f03c347ff5968`|
| [LICENSE](https://raw.githubusercontent.com/WireGuard/wireguard-go/b3bc704ef0ee21a36298601a9e1e5ff90377ac52/LICENSE) |1023|`91276db973f25602d1aa43491f59cbc84cb88e6f151e1d0cc82a755563ce0195`|

The source carries SPDX MIT and2017-2025 WireGuard LLC copyright. The complete
repository MIT permission/notice condition and warranty/liability disclaimer
were read. No upstream source, comment, license text, test, script or executable
was copied, adapted, persisted locally or run. This is independently authored
Apache-2.0 RTL/test/documentation under repository LICENSE/NOTICE, with no
adopted third-party code requiring redistribution of a license copy.

The upstream reference is an RFC6479-style block ring with an exclusive
per-call counter limit and an inclusive age bound. This local implementation
uses an exact W-position bitmap in synchronous RAM, independently addressed
contexts and standard ready/valid. It accepts all unsigned64 values, has no
protocol counter limit and uses age<W. MARK and nonmutating PEEK share explicit
classification; context clear/all-clear have metadata ownership. No WireGuard,
IPsec, cryptographic authentication, replay protection for unauthenticated
traffic, modular-counter or rekey protocol compatibility is claimed. A caller
must authenticate/validate traffic before MARK and manage sequence epochs.

Only read-only metadata/HTTPS retrieval and source inspection preceded RTL.
Untrusted remote text was not treated as instructions. Production has one local
RTL source and one optional direct wrapper, no Go library, network, generated
memory image, sibling core or external memory dependency. New local attributes
were created first and all delivered text uses UTF8/LF. Old assets and shared
files remain untouched; no synthesis/PnR/STA/board or expanded regression runs.
