`timescale 1ns/1ps
module tb_i2c_dbg;
reg clk = 1'b0, rst_n = 1'b0;
reg [3:0] ce_div = 0;
wire ce = (ce_div == 4'd15);
always #5 clk = ~clk;
always @(posedge clk) ce_div <= ce_div + 1;

reg start = 0;
reg [7:0] txd = 0;
reg txv = 0;
wire sda_oe_m, scl_oe_m, sda_oe_s, scl_oe_s;
wire sda = ~(sda_oe_m | sda_oe_s);
wire scl = ~(scl_oe_m | scl_oe_s);
wire tx_ready, busy, done, nack, rx_valid;
wire [7:0] rxd;
wire [7:0] cap_byte; wire [4:0] slv_cnt;
reg [3:0] cap_sel = 0;

i2c_master #(.QDIV(64)) m (
    .clk(clk),.rst_n(rst_n),.clk_en(ce||!rst_n),
    .start(start),.addr(7'h42),.rw(1'b0),.len(5'd2),
    .tx_data(txd),.tx_valid(txv),.tx_ready(tx_ready),
    .rx_data(rxd),.rx_valid(rx_valid),.rx_ack(1'b0),
    .busy(busy),.done(done),.nack(nack),
    .sda_in(sda),.scl_in(scl),.sda_oe(sda_oe_m),.scl_oe(scl_oe_m));
i2c_slave_model #(.ADDR(7'h42),.STRETCH_BYTE(4'd1),.STRETCH_TICKS(16'd2000)) s (
    .clk(clk),.rst_n(rst_n),.stretch_en(1'b0),
    .sda_in(sda),.scl_in(scl),.sda_oe(sda_oe_s),.scl_oe(scl_oe_s),
    .cap_sel(cap_sel),.cap_byte(cap_byte),.byte_cnt(slv_cnt),.addr_seen());

// trace state transitions
reg [4:0] m_st_d = 0;
reg [3:0] s_st_d = 0;
always @(posedge clk) begin
    if (m.state != m_st_d) $display("%0t M %0d->%0d bit_cnt=%0d byte_cnt=%0d shift=%02x", $time, m_st_d, m.state, m.bit_cnt, m.byte_cnt, m.shift);
    if (s.state != s_st_d) $display("%0t S %0d->%0d bit_cnt=%0d shift=%02x sda=%b scl=%b", $time, s_st_d, s.state, s.bit_cnt, s.shift, sda, scl);
    m_st_d <= m.state; s_st_d <= s.state;
    if (s.scl_rise) $display("%0t SLV rise sda=%b bit_cnt=%0d st=%0d", $time, s.sda_s, s.bit_cnt, s.state);
    if (m.state==5 && s.scl_s==0 && !busy==0) ;
    if (m.qcnt==63 && m.state==4) $display("%0t M set sda=%b for bit %0d", $time, ~m.shift[7], m.bit_cnt);
end

initial begin
    repeat(10) @(posedge clk); rst_n <= 1;
    repeat(100) @(posedge clk);
    start <= 1; wait(busy); @(posedge clk); start <= 0;
    // feed two bytes when asked
    wait(tx_ready); txd <= 8'hDE; txv <= 1;
    wait(!tx_ready); @(posedge clk); txv <= 0;
    wait(tx_ready); txd <= 8'hAD; txv <= 1;
    wait(!tx_ready); @(posedge clk); txv <= 0;
    wait(done);
    $display("done nack=%b slv_cnt=%0d cap0=%02x cap1=%02x", nack, slv_cnt,
             s.cbuf[0], s.cbuf[1]);
    repeat(100) @(posedge clk);
    $finish;
end
initial begin
    repeat(3000000) @(posedge clk);
    $display("TIMEOUT m.state=%0d s.state=%0d", m.state, s.state);
    $finish;
end
endmodule
