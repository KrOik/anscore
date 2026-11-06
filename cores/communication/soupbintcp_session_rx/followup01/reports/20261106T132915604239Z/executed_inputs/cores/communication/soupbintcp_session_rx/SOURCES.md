# Sources and licenses

Nasdaq SoupBinTCP Version3.00, original specification, pp2-7 and revision table:
https://www.nasdaqtrader.com/content/technicalsupport/specifications/dataproducts/soupbintcp.pdf
Read on2026-11-06 as read-only protocol research. The document defines two-byte
length framing, server/client direction, control fields and implicit sequencing.
No PDF or copied protocol prose is redistributed. Protocol interpretation and
local bounded/fatal policies are documented in our own words in README.md.

The mature reusable FIFO is Alex Forencich verilog-axis, MIT, fixed commit
48ff7a7e2ef782cf778d47910cf85835c64b1bce:
https://github.com/alexforencich/verilog-axis/tree/48ff7a7e2ef782cf778d47910cf85835c64b1bce
https://github.com/alexforencich/verilog-axis/blob/48ff7a7e2ef782cf778d47910cf85835c64b1bce/rtl/axis_fifo.v
https://github.com/alexforencich/verilog-axis/blob/48ff7a7e2ef782cf778d47910cf85835c64b1bce/COPYING

UPSTREAM.json binds raw downloads. reference/upstream/axis_fifo.v is verbatim;
rtl/deps/soup_rx_axis_fifo.v differs only by the single module declaration name.
All original notices remain intact and LICENSE.axis_fifo is the full MIT license.
No external modules/includes are needed by this FIFO. The unique production name
avoids module collision with other packages. The reference original is excluded
from files.f. Upstream has deprecated verilog-axis in favor of fpganinja/taxi;
this delivery freezes the mature MIT source and makes no maintenance claim.

The session RTL, model, TB, runner and new documentation are original Apache-2.0
work under LICENSE. Copying/derivation is limited to the FIFO and its MIT license;
the finite child lifecycle is copied as text from the already reviewed local
call_auction_clear runner. No old helper was imported or executed. No shared
source has been modified. Local .gitattributes preserves raw bytes, including
license and upstream notices, without changing repository-wide attributes.
