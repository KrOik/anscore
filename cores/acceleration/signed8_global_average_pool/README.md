# Signed8 channel-wise global average pool

`signed8_global_average_pool` reduces a signed8 spatial feature map to one exact
rounded mean per channel. Input is pixel-major, channel-minor (NHWC without a
batch axis); `cmd_pixels` is the product of spatial dimensions. For channel c:

```
sum[c] = sum_p signed8(input[p,c])
mean[c] = RNE(sum[c] / cmd_pixels)
```

There is one rounding after the exact sum. Negative ties round to even. No
affine zero point, rescaling, activation, local window pooling or float behavior
is implied. `m_sum` exposes the exact signed24 sum; `m_inexact` means a nonzero
division remainder, even when the rounded result equals a neighboring integer.
Every mean lies in signed8, so no saturation is required.

One clock, synchronous active-high reset, ordinary valid/ready, no CE or CDC.
All transfers occur at a rising edge with both valid and ready high. Reset
cancels all ownership, blocks public transfers, clears valid state and leaves
RAM payload unreset. Hold source fields while blocked; all output and response
fields remain stable under arbitrary stalls. No gap or backpressure timeout.

Static ranges: MAX_CHANNELS1..64 (default16), MAX_PIXELS1..65536 (default256),
TAG_W1..32 (default16). Unsupported static parameters elaborate a named missing
module. Runtime pixels1..MAX_PIXELS, channels1..MAX_CHANNELS; bad dimensions
return error1 without input transfers. Dimensions and opaque tag latch on the
command transfer. Only one command may own the core through held completion.

Supply exactly pixels*channels samples. LAST is true only on the final sample.
A LAST mismatch consumes that offending sample and immediately returns error2,
without outputs; the caller owns and discards its unsent suffix. No drain,
replay or implicit frame boundary is provided. All samples of the first pixel
overwrite their channel sums, so later frames/reset cannot reuse stale RAM.

Outputs run channel0..channels-1. `m_last` marks the final channel. Completion
is a separate held response and waits for all outputs to retire. `rsp_error`:
0 success,1 dimensions,2 LAST mismatch,3 unexpected divide-by-zero. `rsp_inputs`
counts actual accepted samples (including an offending marker), `rsp_outputs`
actual retired outputs; `rsp_tag` is the accepted tag. Error3 is defensive and
can imply partial output; no rollback. Runtime configuration is only the command.

The payload RAM has one synchronous access per clock. Input accepts every two
clocks without source gaps (read/latch then add/write). The unsigned24 restoring
divider is shared across output channels: 24 calculation clocks, then explicit
round/hold. From final input transfer, first output valid is 29 clocks later;
always-ready channel retirement intervals are 29 clocks. For a new transaction,
command-to-final-output retirement is 2*P*C+29*C clocks, followed by a separate
response edge and next-command ownership turnaround. Backpressure adds directly.
These are RTL cycle budgets to check, not measured frequency or board throughput.

`example/pooled_int4_classifier.sv` is a real connection to unchanged resident
INT4 matvec. Boot writes four weight/metadata records, then a command pools four
feature channels and emits two signed8 logits:
`sat8(mean0+mean1)`, `sat8(mean2-mean3)`. XOR128 maps signed8 means to U8 and the
matrix uses input zero128. Classifier `m_clip` reports logit saturation;
`m_inexact` belongs to its scale1/shift0 stage (always zero), not pool division.
The pool is prechecked after the matrix is ready to load. Completion waits for
the pool response and final class retirement. LAST error flushes both children;
after the response retires the matrix is boot-configured again. Example has no
host weight configuration; it demonstrates actual stream sequencing and error
cancellation rather than trained model accuracy. Reset also restarts boot.

`files.f` is the offline core closure; `example/files.f` explicitly lists the
full composed closure (no nested recursive file lists). Compile from this package
directory. No generated weights, ROM, remote service or external memory is used.

Initial state is RTL_CANDIDATE / INTEGRATION_CANDIDATE / HW_UNVERIFIED. The frozen
finite plan, raw receipts and QUALIFICATION.json establish the eventual scoped
source-check status. No synthesis, PnR, STA, board, PPA or inherited regression.
