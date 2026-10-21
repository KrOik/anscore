# Host configuration and numerical acceptance

`tools/run_uart.py` stages the16word atomic config and verifies a finite UART
run. `tools/isp_host.py` reuses the existing buffer_dma UART command/reply codec
unchanged via import; it does not maintain a second wire-protocol copy.
The reusable helpers also accept an abstract bus for simulation/fixtures.

Supported numerical configuration: four black levels and target,three Q8.8
RGB gains,signed16 row-major CCM3x3 plus RGB biases,Gamma off or host-loaded
complete identity LUT,all4Bayer patterns and all stage bypass flags. The physical
top is RAW10; the Python API also supports RAW8/10/12. Nonidentity Gamma tables
remain unsupported by this host runner and are covered by separate RTL tests.
CLI --black-levels (4 values),--blc-target,--gains (3 values),--matrix (12 values)
set the corresponding atomic words. Limits are checked before opening serial.

Before opening UART,the runner requires a successful50MHz25K build summary,
verifies the packed image hash,and checks every recorded source/CST/build-script
hash against current files. This validates the supplied artifact,not the image
currently loaded in hardware. No hardware fingerprint readback is implemented
yet;`loaded_image_hash_verified` therefore remainsfalse. UART CSR ID alone does
not identify the FPGA device. Identify the actual25K through JTAG before
programming and preserve that separate evidence.

The runner requires an idle subsystem with no queued config,optionally loads
768identity LUT entries,sets the probe page,stages config and commits once.
It waits for the applied version to match the submitted run,not a stale done
bit. Each polling capture reads both snapshot pages and checks snapshot IDs
before/after. The selector is restored after reading. It saves UART exchanges,
latest raw snapshot,decoded metrics and a terminal report even on failure.

Acceptance checks ready/done/noerror,no deadline/command stalls,exact completed
frames/output bytes/output frames,cumulative/last-frame CRC32,latest RGB sums,
RGB dimensions/frame ID,source frame ID and modes. Pixel stalls are permitted
and recorded. Source-frame pacing and actual external timing still require
the separate LA/JTAG acceptance. The run ends at the last response,not after
a final blanking period;do not infer average fps from frames/run_cycles alone.

Example after a successful build and separately confirmed SRAM download:

```powershell
python cores/image_processing/isp_stream/tools/run_uart.py --port COMx --build-summary artifacts/isp_stream_25k/board_<timestamp>/summary.json --output artifacts/isp_board_<unique> --width 320 --height 240 --frames 3
```

Use `--width 640 --height 480` to test the larger chain;default frame period is
1666667clocks at50MHz. `--center-bypass`, `--gamma-identity`, `--pattern 0..3`
and `--probe-page 0..3` select runtime modes. Each output directory must be new.
The runner rejects configurations exceeding its32-bit counter interpretation.
It does not program the board and has not been run on physical25K hardware.
UART is supplemental and cannot close the mandatory hard-user-JTAG gate.

## Hardware-free verification

```powershell
python cores/image_processing/isp_stream/tools/test_host.py
python cores/image_processing/isp_stream/tools/run_uart.py --help
```

Evidence `host_20261020T181920534896Z` PASS: reused codec with fragmented reads,
bad CRC/status rejection,exact config staging,single commit/selector retention,
identity LUT768entries,two simulation-derived pixel/CRC/RGB fixtures,
snapshot provenance/coherence/reserved bits checks and corrupted numerical
metrics rejection. The fixture preserves actual accepted payload bytes from
`control_20261020T180930042929Z`;unobserved timing words are explicitly synthetic
zero. The test labels itself simulation_fixture and physical_measurement=false.
It is host-test evidence,not a fabricated board run.

## Extended bypass flags

The CLI also accepts --blc-bypass,--bayer-bypass,--awb-bypass,--ccm-bypass.
The golden model and snapshot acceptance cover the full low8 flag byte,
including Bayer pattern. Configurable BLC/gains/CCM are now supported as above.
Bayer center bypass changes the golden pixel data.
`host_20261020T183553965028Z` PASS covers10 simulation-derived fixtures,
including8 full-chain bypass cases. Timing fields remain explicitly synthetic
zero; no physical UART execution is claimed. Current build/source hash checks
reject an older baseline image when its source hashes differ from the worktree.

Current evidence: host_20261020T184437729451Z PASS the10 original fixtures;
host_parameters_20261020T184506340923Z PASS all64 retained RTL mode payloads,
observed CSR CRC/RGB sums,nonzero black levels,nonunity gains,signed CCM,
configuration packing/staging and invalid ranges. Other fixture metric words
are explicitly synthetic; these are not physical UART runs.
Command: python cores/image_processing/isp_stream/tools/test_host_parameters.py
