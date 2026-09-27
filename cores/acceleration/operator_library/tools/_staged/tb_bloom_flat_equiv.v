// Behavioural equivalence bench for the staged bloom4_update rewrite.
// Drives the release RTL and the staged RTL with identical stimulus through the
// enabled-ready-valid-32x3-v1 handshake and compares result, aux, fault and the
// 256-bit filter register after every accepted beat.
`timescale 1ns/1ps
module tb_bloom_flat_equiv;
reg clk = 0, rst_n = 0, clk_en = 1, in_valid = 0, out_ready = 1;
reg [31:0] a = 0, b = 0, c = 0;
wire [31:0] r_ref, x_ref, r_flat, x_flat;
wire f_ref, f_flat, rd_ref, rd_flat, ov_ref, ov_flat;
integer seed = 32'hB100F117;
integer errors = 0, beats = 0, n;
reg [31:0] ka, kb, kc;

acc_bloom4_update         ref_  (.clk(clk), .rst_n(rst_n), .clk_en(clk_en),
                                .in_valid(in_valid), .in_ready(rd_ref),
                                .a(a), .b(b), .c(c),
                                .out_valid(ov_ref), .out_ready(out_ready),
                                .result(r_ref), .aux(x_ref), .fault(f_ref));
acc_bloom4_update_flat    flat_ (.clk(clk), .rst_n(rst_n), .clk_en(clk_en),
                                .in_valid(in_valid), .in_ready(rd_flat),
                                .a(a), .b(b), .c(c),
                                .out_valid(ov_flat), .out_ready(out_ready),
                                .result(r_flat), .aux(x_flat), .fault(f_flat));

always #5 clk = ~clk;

task new_row;                  // keep c[30:9] clear most of the time
    integer bad;
    begin
        bad = (($random(seed) & 32'h7fffffff) % 16) == 0;
        ka = $random(seed); kb = $random(seed);
        kc = {($random(seed) & 32'h7fffffff) % 4 == 0, 1'b0, 22'd0,
              ($random(seed) & 32'h7fffffff) % 2 == 0, 8'h00};
        if (bad) kc[30:9] = ($random(seed) & 32'h7fffffff) & 32'h003f_ffff;
        else if (($random(seed) & 32'h7fffffff) % 3 == 0)
            kc[7:0] = $random(seed) & 32'hff;      // per-beat salt
    end
endtask

initial begin
    repeat (4) @(posedge clk);
    rst_n = 1;
    for (n = 0; n < 4000; n = n + 1) begin
        new_row;
        in_valid = 1; a = ka; b = kb; c = kc;
        @(posedge clk);
        while (!(rd_ref && rd_flat)) @(posedge clk);   // both must accept
        in_valid = 0;
        // stall out_ready randomly, then require both outputs to agree
        out_ready = (($random(seed) & 32'h7fffffff) % 2) == 1;
        @(posedge clk);
        out_ready = (($random(seed) & 32'h7fffffff) % 4) != 0;
        @(posedge clk);
        if (ov_ref !== ov_flat || r_ref !== r_flat || x_ref !== x_flat ||
            f_ref !== f_flat || ref_.state_r !== flat_.state_r) begin
            errors = errors + 1;
            if (errors < 8)
                $display("MISMATCH n=%0d a=%h b=%h c=%h ref=%h/%h/%b ov=%b flat=%h/%h/%b ov=%b",
                         n, ka, kb, kc, r_ref, x_ref, f_ref, ov_ref, r_flat, x_flat, f_flat, ov_flat);
        end
        beats = beats + 1;
        out_ready = 1;
        repeat (2) @(posedge clk);
    end
    $display("EQUIV beats=%0d errors=%0d", beats, errors);
    if (errors == 0) $display("BLOOM FLAT EQUIV PASS");
    else $display("BLOOM FLAT EQUIV FAIL");
    $finish;
end

initial begin
    #4000000;
    $display("EQUIV TIMEOUT");
    $finish;
end
endmodule
