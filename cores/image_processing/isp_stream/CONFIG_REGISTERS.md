# ISP atomic configuration CSR

`isp_config_registers.v` reuses `production_system_ip_25k/rtl/sys_atomic_config.v`
unchanged with16words. The adapter provides one outstanding CSR transaction.
Responses hold valid/data/error under backpressure; a held response never
reexecutes its request. Only aligned32-bit writes with all four strobes are
accepted. Unknown/read-only addresses and invalid operations return an error.

| Address | Read | Write |
|---|---|---|
| 0x00 | bit0 cfg_ready,bit1 pending,bit2 cfg_valid | error |
| 0x04 | applied configuration version | value1 commits all shadow words |
| 0x08 | ID0x49535031 | error |
| 0x20..0x5c | shadow words0..15 | update corresponding word |
| 0x80..0xbc | applied words0..15 | error |

| Word | Bits/meaning |
|---|---|
| 0 | width[15:0],height[31:16] |
| 1 | number of frames |
| 2 | frame period in clocks |
| 3 | RAW seed,zero extended |
| 4 | bit0 BLC bypass,bit1 Gamma enable,bit2 Sobel center bypass,bit3 Bayer center bypass,bits5:4 Bayer pattern,bit6 AWB bypass,bit7 CCM bypass;upper24 reserved zero |
| 5 | BLC target,zero extended |
| 6..7 | four16-bit black levels,in increasing plane order |
| 8..9 | three16-bit Q8.8 RGB gains;word9 upper16bits reservedzero |
| 10..15 | twelve16-bit signed CCM coefficients: row-major3x3 then RGB biases |

Commit validates dimensions>=5,width<=MAX_WIDTH,nonzero frame count,
period>=2,RAW seed/target/levels within RAW_BITS and reserved flag/gain bits
zero. Reset clears all words,so the host must stage a valid configuration.
Gamma completeness remains a pipeline-level check; this adapter does not
load the LUT or silently disable Gamma.

The canonical block snapshots a commit and applies only when cfg_ready is
high. cfg_version increments once at application. The adapter then raises
cfg_valid with the complete512-bit cfg_words bus; that bus/valid remain held
until accepted. Shadow writes and another commit are rejected from submission
through this command handshake,including the cycle between canonical apply
and the adapter observing its version. Shadow writes after acceptance do not
change the active configuration. cfg_ready must represent the downstream
runner's safe admission point. This module alone does not start an ISP run.

Test after sourcing scripts/env.ps1:

```powershell
python cores/image_processing/isp_stream/tools/test_config.py
```

Evidence `config_20261020T183056126132Z` PASS: all16words staged/read back,
unsafe commit deferred with old active unchanged,atomic application,20cycle
held configuration,blocked writes/duplicate commit,all16active reads,
immediate application while responses stall,exactly-once command accounting,
invalid configuration/flags,unaligned/partial/read-only/unknown accesses.
The low8 flag bits are integrated with source/ISP,LUT CSR,coherent metrics and
registered probes in isp_control. Acceptance of bits3/6/7 intentionally extends
the earlier protocol; the reserved-flag rejection test now exercises bit8.
No physical acceptance or final resource/Fmax claim follows from this test.
