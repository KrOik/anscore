# Delivery

This package adds true store-forward payload shaping around three unchanged
canonical dependencies: multiflow_token_shaper, cip_sync_sp_ram and
cip_sync_fifo. It stores one packet per flow, counts asserted KEEP bytes,
publishes only complete LAST-terminated packets and charges the full cost only
on actual output SOP transfer. The selected flow remains locked through actual
LAST. Invalid, disabled, empty and overlength packets, and packets whose byte
cost exceeds capacity, are drained and reported without output payload.

Use files.f from the package root for the core, or example/files.f for the
actual fixed four_class_payload_tx composition. All sources are present offline.
The core supports FLOWS 1..8, DATA_W 8/16/32/64, MAX_BEATS 1..512, TOKEN_W 1..24,
TAG_W 1..16 and QUANTUM 1..1024, with maximum packet bytes fitting TOKEN_W.
README.md gives the complete handshake, response, reset and cost contract;
ARCHITECTURE.md records resource choices and source-derived schedules;
SOURCES.md records pre-authoring external comparison/license inspection.

QUALIFICATION.json and QUALIFICATION.md contain the final finite outcome.
The original one-attempt failure is retained unchanged. The separately reviewed
followup01 passes all three core profiles and the actual four-class example,
using the original vectors with no new preparation. Both old and new controls,
raw output, immutable initial/terminal/validated records and original images
are retained. No automatic retry or deletion occurred.

The default RAM payload is 10 KiB and the maximum 36 KiB, before small FIFO and
metadata overhead. Those are structural estimates. Hardware remains
HW_UNVERIFIED; no synthesis, PnR, STA, board or PPA evidence is claimed.
