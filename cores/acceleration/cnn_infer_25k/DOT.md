# Signed streaming dot product

`rtl/int8_dot_stream.v` is a narrow new arithmetic boundary for this model.
The legacy PE accepts unsigned activations and has no matching transaction or
error boundary; the ip_series MAC shifts each product. Neither is replaced or
modified. The new module computes bias+sum(signed8 x signed8) without shifting.

Commands latch a signed32 bias and1..392terms. Each accepted sample supplies
both operands and an exact last marker. One multiplier register feeds a signed
accumulator; continuous input accepts one pair per clock. The last product is
drained before one held result/error response. No new command or sample is
accepted while that response waits. Reset aborts the active transaction.

Error1: invalid length;2: early/missing last;3: signed32 overflow. Error results
are zero. Overflow never silently wraps into a valid output. A failed transaction
aborts remaining samples; the caller must stop the frame and await the response.
This is an explicit abort contract,not successful consumption of the whole dot.

`python cores/acceleration/cnn_infer_25k/tools/test_dot.py` after sourcing scripts/env.ps1:
dot_20261020T185543965235Z PASS47responses,392continuous beats/II1,random signed
operands,input gaps,bias latching,response stalls,framing/length/overflow,
mid-dot reset and clean recovery. The TB uses an independent direct signed sum.

Isolated synthesis dot_synth_20261020T185605388105Z PASS GW5A mapping:
292LUT1..4,95ALU,119FF,8MUX2_LUT5,0DSP/BSRAM. Top-level pad counts belong to
the isolated interface and are not the eventual board pin count. The installed
Yosys GW5A flow implements this multiplier in logic. No routed frequency or
full-CNN throughput claim follows; model scheduling and memories remain open.
