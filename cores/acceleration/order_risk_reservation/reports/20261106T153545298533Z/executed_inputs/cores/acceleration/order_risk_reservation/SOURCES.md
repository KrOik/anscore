# Semantic audit, primary references and reuse

Baseline d32ea87e268c5957b7203560a5b46864e282a6e1, read-only review2026-11-06.
Independent IP, operator_library, utility_library and common_scaffold were
searched by order/risk/credit/position/reservation/cancel/pending/scheduler terms,
then the actual candidate READMEs/RTL were read. Existing position_limit_reservations
already supplies reserve/fill/cancel and signed directional limits; its IOC
example completes fills then cancels remainder. pretrade_credit_ledger tracks
gross notional holds, not persistent positions or venue cancel-pending state.
itch_order_state tracks market-data resting orders, not client risk before
venue acceptance. OUCH server_rx decodes events without retained client state.
No reviewed operator/common module supplies pending-new/venue-reject and pending-
cancel/fill/reject/partial-confirmation lifecycle. The new capability is that
lifecycle, with real reuse of existing accounting and decoder implementations.

Official Nasdaq OUCH4.2 PDF, Updated October2025:
https://www.nasdaqtrader.com/content/technicalsupport/specifications/TradingProducts/OUCH4.2.pdf
Fetched read-only HTTPS this session:261630bytes, SHA256
037c818d954af7299690ecc5d94f094f730171e05f741a6c7c4f0ace75a244ce.
It defines14-byte tokens, accepted/executed/canceled/rejected messages and
their quantity fields. This service adds an explicit application lifecycle;
it does not claim complete OUCH conformance or derive cancellation confirmation
from outbound request delivery. Nasdaq copyright2025; PDF/text not redistributed.

External open-source comparison only:
https://github.com/gitter-badger/OUCH/tree/3b63e8401b69a5244bf5a2301d38271ff07892e4
src/ouch.hpp fetched read-only HTTPS:18352bytes, SHA256
663c1754d709991ccf6d6cd541815ce36d658b12e13222001d276839059129a3.
The MIT2015 Carriez SDK corroborates full token storage and event layout concepts;
its obsolete layouts/signed integer macros are not treated as current authority.
No external code, script or model is imported, executed or copied. The search
service returned infrastructure HTTP500; direct primary URL retrieval succeeded.

Root independently confirmed these files were100644 blobs in baseline Git.
This worker did not invoke Git. Exact unchanged actual RTL dependencies:

| Path from repository root | SHA256 |
| --- | --- |
|cores/storage/position_limit_reservations/rtl/position_limit_reservations.sv|583580cbccc6deed93f21278732368d64d6a7145bff9e0ea1cd0e61809ad9227|
|cores/system/common_scaffold/memory/src/cip_sync_sp_ram.v|04c0fe8416308c7e9a295d582dc7fee5fd8bbadf2fe4e745632543588c4f7619|
|cores/communication/nasdaq_ouch42_server_rx/rtl/nasdaq_ouch42_server_rx.sv|8fdfbb4a7f24fb5b6e0eec8a4a62dc80050b5c1c18de59e4046469eee4b52ca1|

All new RTL/model/TBs/runner/documents are original Apache-2.0 work. Shared
dependencies retain their existing license/provenance. No mature source changed.
