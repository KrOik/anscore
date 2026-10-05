`timescale 1ns/1ps
// Focused fft64 unit test: load each selftest vector, run, dump re/im per bin.
module tb_fft64;

reg clk = 1'b0;
reg rst_n = 1'b0;
always #5 clk = ~clk;

reg signed [15:0] costab [0:31];
initial $readmemh("fft64_cos.mem", costab);

function signed [15:0] stim_fft;
    input [1:0] v;
    input [5:0] n;
    reg [5:0] ci;
    reg signed [15:0] c;
    begin
        case (v)
            2'd0: stim_fft = (n == 6'd0) ? 16'sd16384 : 16'sd0;
            2'd1: stim_fft = 16'sd4096;
            2'd2: begin
                ci = {n[3:0], 2'b00};
                c  = ci[5] ? -costab[ci[4:0]] : costab[ci[4:0]];
                stim_fft = c >>> 2;
            end
            default: stim_fft = n[0] ? -16'sd8192 : 16'sd8192;
        endcase
    end
endfunction

reg        ld_en, start, rd_en;
reg [5:0]  ld_addr, rd_addr;
reg [1:0]  vec = 2'd0;
wire       busy, done;
wire signed [15:0] rd_re, rd_im;

fft64 dut (
    .clk(clk), .clk_en(1'b1), .rst_n(rst_n),
    .ld_en(ld_en), .ld_addr(ld_addr),
    .ld_re(stim_fft(vec, ld_addr)), .ld_im(16'sd0),
    .start(start), .busy(busy), .done(done),
    .rd_en(rd_en), .rd_addr(rd_addr), .rd_re(rd_re), .rd_im(rd_im)
);

integer k;
integer vi;
integer fd;

// butterfly trace (vec2 only): log operands at S_WRA (compute beat)
always @(posedge clk) begin
    if (rst_n && vec == 2'd2 && dut.st == 3'd3) begin
        $fwrite(fd, "bfly s%d bf%d i%d j%d tw%d a=%d,%d b=%d,%d t=%d,%d oi=%d,%d oj=%d,%d\n",
                dut.stage, dut.bf, dut.idx_i, dut.idx_j, dut.tw_idx,
                dut.a_re, dut.a_im, dut.b_re, dut.b_im,
                dut.t_re, dut.t_im,
                dut.oi_re, dut.oi_im, dut.oj_re_w, dut.oj_im_w);
    end
end

initial begin
    fd = $fopen("sim/dump_fft_bins.txt", "w");
    ld_en = 0; start = 0; rd_en = 0; ld_addr = 0; rd_addr = 0;
    repeat (10) @(posedge clk);
    rst_n <= 1'b1;
    for (vi = 0; vi < 4; vi = vi + 1) begin
        vec = vi[1:0];
        for (k = 0; k < 64; k = k + 1) begin
            @(posedge clk); ld_en <= 1; ld_addr <= k[5:0];
        end
        @(posedge clk); ld_en <= 0;
        // read back raw buffer (bit-reversed storage) before running
        for (k = 0; k < 64; k = k + 1) begin
            rd_en <= 1; rd_addr <= k[5:0];
            @(posedge clk);
            rd_en <= 0;
            @(posedge clk); #1;
            $fwrite(fd, "v%d raw%d %d %d\n", vec, k, rd_re, rd_im);
        end
        start <= 1;
        @(posedge clk); start <= 0;
        wait (busy);                  // start accepted -> done drops low
        wait (done);                  // run complete
        @(posedge clk);
        for (k = 0; k < 64; k = k + 1) begin
            rd_en <= 1; rd_addr <= k[5:0];
            @(posedge clk);            // rd_en/addr visible during this cycle
            rd_en <= 0;
            @(posedge clk); #1;        // q updated, settle NBA
            $fwrite(fd, "v%d k%d %d %d\n", vec, k, rd_re, rd_im);
        end
        rd_en <= 0;
    end
    $fclose(fd);
    $display("tb_fft64 done");
    $finish;
end

initial begin
    repeat (20000) @(posedge clk);
    $display("tb_fft64 TIMEOUT");
    $finish;
end

endmodule
