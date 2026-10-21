# Validation state

Digital RTL regressions and complete25K route/pack pass. No matching25K
download, physical UART/JTAG, LA or external PHY test has been performed for
this subsystem. L3/L5 release claims remain blocked by those missing gates
and the open dependency/license audit.

Current complete target build:
`artifacts/ethernet_udp_25k/board_20261020T200904372694Z`.
Target GW5A-LV25MG121NES,50MHz constraint, achieved106.678MHz.
Final P&R utilization5278LUT4,1782ALU,2971DFF,5BSRAM,11IOB,0PLL/DSP.
Use the final summary JSON utilization, not the earlier placement-stage count.
Fingerprint07162472fe1a28f3; packed image SHA256
`00417c03f79a50b9aa6882044f592fb012199129cc7e00c10ad02eb14991dd7d`.
Frozen inputs/current hashes and packed-image validation were checked after
build. No image was downloaded. PPA_25K.csv records this state.

Run `. ./scripts/env.ps1`, then the tools listed in SPEC.md. Coverage includes
independent network encoder/CRC, empty/odd/max payloads, badFCS/IP/UDP checks,
header/length rejects, random stalls, queued atomic commands, exact counter/
CRC readback, source identity, timeout, reset/recovery and held completions.
Tests have narrower coverage limits documented per module; they do not prove
all possible malformed signals or sustained line-rate application throughput.

The host test reruns actual CSR RTL to obtain numeric fixtures, then rejects
ten corrupted/identity/timeout cases without ACK. The physical UART runner
requires a completed matching build and actual working wiring. It cannot
establish mandatory hard-user-JTAG or external PHY acceptance. A supplied
image hash plus CSR fingerprint does not physically read back every loaded
configuration bit; reports keep loaded_image_hash_verified false.

Pending: real25K controlled replay/JTAG readback and8channelLA evidence;
physical PHY adapter/continuous100Mbps report when hardware is available;
remaining directed fault tests, clean release/license audit and catalog links.
