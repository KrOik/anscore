# Provenance and offline dependencies

The RTL, testbench, example, Python oracle and evidence runner are original ANSCORE implementations. No upstream implementation is copied, translated, imported, compiled or executed. Runtime and delivery require no network and no upstream C library. Python fixture/evidence utilities use the standard library only; HDL evidence uses the locally available Icarus Verilog/vvp tools with independent 20-second hard deadlines.

QOI format and deterministic encoder choices were reviewed against the complete pinned `qoi.h`, including its helpers, encoder, decoder and file wrappers, and the complete MIT license:

- Repository: https://github.com/phoboslab/qoi
- Commit: `ffb2d2cb74a1de60819b21b939f7209aa53e91c1`
- https://github.com/phoboslab/qoi/blob/ffb2d2cb74a1de60819b21b939f7209aa53e91c1/qoi.h — 18,326 bytes; SHA256 `7de6fca1a285b1c20d38f2723dec8b774eb9f144edb9710800a95feeea09375a`.
- https://github.com/phoboslab/qoi/blob/ffb2d2cb74a1de60819b21b939f7209aa53e91c1/LICENSE — 1,075 bytes; SHA256 `0caf25d92ae0e7e12107e144a86782ccaad37ddaa3ee51e86e193c7db9ed1487`.

Read-only raw/urllib/API/CDN attempts encountered network timeouts. A native curl request to the GitHub contents API successfully retrieved and base64-decoded the exact bytes in memory; the full source/license were read and both hashes matched. The downloaded files were not saved, imported or run. `qoi.h` prints Copyright (c) 2021 Dominic Szablewski and SPDX-License-Identifier MIT; the separate license prints 2022. These distinct printed dates are preserved rather than reconciled.

The local QOI decoder production RTL, README and SOURCES were read completely, with existing PNG stored-DEFLATE encoder behavior also reviewed. All 576 core READMEs (3,075,691 raw bytes) were read for semantic deduplication; two historical files required GB18030 decoding. No existing QOI encoder implementation was found. B24 published baseline: `d35d71be3bfc76f272809ae250d19cba92dbb18c`. Existing modules and protected refs are unchanged by this package.

The following upstream license is reproduced as provenance, despite there being no adopted upstream source dependency:

```text
MIT License

Copyright (c) 2022 Dominic Szablewski

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
