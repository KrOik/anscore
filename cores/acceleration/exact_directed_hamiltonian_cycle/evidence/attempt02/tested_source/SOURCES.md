# Source and semantic review

Original ANSCORE RTL and verification authoring, Apache-2.0. No external code
was copied, translated, imported, compiled or executed. The production closure
contains only rtl/exact_directed_hamiltonian_cycle.sv. LICENSE retains the
repository's Apache text; NOTICE identifies original authorship.

Before implementation, local path/content searches covered Hamiltonian,
Held-Karp, traveling-salesman and Chinese equivalents across acceleration
packages, the IP index and current cumulative108+four new B28 capability
contracts. No same directed complete-tour service was found. Existing minimum
cost assignment permits disjoint subtours; general matching permits uncovered
vertices; Euler traversal covers edges. These are different input/output
contracts, not alternative widths for this capability. This is a source-library
deduplication result, not a patent novelty claim or a claim about all external IP.

Read-only external repository search used the GitHub primary API query
`traveling salesman verilog`, returning total_count0. The browser search/open
service returned HTTP500; no external installer/project was run or adopted.
The query result is not proof that no HDL implementation exists anywhere.

Bibliographic metadata was actually read from the DOI registration record:
https://api.crossref.org/works/10.1137/0110015
Michael Held and Richard M. Karp, *A Dynamic Programming Approach to Sequencing
Problems*,1962, DOI10.1137/0110015. The full paper was not read; no passage,
figure or source code from it is reproduced. The package independently states
and implements the finite subset recurrence described in README, with a
separately authored direct-tour-search reference. No third-party source license
or runtime dependency is introduced by the bibliographic reference.

Original baseline release before this package:
481863a7318d510ca6717c1690a7107f363525de (B28 local112-package snapshot).
Existing RTL, old verification evidence and original dirty/untracked files are
outside the write scope. HW_UNVERIFIED; all qualification remains NOT_RUN.
