// Tang Primer 25K board harness top: on-chip stimulus + the frozen harness.
//
// The dock's USB-UART bridge cannot drive the FPGA's RX pad (see stim_25k.v), so
// a case ROM drives the harness's own uart_rx from inside the fabric and the
// report stream leaves over the working TX direction.  The harness module itself
// is the silicon-proven 20K one, instantiated unchanged apart from CLK_FRE.
//
//   FAMILY=0 dsp_stream_harness (BLK1/RES1)   FAMILY=1 isp_stream_harness (IMG1/IMR1)
//   FAMILY=2 block_harness       (BLK1/RES1)
//   FAMILY=3 image_harness       (IMG1/IMR1) -- CSC -> morphology delivery chain
//   FAMILY=4 dsp_chain_harness   (DSC1/DST1) -- DC -> statistics delivery chain
module rom_harness_25k #(
    parameter FAMILY = 0,
    parameter CORE = 0,
    parameter BITS = 8,
    parameter PAD_MODE = 1,
    parameter integer CLK_FRE = 50,
    parameter NCASE = 4,
    parameter MEM_IMPL = 0,
    parameter [31:0] SEED = 32'HA5A5_1234)(
    input wire clk,
    input wire uart_rx_pin,          // pad B3: unused here, kept for the CST
    output wire uart_tx,
    output wire dbg_uart);

reg [12:0] por = 0;
always @(posedge clk) if (!por[12]) por <= por + 1'b1;
wire rst_n = por[12];

wire stim_tx;
wire stim_done;
localparam [31:0] MAGIC = (FAMILY == 4) ? "DSC1"
    : (FAMILY == 1 || FAMILY == 3) ? "IMG1" : "BLK1";
// the DC -> statistics chain packet carries one 16-bit sample per case word
localparam integer BPE = (FAMILY == 4) ? 2 : 4;

stim_25k #(.CLK_FRE(CLK_FRE), .SEED(SEED), .MAGIC(MAGIC), .NCASE(NCASE),
            .BPE(BPE)) stim(
    .clk(clk), .rst_n(rst_n), .report_line(uart_tx), .tx_pin(stim_tx),
    .done(stim_done));

// hold the receiver in its idle level until the ROM has come out of reset.  ANDing
// with pad B3 keeps that input loaded (it is pulled up, so undriven it reads 1 and
// the ROM has the line to itself) instead of leaving a CST-assigned pin dangling.
wire rx_drive = rst_n ? (stim_tx & uart_rx_pin) : 1'b1;

generate
if (FAMILY == 0) begin: g_dstream
 dsp_stream_harness #(.CORE(CORE), .CLK_FRE(CLK_FRE), .MEM_IMPL(MEM_IMPL)) dut(
  .clk(clk), .uart_rx_pin(rx_drive), .uart_tx(uart_tx), .dbg_uart());
end else if (FAMILY == 1) begin: g_isp
 isp_stream_harness #(.CORE(CORE), .BITS(BITS), .PAD_MODE(PAD_MODE),
                      .CLK_FRE(CLK_FRE)) dut(
  .clk(clk), .uart_rx_pin(rx_drive), .uart_tx(uart_tx), .dbg_uart());
end else if (FAMILY == 3) begin: g_chain
 image_harness #(.BITS(BITS), .PAD_MODE(PAD_MODE), .MEM_IMPL(MEM_IMPL),
                 .CLK_FRE(CLK_FRE)) dut(
  .clk(clk), .uart_rx_pin(rx_drive), .uart_tx(uart_tx), .dbg_uart());
end else if (FAMILY == 4) begin: g_chaindsp
 dsp_chain_harness #(.CLK_FRE(CLK_FRE)) dut(
  .clk(clk), .uart_rx_pin(rx_drive), .uart_tx(uart_tx), .dbg_uart());
end else begin: g_block
 block_harness #(.CORE(CORE), .BITS(BITS), .MEM_IMPL(0), .CLK_FRE(CLK_FRE)) dut(
  .clk(clk), .uart_rx_pin(rx_drive), .uart_tx(uart_tx), .dbg_uart());
end
endgenerate

assign dbg_uart = uart_tx;

endmodule
