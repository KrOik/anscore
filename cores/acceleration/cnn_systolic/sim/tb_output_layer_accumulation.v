`timescale 1ns/1ps
// Independent stream contract: sum all pages and input-channel slots for each
// pixel/output-channel slot. Column skew follows the documented PE interface.
module tb_output_layer_accumulation #(
 parameter CPO=1, CPI=3, COLS=2, PAGES=2, SCALE=1
);
reg clk=0; always #5 clk=~clk;
reg rst_n=0,clk_en=1,new_line_in=0;
reg [PAGES*COLS*16-1:0] page_y_out='0;
wire [COLS*16-1:0] final_out;
wire output_valid,new_line_out_1;
output_layer #(.PE_PAGE_NUM(PAGES),.PE_COL_NUM(COLS),.PE_ROW_NUM(1),
 .PE_OUT_WIDTH(16),.BIAS_WIDTH(16),.ACC_WIDTH(24),.SHIFT_KEY(0),
 .OUT_WIDTH(16),.CYCLE_PERIOD_OUT(CPO),.CYCLE_PERIOD_IN(CPI),
 .IMG_COL(8),.WITH_RELU(0),.BIAS_FILE("accumulation_bias.mem")) dut(.*);
function integer stimulus;
 input integer pixel,ci,co,col,page;
 begin stimulus=(((pixel*11+ci*5+co*7+col*3+page*13)%31)-15)*SCALE; end
endfunction
integer t,p,c,s,pix,ci,co,k=0,expect_value,j;
reg [COLS*16-1:0] held;
initial begin
 repeat(3) @(negedge clk);
 rst_n=1;
 for(t=0;t<8*CPI*CPO+40+COLS;t=t+1) begin
  new_line_in=(t==0);
  for(p=0;p<PAGES;p=p+1) for(c=0;c<COLS;c=c+1) begin
   s=t-5-c; // PE_ROW_NUM+4 enabled beats, plus systolic column skew.
   if(s>=0 && s<8*CPI*CPO)
    page_y_out[(p*COLS+c)*16+:16]=stimulus(s/(CPI*CPO),(s/CPO)%CPI,s%CPO,c,p);
   else page_y_out[(p*COLS+c)*16+:16]=0;
  end
  if(t%7==3) begin
   clk_en=0; held=final_out;
   @(posedge clk); #1;
   if(final_out!==held) $fatal(1,"output changed while clk_en=0");
   @(negedge clk); clk_en=1;
  end
  @(posedge clk); #1;
  if(output_valid) begin
   if(k>=8*CPO) $fatal(1,"extra valid output");
   pix=k/CPO; co=k%CPO;
   for(c=0;c<COLS;c=c+1) begin
    expect_value=0;
    for(j=0;j<CPI;j=j+1) for(p=0;p<PAGES;p=p+1)
     expect_value=expect_value+stimulus(pix,j,co,c,p);
    if(expect_value>32767) expect_value=32767;
    if(expect_value< -32768) expect_value=-32768;
    if($signed(final_out[c*16+:16])!==expect_value)
     $fatal(1,"sum mismatch CPO=%0d CPI=%0d pixel=%0d co=%0d col=%0d got=%0d expected=%0d",CPO,CPI,pix,co,c,$signed(final_out[c*16+:16]),expect_value);
   end
   k=k+1;
  end
  @(negedge clk);
 end
 if(k!=8*CPO) $fatal(1,"missing output count %0d",k);
 $display("PASS output accumulation CPO=%0d CPI=%0d COLS=%0d PAGES=%0d outputs=%0d",CPO,CPI,COLS,PAGES,k);
 $finish;
end
initial begin #1000000; $fatal(1,"timeout"); end
endmodule
