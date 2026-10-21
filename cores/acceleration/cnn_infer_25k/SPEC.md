# IP-05 complete small INT8 network (development)

Target GW5A-LV25MG121NES,50MHz; no external DDR. Complete scalar inference RTL
passes three inputs against every layer; see ENGINE.md. Physical inference,
25K P&R passes at50MHz;physical inference and measured performance remain open.
The model is a deterministic functional
fixture,not a trained classifier or an accuracy benchmark.

Network: signed INT8 28x28x1 -> same-padded3x3 conv1,4channels -> ReLU/right7/
clamp127 -> maxpool2 ->14x14x4 -> same-padded3x3 conv2,8channels ->
ReLU/right7/clamp127 -> maxpool2 ->7x7x8 -> dense392x10 -> signed32 scores/Top3.
Every convolution and dense dot product starts with signed32 bias and adds
unshifted signed8 products. No intermediate wrap/saturation is allowed; the
converter checks conservative accumulator bounds. Quantization is
min(127,max(0,acc)>>7),with no rounding offset. Top3 sorts descending score,
breaking ties by ascending class index. Padding is mathematical zero.

Tensors are position-major HWC,channel fastest. Conv weights are OIHW (output,
input,kernel y,kernel x); dense weights are output-major then flattened HWC.
Exported byte memories use two's-complement hex; biases and accumulator taps
are32-bit two's-complement. The complete model has4244weight bytes and22biases.
Intermediate conv accumulators,quantized tensors,pools and all10scores are
golden deliverables,not only a final digest. They permit per-layer readback.

Reuse review: existing cnn_infer_138k provides network scheduling/layout
concepts,but its16x9multiplier datapath is not copied into this smaller device.
cnn_systolic_20k PE,pooling and activation will be evaluated individually.
ips_int8_mac_array applies `(product+1)>>>2` per term and saturates each update;
it cannot implement this model unchanged and is not silently substituted.
Existing modules and their contracts remain untouched. Repository distribution
rights remain unresolved; no external weights or RTL are bundled here.

Implemented: bounded synchronous tensor/weight memories,sequential weight
loading,MAC/layer scheduler,ReLU/pool,dense/Top3 and full per-layer simulation.
CSR control/readback and supplementary UART top are implemented;25K route/pack
passes. Remaining: hard JTAG binding,physical per-layer verification,measured
latency/throughput and physical JTAG-controlled acceptance. IP-03 and
IP-04 physical gates remain open independently.
