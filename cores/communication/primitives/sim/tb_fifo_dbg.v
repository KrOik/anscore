`timescale 1ns/1ps
module tb_fifo_dbg;
reg clk = 1'b0, rst_n = 1'b0;
reg rdclk = 1'b0;
always #5 clk = ~clk;
always @(posedge clk) rdclk <= ~rdclk;

reg [5:0] wi = 0;
reg [7:0] fc = 0;
reg fseen = 0;
wire full, empty;
wire [7:0] dout;
wire [7:0] din = (wi << 5) - (wi << 1) - wi + 8'd5;
wire wren = (wi < 6'd40) && !full;
wire rdgo = (wi >= 6'd24) || (fc > 8'd32);
reg rden = 0, rdpend = 0;
reg [1:0] rdgo_s = 0;
reg [5:0] rcnt = 0;
reg [31:0] dg = 32'h811c9dc5;

fifo_async #(.DW(8),.AW(4)) f (
    .wr_clk(clk),.wr_rst_n(rst_n),.wr_en(wren),.din(din),.full(full),
    .rd_clk(rdclk),.rd_rst_n(rst_n),.rd_en(rden),.dout(dout),.empty(empty));

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin wi<=0; fc<=0; fseen<=0; end
    else begin
        if (wren) wi <= wi + 1;
        if (full && wi < 40) begin fseen <= 1; if (fc != 8'hFF) fc <= fc + 1; end
    end
end

always @(posedge rdclk or negedge rst_n) begin
    if (!rst_n) begin rden<=0; rdpend<=0; rdgo_s<=0; rcnt<=0; end
    else begin
        rdgo_s <= {rdgo_s[0], rdgo};
        rden <= 0;
        if (rdpend) begin rdpend <= 0; rcnt <= rcnt + 1; end
        else if (rdgo_s[1] && !empty && rcnt < 40) begin rden <= 1; rdpend <= 1; end
    end
end

always @(posedge clk) begin
    if (rst_n && (wren || full || rdgo || rcnt != 0) && ($time % 20000 < 10))
        $display("%0t wi=%0d full=%b fc=%0d rdgo=%b empty=%b rcnt=%0d dout=%02x rptr=%0d wptr=%0d",
                 $time, wi, full, fc, rdgo, empty, rcnt, dout, f.rptr_bin, f.wptr_bin);
end

initial begin
    repeat(10) @(posedge clk); rst_n <= 1;
    repeat(3000) @(posedge clk);
    $display("final wi=%0d rcnt=%0d fseen=%b", wi, rcnt, fseen);
    $finish;
end
endmodule
