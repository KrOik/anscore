# Primary sources and license boundary

Reviewed2026-11-06 using read-only HTTPS. The web search service returned an
infrastructure HTTP500; the primary documents were then fetched directly with
stdlib HTTPS. No third-party protocol code is imported, executed or copied.

* Nasdaq official OUCH4.2 specification, Updated October2025:
  https://www.nasdaqtrader.com/content/technicalsupport/specifications/TradingProducts/OUCH4.2.pdf
  SHA256 `037c818d954af7299690ecc5d94f094f730171e05f741a6c7c4f0ace75a244ce`,261630 bytes.
  Sections1.1/1.2 and3.1..3.10 establish sequencing, unsigned network-order
  types,decimal4 prices, the six selected layouts and reason-code extension.
  Nasdaq copyright2025, all rights reserved. Only protocol facts and original
  paraphrases are recorded; the PDF and its narrative tables are not redistributed.
* Read-only external implementation comparison:
  https://github.com/gitter-badger/OUCH/tree/3b63e8401b69a5244bf5a2301d38271ff07892e4
  Its `src/ouch.hpp` SHA256 is
  `663c1754d709991ccf6d6cd541815ce36d658b12e13222001d276839059129a3`.
  `LICENSE` declares MIT, Copyright(c)2015 Carriez. Packed structs independently
  corroborate selected lengths10/66/80/28/40/24 and the displaced U previous
  token. Its little-endian conversion macros and signed C++ integer storage
  are not reused. The old SDK has an obsolete AIQ layout, so it is not treated
  as authority for current protocol coverage or enumerations. Comparison only;
  no SDK source or license file is vendored into this original implementation.
* Local actual dependency: `../soupbintcp_session_rx/followup01/rtl/soupbintcp_session_rx.sv`,
  SHA256 `bd6c95ef32b96e02257983c1dc020d907a3dd3eeda2830129611593491396a3f`,
  Apache-2.0; and `../soupbintcp_session_rx/rtl/deps/soup_rx_axis_fifo.v`,
  SHA256 `8ab6ac183c805d806e5a5e6ae0acfba609519a0f5103146897d5beec9013a5dc`,
  MIT upstream verilog-axis commit `48ff7a7e2ef782cf778d47910cf85835c64b1bce`.
  See that package's LICENSE.axis_fifo and upstream provenance. Those frozen
  files are referenced unchanged. The upstream FIFO is deprecated; no upstream
  maintenance promise is made.

All newly authored RTL,model,TB,runner and documentation are Apache-2.0.
This is an original interoperable decoder, with no Nasdaq affiliation claim.
