# Provenance and license

All local RTL, example, test generation and documentation were independently
written for ANSCORE under its Apache-2.0 license. No upstream source file or
text was copied/adapted into this package. No third-party dependency is needed
to use the RTL or execute its finite checks. Development baseline:
`6d1af43402343c6b8e2882d0d24cc8bc6da8ce05`.

Read-only predevelopment review examined this public histogram algorithm:

- Repository: https://github.com/TheAlgorithms/Python
- Fixed commit: `574d100b7181956e9c8384552fd078165e4cc326`
- File: `data_structures/stacks/largest_rectangle_histogram.py`
- Fixed URL: https://github.com/TheAlgorithms/Python/blob/574d100b7181956e9c8384552fd078165e4cc326/data_structures/stacks/largest_rectangle_histogram.py
- Git blob: `7575bd9f628da47c322d90de12b326b63238f796`
- Retrieved source SHA256: `7cd542ca383e683dd8a0c60dc9543218bfc69a7297d9a2167d61b63c0caa389f`
- License: MIT, actual license text reviewed at the same commit.
- License URL: https://github.com/TheAlgorithms/Python/blob/574d100b7181956e9c8384552fd078165e4cc326/LICENSE.md
- License Git blob: `de631c3ef33374d91a78dca3a656806e4e3bb890`
- Retrieved license SHA256: `4395a1dc4bda1d6054c45b4d1230c709c7398e6d66f1d0aff4b22d95973bea56`
- Upstream copyright: 2016-2022 TheAlgorithms and contributors.

The reference computes only a histogram's maximum area with a software stack.
It was used to check the general increasing-stack idea and trailing zero
sentinel. This RTL independently defines a framed binary-raster objective,
column-height storage, a synchronous-RAM stack with cached top, coordinates,
deterministic tie rule, errors, reset cancellation and ready/valid behavior.
The numerical oracle deliberately enumerates all rectangles rather than
translating the reference algorithm. No upstream code, remote scripts, build
system or installation commands were executed. API responses and source text
were treated only as untrusted reference data.
