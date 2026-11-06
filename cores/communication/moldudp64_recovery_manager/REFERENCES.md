# Read-only protocol and upstream references

No external source was copied, imported, executed, installed or made a local
build dependency. This RTL and its model are independently authored.

Nasdaq MoldUDP64 v1.00 protocol specification:
https://www.nasdaqtrader.com/content/technicalsupport/specifications/dataproducts/moldudp64.pdf

Read pages2..5 in memory. Retrieved86837 bytes, SHA256
96cdd02b8728a441cb970d1371a96e73c01e1edaffb2891d43667e2a0ad8add5.
It defines big-endian session10/sequence8/count2, identical20-byte request
headers, heartbeat0, EOF65535 and downstream unicast responses. A response may
contain only complete messages fitting one UDP packet, requiring more requests.
This supports clearing outstanding on actual partial progress. The existing
receiver's EOF epoch policy is narrower than the protocol's persistent server
re-request policy; the example expressly retains that existing limitation.

Read-only upstream: https://github.com/paritytrading/nassau at commit
84b554b528ef1aa8c683ec578d81a47fcdea1528, Apache License2.0, copyright2014
Nassau authors. Full LICENSE.txt and the following files were inspected:

| File | Bytes | SHA256 |
| --- | ---: | --- |
| LICENSE.txt | 11357 | b40930bbcf80744c86c46a12bc9da056641d722716c378f5659b9e555ef833e1 |
| libraries/core/src/main/java/com/paritytrading/nassau/moldudp64/MoldUDP64Client.java | 12754 | b023b6bd6bcca4c423f673f4a55704a97db5f1a67187db1eb6bcea725ba8841a |
| libraries/core/src/main/java/com/paritytrading/nassau/moldudp64/MoldUDP64ClientState.java | 1152 | 135f93bfc073493e12887972f8b8b614a4790deb6b6aef86c4d1ce9448529aa5 |
| libraries/core/src/main/java/com/paritytrading/nassau/moldudp64/MoldUDP64.java | 1409 | 2a421cf61395f167cce6f304039931b1fc7dae972255cbf6224aa02cb75e2e72 |

The client maintains nextExpected/requestUntil, timeout retry and a65534 maximum
request count. This design uses explicit external retry triggers, full unsigned
64-bit arithmetic, explicit configuration and a bounded private RAM context
table. No software timer or implicit first-packet epoch initialization is used.

Initial web-search tool attempts returned HTTP500; direct read-only HTTPS was
used. A master-branch commit lookup returned422 before resolving main and the
fixed commit. A later spec page6 print had a GBK UnicodeEncodeError after pages
2..5 were read. These were reference discovery/printing events, not model or
HDL execution attempts. No external download cache was retained.

Local unchanged dependencies:

- cip_sync_sp_ram.v:04c0fe8416308c7e9a295d582dc7fee5fd8bbadf2fe4e745632543588c4f7619
- moldudp64_itch_rx.sv:d5ac572f9c0362a27c647aca96f7c189716eacbae2a7f5279fea448ec70ebd04
