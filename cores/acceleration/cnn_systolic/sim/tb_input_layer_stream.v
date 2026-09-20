`timescale 1ns/1ps
// Independent image-coordinate oracle for the existing 40-window contract.
// GAP inserts input-valid bubbles; STALL pauses the whole enabled pipeline.
module tb_input_layer_stream #(parameter GAP=0, STALL=0, ROW_IDLE=32, RANDOM_GAPS=0, SEED=32'h179cab31, CHECK_LAYER=0, IMG_W=8, IMG_H=6, RESET_MID=0);
reg clk=0,clk_en=1,rst_n=0,new_line_input_1=0,data_input_valid=0;
reg [1:0][7:0] data_input=0;
wire [8:0][1:0][7:0] data_out;
wire [143:0] flat=data_out;
wire line_buf_full,data_out_valid,new_line_out_1;
integer cycle=0,count=0,errors=0,accepted=0,y,x,k,ch,iy,ix,value;
reg [31:0] rng=SEED;
reg check_active=!RESET_MID;
integer layer_count=0,layer_errors=0,lk,lc,ly,lx,acc,result_value;
wire [1:0][7:0] layer_out;
wire layer_valid,layer_line;
generate if(CHECK_LAYER) begin : g_layer
 lprnet_layer_direct #(.PE_PAGE_NUM(2),.PE_ROW_NUM(9),.PE_COL_NUM(2),
  .KERNEL_COL(3),.KERNEL_ROW(3),.MAX_POOL(0),.WITH_RELU(1),
  .DATA_WIDTH(8),.WEIGHT_WIDTH(8),.CYCLE_PERIOD_IN(1),.CYCLE_PERIOD_OUT(2),
  .IMG_COL(IMG_W),.IMG_ROW(IMG_H),.STEP_ROW(1),.STEP_COL(1),.USE_DSP_PE("no"),
  .SHIFT_KEY(4),.BIAS_WIDTH(16),.OUT_WIDTH(8),
  .WEIGHT_FILE0("weight_layer9_page0.mem"),.WEIGHT_FILE1("weight_layer9_page1.mem"),
  .BIAS_FILE("bias_layer9.mem")) layer_dut (
  .clk(clk),.clk_en(clk_en),.rst_n(rst_n),.new_line_input_1(new_line_input_1),
  .data_input_valid(data_input_valid),.data_input(data_input),
  .y_out(layer_out),.output_valid(layer_valid),.new_line_out_1(layer_line));
 always @(posedge clk) if(check_active && rst_n && clk_en && layer_valid) begin
  acc=8;
  for(lk=0;lk<9;lk=lk+1) begin
   ly=(layer_count/2)/IMG_W+lk/3-1; lx=(layer_count/2)%IMG_W+lk%3-1;
   // Input ports truncate each channel to eight bits before convolution.
   if(ly>=0 && ly<IMG_H && lx>=0 && lx<IMG_W)
    acc=acc+((lx+1+IMG_W*ly)&255)+((3*(lx+1)+7*ly+2)&255);
  end
  result_value=(acc>>4)+((acc>>3)&1);
  if(result_value>255) result_value=255;
  for(lc=0;lc<2;lc=lc+1) if(layer_out[lc]!==result_value[7:0]) begin
   if(layer_errors<8) $display("LAYER MISMATCH beat=%0d ch=%0d got=%h expected=%h",layer_count,lc,layer_out[lc],result_value[7:0]);
   layer_errors=layer_errors+1;
  end
  layer_count=layer_count+1;
 end
end endgenerate
always #5 clk=~clk;
always @(negedge clk) begin
 cycle=cycle+1;
 clk_en=(!STALL || cycle%5!=0);
end
input_layer #(.DATA_WIDTH(8),.PE_PAGE_NUM(2),.PE_ROW_NUM(9),
 .CYCLE_PERIOD_IN(1),.CYCLE_PERIOD_OUT(2),.STEP_ROW(1),.STEP_COL(1),
 .KERNEL_ROW(3),.KERNEL_COL(3),.IMG_COL(IMG_W),.IMG_ROW(IMG_H)) dut(.*);
task beat;
 input nl,dv;
 input [15:0] data;
 begin
  @(negedge clk); #1;
  new_line_input_1=nl; data_input_valid=dv; data_input=data;
  @(posedge clk);
  while(!clk_en) @(posedge clk);
 end
endtask
always @(posedge clk) begin
 if(check_active && rst_n && clk_en) begin
  if(data_input_valid) begin
   if(line_buf_full) $fatal(1,"test stimulus violated full backpressure");
   accepted=accepted+1;
  end
  // Observe the transfer at the consuming edge, before DUT nonblocking updates.
  if(data_out_valid) begin
   for(k=0;k<9;k=k+1) for(ch=0;ch<2;ch=ch+1) begin
    iy=count/IMG_W+k/3-1; ix=count%IMG_W+k%3-1;
    value=0;
    if(iy>=0 && iy<IMG_H && ix>=0 && ix<IMG_W)
     value=ch ? 3*(ix+1)+7*iy+2 : ix+1+IMG_W*iy;
    if(flat[(k*2+ch)*8+:8]!==value[7:0]) begin
     if(errors<8) $display("MISMATCH window=%0d lane=%0d ch=%0d got=%h expected=%h",count,k,ch,flat[(k*2+ch)*8+:8],value[7:0]);
     errors=errors+1;
    end
   end
   count=count+1;
  end
 end
end
initial begin
 repeat(5) @(negedge clk);
 #1; rst_n=1;
 if(RESET_MID) begin
  beat(1,0,0);
  repeat(3) beat(0,1,16'h7251);
  beat(0,0,0);
  @(negedge clk); #1; rst_n=0;
  repeat(5) @(negedge clk);
  #1; rst_n=1; check_active=1;
 end
 for(y=0;y<IMG_H;y=y+1) begin
  beat(1,0,0);
  for(x=0;x<IMG_W;x=x+1) begin
   rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
   repeat(RANDOM_GAPS ? rng[2:0] : GAP) beat(0,0,0);
   beat(0,1,{8'(3*(x+1)+7*y+2),8'(x+1+IMG_W*y)});
  end
  repeat(ROW_IDLE) beat(0,0,0);
 end
 repeat(2*IMG_W+100) beat(0,0,0);
 if(accepted!=IMG_W*IMG_H) $fatal(1,"input acceptance mismatch %0d",accepted);
 if(CHECK_LAYER && (layer_count!=2*(IMG_H-1)*IMG_W || layer_errors!=0)) $fatal(1,"layer beats=%0d errors=%0d",layer_count,layer_errors);
 if(count!=(IMG_H-1)*IMG_W || errors!=0) $fatal(1,"input stream GAP=%0d STALL=%0d accepted=%0d windows=%0d errors=%0d",GAP,STALL,accepted,count,errors);
 $display("PASS input stream GAP=%0d STALL=%0d windows=%0d bytes=%0d",GAP,STALL,count,count*18);
 $finish;
end
initial begin #1000000; $fatal(1,"timeout"); end
endmodule
