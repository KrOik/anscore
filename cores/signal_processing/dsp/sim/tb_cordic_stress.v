`timescale 1ns/1ps
module tb_cordic_stress;
  reg clk=0, rst_n=0, ce=1, valid=0, mode=0;
  reg signed [15:0] x=0,y=0,z=0;
  wire signed [15:0] xo,yo;
  wire signed [17:0] zo;
  wire ov;
  reg [98:0] vectors[0:4095];
  integer accepted_at[0:4095];
  integer sent=0, got=0, beat=0, i;
  reg [50:0] held;
  reg checking=1;
  always #5 clk=~clk;
  cordic dut(.clk(clk),.clk_en(ce),.rst_n(rst_n),.mode(mode),.in_valid(valid),
    .x_in(x),.y_in(y),.z_in(z),.x_out(xo),.y_out(yo),.z_out(zo),.out_valid(ov));
  always @(posedge clk) begin
    if(rst_n && checking) begin
      if(ce) begin
        if(valid) begin accepted_at[sent]=beat; sent=sent+1; end
        #1;
        if(ov===1) begin
          if(got>=sent || {zo,yo,xo}!==vectors[got][49:0])
            $fatal(1,"value %0d got=%013x expected=%013x",got,{zo,yo,xo},vectors[got][49:0]);
          if(beat-accepted_at[got]!=17) $fatal(1,"latency %0d",beat-accepted_at[got]);
          got=got+1;
        end else if(ov!==0) $fatal(1,"unknown valid");
        beat=beat+1;
      end else begin
        held={ov,zo,yo,xo}; #1;
        if({ov,zo,yo,xo}!==held) $fatal(1,"clk_en freeze failed");
      end
    end
  end
  initial begin
    $readmemh("cordic_vectors.mem",vectors);
    repeat(3) @(negedge clk); rst_n=1;
    for(i=0;i<4096;i=i+1) begin
      @(negedge clk);
      if(i%7==0) begin ce=0; repeat(2) @(negedge clk); ce=1; end
      if(i%11==0) begin valid=0; @(negedge clk); end
      {mode,x,y,z}=vectors[i][98:50]; valid=1;
    end
    @(negedge clk); valid=0;
    repeat(20) @(negedge clk);
    if(got!=4096 || sent!=4096) $fatal(1,"count got=%0d sent=%0d",got,sent);
    checking=0;
    // Reset a partially filled pipeline, then confirm no stale valid survives.
    valid=1; repeat(4) @(negedge clk); valid=0; rst_n=0;
    #1; if(ov!==0 || {zo,yo,xo}!==0) $fatal(1,"async reset failed");
    @(negedge clk); rst_n=1;
    repeat(20) begin @(negedge clk); if(ov!==0) $fatal(1,"stale valid after reset"); end
    $display("CORDIC_STRESS PASS vectors=4096 modes=2 latency=17 ce_pause bubbles async_reset");
    $finish;
  end
  initial begin #2000000; $fatal(1,"timeout"); end
endmodule
