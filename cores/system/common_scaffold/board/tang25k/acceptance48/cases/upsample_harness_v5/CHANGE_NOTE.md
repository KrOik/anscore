# Upsample qualified setup/resource candidate

Exact DUT is inherited from upsample_registered_borrow_v4. Only isolated acceptance driver and ROM outputs change: synchronous driver from geo_optimized/downsample_v4, five ROM outputs registered, CE_DIV4. Seven UART normal/fault/watchdog simulations PASS after harness modification. DUT reference evidence remains explicitly linked in case.json:348commands,42528outputs,12resets across6width profiles; independent100000random58-bit subtract records PASS. No additional DUT enabled cycles or golden changes.

OSS attempt upsample_harness_20261019: placement67.66MHz, route61.62MHz,6416LUT4,2186FF,3BRAM,0DSP. All route/setup/resource gates PASS. No explicit hold violations; hold model remains UNPROVEN, which causes builder exit1 and NOT_PACKED status. Board pending root, no JTAG performed by this agent. Do not claim final timing signoff.

Exact mapper SHA256:26068615154730f358425c249c8b83ed0d7707ed4fb7c29c89cc81fd764c55a5. Production/shared RTL unmodified. Failed v3/v4 builds retained; temporary binaries and fixtures auto-cleaned.
