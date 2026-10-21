`timescale 1ns/1ps
module tb_byte_reverse32;
reg clk=0; always #5 clk=~clk;
reg rst_n=0, clk_en=0, in_valid=0, out_ready=0;
reg [31:0] a=0,b=0,c=0;
wire in_ready,out_valid,fault;
wire [31:0] result,aux;
prod_byte_reverse32 dut(.*);
localparam N=342;
localparam LATENCY=1;
reg [160:0] vec[0:N-1];
reg [31:0] rng=32'h18252056;
reg held=0; reg [64:0] held_word;
integer sent,received,cycles,phase;
integer stalls=0, pauses=0, consecutive=0;
reg prior_accept=0;
task reset_dut;
begin
    @(negedge clk); rst_n=0; in_valid=0; clk_en=0; out_ready=0;
    repeat(3) @(posedge clk);
    @(negedge clk); rst_n=1;
    sent=0; received=0; cycles=0; held=0; prior_accept=0;
end
endtask
task run_vectors;
input integer randomized;
begin
    while(received<N) begin
        @(negedge clk);
        rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
        clk_en=!randomized || (rng[1:0]!=0);
        out_ready=!randomized || (rng[4:2]!=0);
        in_valid=(sent<N) && (!randomized || in_valid || rng[6]);
        if(sent<N) {a,b,c}=vec[sent][160:65];
        @(posedge clk);
        if(held && ({result,aux,fault}!==held_word || out_valid!==1))
            $fatal(1,"byte_reverse32 changed pending output at cycle %0d",cycles);
        if(clk_en && out_valid && out_ready) begin
            if({result,aux,fault} !== vec[received][64:0])
                $fatal(1,"byte_reverse32 row %0d got %h expected %h",received,{result,aux,fault},vec[received][64:0]);
            received=received+1;
        end
        held=out_valid && (!clk_en || !out_ready);
        held_word={result,aux,fault};
        if(clk_en && in_valid && in_ready) begin
            sent=sent+1;
            if(prior_accept) consecutive=consecutive+1;
            prior_accept=1;
        end else prior_accept=0;
        if(out_valid && !out_ready && clk_en) stalls=stalls+1;
        if(!clk_en) pauses=pauses+1;
        cycles=cycles+1;
        if(cycles>N*25) $fatal(1,"byte_reverse32 timeout");
    end
    @(negedge clk); in_valid=0; clk_en=1; out_ready=1;
    repeat(2) @(posedge clk);
    #1; if(out_valid!==0) $fatal(1,"byte_reverse32 unexpected duplicate output");
end
endtask
initial begin
    $readmemh("vectors/byte_reverse32.mem",vec);
    reset_dut; run_vectors(0);
    reset_dut; run_vectors(1);
    // Drop a pending response with asynchronous reset while CE is disabled.
    @(negedge clk); clk_en=1; in_valid=1; out_ready=0; {a,b,c}=vec[0][160:65];
    repeat(LATENCY) @(posedge clk); #1;
    if(out_valid!==1) $fatal(1,"byte_reverse32 pending setup failed");
    @(negedge clk); clk_en=0; rst_n=0;
    #1; if(out_valid!==0 || {result,aux,fault}!==65'd0) $fatal(1,"byte_reverse32 reset failed");
    reset_dut; run_vectors(1);
    if(stalls==0 || pauses==0 || consecutive<N-1) $fatal(1,"byte_reverse32 vacuous protocol coverage");
    $display("PASS byte_reverse32 vectors=%0d phases=3 stalls=%0d pauses=%0d",N,stalls,pauses);
    $finish;
end
endmodule
