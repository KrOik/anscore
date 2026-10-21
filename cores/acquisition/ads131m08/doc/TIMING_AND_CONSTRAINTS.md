# Timing and constraints

The IP uses one `clk` domain. SPI timing is generated synchronously from that
clock; there is no CDC wrapper. The 20K bring-up target is GW2A-
LV18PG256C8/I7 at 27 MHz. Its scalar wrapper and CST are
`src/ads131m08_pads_top_20k.v` and `constr/tang20k_ads131m08_ip.cst`.

The 20K route gate passed on 2026-09-13 with Fmax 287.94 MHz and no
unconstrained IO. The 25K CST is `reference-only`: it is a template based on
the official breakout mapping and has no physical-board evidence. It must not
be labelled hardware verified.

Run `scripts/harness.ps1 pnr -Board tang20k -AdcCount 1` to reproduce the 20K
route evidence. Board programming and electrical SPI measurements remain
deferred.
