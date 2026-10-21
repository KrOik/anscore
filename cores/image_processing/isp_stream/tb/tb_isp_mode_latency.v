`timescale 1ns/1ps
// Reuse the real64-mode CSR scenario; remove sink stalls to measure pipeline timing.
module tb_isp_mode_latency;
 tb_isp_all_modes scene();
 integer cycle=0,first_input=0,first_output=0,last_input=0,inputs=0,outputs=0;
 initial force scene.output_ready=1'b1;
 always @(posedge scene.clk)begin
  cycle=cycle+1;
  if(scene.rst)begin
   if(scene.dut.launch)begin inputs=0;outputs=0;first_input=0;first_output=0;end
   if(scene.dut.sv&&scene.dut.sr)begin
    if(inputs==0)first_input=cycle;
    inputs=inputs+1;last_input=cycle;
   end
   if(scene.mv&&scene.output_ready)begin
    if(outputs==0)first_output=cycle;
    outputs=outputs+1;
    if(scene.mf)begin
     if(inputs!=49||outputs!=9)$fatal(1,"latency frame accounting");
     $display("MODE_LATENCY version=%0d first=%0d tail=%0d input_span=%0d output_span=%0d",
      scene.dut.version,first_output-first_input,cycle-last_input,last_input-first_input,cycle-first_output);
    end
   end
  end
 end
endmodule
