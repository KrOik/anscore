`timescale 1ns/1ps
module tb_spatial_sum_stream;
parameter LANES=2, COLS=4, CPO=2, ROWS=3, WIDTH=8, ACC=16, GAPS=0;
localparam DEPTH=COLS*CPO;
reg clk=0;
always #5 clk=~clk;
reg rst_n=0, clk_en=0, marker=0, valid=0;
reg [LANES*WIDTH-1:0] din=0;
wire [LANES*ACC-1:0] dout;
wire out_valid,out_marker;
lprnet_spatial_sum #(.PE_COL_NUM(LANES),.CYCLE_PERIOD_OUT(CPO),
 .IMG_COL(COLS),.IMG_ROW(ROWS),.DATA_WIDTH(WIDTH),.ACC_WIDTH(ACC)) dut
 (.clk(clk),.rst_n(rst_n),.clk_en(clk_en),.new_line_input_1(marker),
 .data_input_valid(valid),.data_input(din),.y_out(dout),
 .new_line_out_1(out_marker),.output_valid(out_valid));
integer sums[0:DEPTH*LANES-1];
reg [LANES*ACC-1:0] expected[0:DEPTH*4-1];
integer head=0,tail=0,markers=0,frame,row,col,lane,value,idx;
integer epoch;
reg [3:0] expected_valid=0;
reg [2:0] expected_marker=0;
reg [LANES*WIDTH-1:0] next_data;
reg [LANES*ACC-1:0] previous_data;
reg previous_valid,previous_marker;

task step;
 input en,mark,v;
 input [LANES*WIDTH-1:0] d;
 begin
  @(negedge clk);
  previous_data=dout; previous_valid=out_valid; previous_marker=out_marker;
  clk_en=en;marker=mark;valid=v;din=d;
  if(en) begin
   expected_valid={expected_valid[2:0],v && row==ROWS-1};
   expected_marker={expected_marker[1:0],v && row==ROWS-1 && col==0};
  end
  @(posedge clk);#1;
  if (!en) begin
   if (dout !== previous_data || out_valid !== previous_valid || out_marker !== previous_marker)
    $fatal(1,"STALL changed output");
  end else begin
   if(out_valid !== expected_valid[3] || out_marker !== expected_marker[2])
    $fatal(1,"Output/marker latency mismatch");
   if(out_marker) markers=markers+1;
   if(out_valid) begin
    if(head>=tail) $fatal(1,"Unexpected output index %0d",head);
    if(dout !== expected[head])
     $fatal(1,"DATA depth=%0d rows=%0d index=%0d got=%h expected=%h",DEPTH,ROWS,head,dout,expected[head]);
    head=head+1;
   end
  end
 end
endtask

initial begin
 repeat(3) @(posedge clk);
 @(negedge clk);rst_n=1;
 for(epoch=0;epoch<3;epoch=epoch+1) begin
 head=0;tail=0;markers=0;expected_valid=0;expected_marker=0;
 for(frame=0;frame<4;frame=frame+1) begin
  for(idx=0;idx<DEPTH*LANES;idx=idx+1) sums[idx]=0;
  for(row=0;row<ROWS;row=row+1) begin
   step(1,1,0,0); // Contract: row marker precedes the first valid beat.
   for(col=0;col<DEPTH;col=col+1) begin
    next_data=0;
    for(lane=0;lane<LANES;lane=lane+1) begin
     value=((epoch*101+frame*73+row*37+col*19+lane*53) % (1<<WIDTH));
     next_data[lane*WIDTH+:WIDTH]=value;
     if(value >= (1<<(WIDTH-1))) value=value-(1<<WIDTH);
     sums[col*LANES+lane]=sums[col*LANES+lane]+value;
     if(row==ROWS-1) expected[tail][lane*ACC+:ACC]=sums[col*LANES+lane];
    end
    if(row==ROWS-1) tail=tail+1;
    if(GAPS && ((col+row+frame)%3==0)) step(1,0,0,0);
    if(GAPS && ((col+frame)%2==0)) step(0,0,1,~next_data);
    step(1,0,1,next_data);
   end
  end
 end
 repeat(6) step(1,0,0,0);
 if(head!=4*DEPTH || markers!=4) $fatal(1,"COUNT outputs=%0d markers=%0d",head,markers);
 // Interrupt a new frame while its first input is still in the pipeline.
 // SRAM deliberately retains old frame data across asynchronous reset.
 @(negedge clk);clk_en=1;marker=1;valid=0;
 @(negedge clk);marker=0;valid=1;din='1;
 @(negedge clk);clk_en=0;valid=0;rst_n=0;#1;
 if(dout !== 0 || out_valid !== 0 || out_marker !== 0) $fatal(1,"Async reset failed");
 repeat(2) @(negedge clk);
 rst_n=1;
 end
 $display("PASS spatial_sum depth=%0d rows=%0d lanes=%0d width=%0d acc=%0d gaps=%0d outputs=%0d resets=3",DEPTH,ROWS,LANES,WIDTH,ACC,GAPS,head*3);
 $finish;
end
initial begin #1000000; $fatal(1,"TIMEOUT"); end
endmodule
