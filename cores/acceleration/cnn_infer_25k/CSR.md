# Complete inference CSR and trace readback

One outstanding32-bit transaction. Responses hold data/error/valid until ready;
only aligned,full-strobe writes are accepted. Unknown accesses return errors.
`cnn_control.v` stores all10597 layer values in a synchronous32-bit trace RAM,
indexed in stage-major order. The engine's tap sink is always ready; host reads
do not stall inference. A new run invalidates readback until successful completion.

| Address | Read | Write |
|---|---|---|
| 00 | ID434e4e31 | error |
| 04 | bit0 loader ready,1 start ready,2 done;bits7:4 engine error | error |
| 08 | loader region | 0input,1weights,2biases;resets load cursor0;idle only |
| 0c | load cursor | unsigned16 address;idle only |
| 10 | error | load one word;cursor increments only on successful engine ACK |
| 14 | error | 1start,2acknowledge completion;wrong state/value errors |
| 18 | run cycles | error |
| 1c | captured layer word count | error |
| 20 | engine error | error |
| 24 | trace read cursor | 0..10596 |
| 28 | registered trace data;cursor increments,saturates at10596 | error |
| 30/34 | build fingerprint low/high32 | error |

Trace offsets: conv1_acc0,conv1_quant3136,pool16272,conv2_acc7056,
conv2_quant8624,pool210192,scores10584,Top310594. Values are as specified in
ENGINE.md. Trace reads require held successful completion and count10597.
Load data uses low8bits for image/weights,and full32bits for biases.

`test_control.py` evidence `control_20261020T190709765497Z` PASS: three complete
inferences,one loaded weight set,31791 exact CSR readback words,read
cursor controls,held replies,failed-load cursor retention,partial/unaligned/
unknown accesses,busy-state rejection and build-ID readout. It is CSR simulation,
not physical UART/JTAG acceptance.

`examples/25k/cnn_top.v` reuses unchanged sys_uart and uart_csr_transport for
supplementary UART control. Pins copy the verified25K mapping:50MHzE2,TXC3,
RXB3,CH0..7 G5,F5,G8,G7,H7,H8,J5,H5. It is not a hard-user-JTAG wrapper.
Probe bits0..7: registered req_ready,req_valid,loader accept,start accept,
layer tap valid,start_ready,done_valid,error. Observation delay is one clock.

`build_board.py` freezes all inputs and embeds a64-bit SHA256-derived source/
configuration fingerprint. This identifies the supplied build configuration;
it is neither the entire bitstream hash nor a cryptographic hardware attestation.
The full packed-image hash is stored separately. Default unbuilt RTL ID0 means
unspecified. Board synthesis/P&R/pack never automatically downloads an image.
