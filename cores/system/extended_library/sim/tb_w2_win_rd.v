`timescale 1ns/1ps
// Quick sanity TB for w2_dpram + w2_win_rd (shared infra check).
module tb_w2_win_rd;
    localparam IMG_W = 4, IMG_H = 4, K = 3, AW = 4;
    reg clk = 0, rst_n = 0, clk_en = 1;
    always #5 clk = ~clk;

    reg        we; reg [AW-1:0] waddr; reg [7:0] wdata;
    wire       re; wire [AW-1:0] raddr; wire [7:0] q;
    w2_dpram #(.W(8), .DEPTH(16), .AW(4)) ram (
        .clk(clk), .clk_en(clk_en), .we(we), .waddr(waddr), .wdata(wdata),
        .re(re), .raddr(raddr), .q(q));

    reg start = 0;
    wire [K*K*8-1:0] win; wire win_valid, wdone;
    wire [1:0] wx; wire [15:0] wy;
    w2_win_rd #(.K(K), .IMG_W(IMG_W), .IMG_H(IMG_H)) rd (
        .clk(clk), .clk_en(clk_en), .rst_n(rst_n), .start(start),
        .re(re), .raddr(raddr), .q(q),
        .win(win), .win_valid(win_valid), .win_x(wx), .win_y(wy), .done(wdone));

    integer i, errs = 0, nw = 0;
    // expected tap: pixel value = addr*2+1; window tap(r,c) clamps
    function [7:0] imgv; input integer x, y;
        begin imgv = (y*IMG_W+x)*2+1; end
    endfunction
    function integer clmp;
        input integer v;
        input integer m;
        begin clmp = (v < 0) ? 0 : ((v > m) ? m : v); end
    endfunction

    initial begin
        we = 0;
        repeat (4) @(posedge clk); rst_n = 1;
        // load frame: I[y][x] = (y*4+x)*2+1
        for (i = 0; i < 16; i = i + 1) begin
            @(posedge clk); we <= 1; waddr <= i[AW-1:0]; wdata <= i*2+1;
        end
        @(posedge clk); we <= 0;
        start <= 1; @(posedge clk); start <= 0;
        repeat (2000) @(posedge clk);
        if (!wdone) begin $display("W2TB WINR FAIL timeout"); $finish; end
        if (nw != 16 || errs != 0)
            $display("W2TB WINR FAIL nw=%0d errs=%0d", nw, errs);
        else
            $display("W2TB WINR PASS nw=%0d", nw);
        $finish;
    end

    integer r, c;
    always @(posedge clk) if (rst_n && win_valid) begin
        nw = nw + 1;
        for (r = 0; r < K; r = r + 1)
            for (c = 0; c < K; c = c + 1)
                if (win[(r*K+c)*8 +: 8] !==
                    imgv(clmp(wx+c-1,IMG_W-1), clmp(wy+r-1,IMG_H-1))) begin
                    errs = errs + 1;
                    $display("MISM y=%0d x=%0d r=%0d c=%0d got=%02x exp=%02x",
                        wy, wx, r, c, win[(r*K+c)*8 +: 8],
                        imgv(clmp(wx+c-1,IMG_W-1), clmp(wy+r-1,IMG_H-1)));
                end
    end
endmodule
