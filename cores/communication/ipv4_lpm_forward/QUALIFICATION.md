# Finite qualification

First execution PASS:11 HDL children,4 completed simulations and4 isolated
archived oracle preparations. There were zero planning oracle calls, failures,
timeouts, retries or inherited regression runs. Hardware is HW_UNVERIFIED.

Three core configurations ROUTES/TAG_W=1/1,3/8,128/32 checked697 vector records
(409 packet goldens,282 admin goldens,6 reset records),462 real future command
acceptances,33 resets,12 live reset phases,3 priority checks and3 injected helper
faults with recovery. Hold monitors cover both input sources and both outputs.
The actual four-slot bootstrap fixture checks50 packet vectors in two epochs,
then cancels a held result and requires fresh real route initialization and
correct replay. Its101 retired results include the recovery result.

The recorded core scans include the full128-slot configuration and both valid
received checksum zero representations. Shared source bytes remain identical
to baseline. The longest core simulation was78989 clocks; this is a finite
observation, not Fmax or a physical packet-rate claim. The fixture supplies no
Ethernet/ARP/ICMP/MTU/options/payload datapath, as specified in README.

All17 source/archive mappings,30 raw streams,4 vector/summary pairs,3 tools,
4 retained images, exact process arguments/order/budgets and review-field-only
plan change were independently checked without importing a checker or model.
Full hashes are in EVIDENCE_AUDIT.json and B43_DELIVERY.json. All success images
remain task-local outside Git; no deletion or alternate cleanup was attempted.
