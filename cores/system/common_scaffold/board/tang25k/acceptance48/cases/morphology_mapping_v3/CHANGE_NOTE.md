# Morphology address-pipeline candidate

Candidate only; production sources are unchanged.

- scratch RAM: merge the two mutually exclusive synchronous reads into one explicit read-enable/address mux. The write port is unchanged.
- Register the clamped neighborhood address during READ; MEM_READ performs the existing synchronous RAM access; REDUCE consumes its output. This adds one enabled clock per neighborhood tap, preserves CE/backpressure and all five operations, and maintains synchronous BRAM storage.
- Isolated board self-test driver reset uses synchronous processes, matching the already qualified window candidate. No public module reset interface changes.

Verification: seven UART normal/fault/watchdog simulations PASS and all ten original independent morphology profiles (five data widths, direct/helper and public adapter) PASS. Expected values are unchanged.

Commands:
```
python cores/system/common_scaffold/board/tang25k/acceptance48/make_morph_address_case.py cores/system/common_scaffold/board/tang25k/acceptance48/cases/morphology_mapping_v1 cores/system/common_scaffold/board/tang25k/acceptance48/cases/morphology_mapping_v3
python cores/system/common_scaffold/board/tang25k/acceptance48/build_case.py cores/system/common_scaffold/board/tang25k/acceptance48/cases/morphology_mapping_v3 --attempt morph_addr_20261018 --no-lutram
```

Resources: 1835 LUT4, 375 FF, 2 BSRAM, 0 DSP. Routed setup 50.14 MHz at requested 50 MHz; placement estimate 62.27 MHz. All setup/resource/route gates pass. Hold timing remains unproven; no explicit violation is reported. The builder exits 1 because of that hold gate; no bitstream was packed/programmed by this agent. Actual functional board validation belongs to root.
