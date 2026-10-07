`timescale 1ns/1ps
// tb_st_img_scaler -- standalone TB for st_img_scaler (TAG SCL).
module tb_st_img_scaler;
    localparam NBYTES = 1280;    // 16x16 downscale + 32x32 upscale
    localparam [31:0] EXP = 32'hA34F3413;
    localparam TIMEOUT = 600000;

    reg clk = 0;  always #5 clk = ~clk;
    reg rst_n = 0;
    reg [3:0] ced = 4'd0;
    wire ce = (ced == 4'd15);
    always @(posedge clk) ced <= ced + 4'd1;

    reg         start = 0;
    wire        done, pass;
    wire [31:0] digest;
    wire [15:0] cycles;
    st_img_scaler dut (.clk(clk), .clk_en(ce), .rst_n(rst_n), .start(start),
                       .done(done), .pass(pass), .digest(digest),
                       .cycles(cycles));

    reg [7:0] golden [0:NBYTES-1];
    integer n = 0, errs = 0, fd, to;
    initial $readmemh("sim/golden_img_scaler.txt", golden);

    always @(posedge clk) begin
        if (rst_n && ce && dut.o_valid === 1'b1) begin
            $fwrite(fd, "%02x\n", dut.o_byte);
            if (n >= NBYTES) begin
                errs = errs + 1;
                $display("EXTRA byte %02x at n=%0d", dut.o_byte, n);
            end else if (dut.o_byte !== golden[n]) begin
                errs = errs + 1;
                if (errs < 20)
                    $display("MISM n=%0d got=%02x exp=%02x",
                             n, dut.o_byte, golden[n]);
            end
            n = n + 1;
        end
    end

    initial begin
        fd = $fopen("sim/dump_img_scaler.txt", "w");
        repeat (8)  @(posedge clk); rst_n <= 1;
        repeat (20) @(posedge clk); start <= 1;
        repeat (20) @(posedge clk); start <= 0;
        for (to = 0; to < TIMEOUT && !done; to = to + 1) @(posedge clk);
        repeat (40) @(posedge clk);
        $fclose(fd);
        if (!done)               $display("W2TB SCL FAIL timeout");
        else if (n != NBYTES)    $display("W2TB SCL FAIL nbytes=%0d exp=%0d", n, NBYTES);
        else if (errs != 0)      $display("W2TB SCL FAIL errs=%0d", errs);
        else if (digest !== EXP) $display("W2TB SCL FAIL D=%08X exp=%08X", digest, EXP);
        else if (pass !== 1'b1)  $display("W2TB SCL FAIL pass=0 D=%08X", digest);
        else                     $display("W2TB SCL PASS D=%08X C=%d", digest, cycles);
        $finish;
    end
endmodule
