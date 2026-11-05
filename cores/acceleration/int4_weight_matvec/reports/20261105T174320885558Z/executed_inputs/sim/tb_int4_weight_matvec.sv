`timescale 1ns/1ps
module tb_int4_weight_matvec;
 parameter MAX_ROWS=8,MAX_COLS=64,TAG_W=16;
 reg clk=0;always #5 clk=~clk;
 reg rst=1,c_valid=0,c_rsp_ready=0,cmd_valid=0,s_valid=0,m_ready=0;
 reg [1:0] c_op=0;reg [15:0] c_row=0,c_word=0,c_scale=0;
 reg [31:0] c_weights=0;reg signed [31:0] c_bias=0;
 reg [4:0] c_shift=0;reg signed [7:0] c_zero=0;
 wire c_ready,c_rsp_valid;wire [1:0] c_error;
 reg [15:0] cmd_rows=0,cmd_cols=0;reg [7:0] cmd_x_zero=0,s_data=0;
 reg [TAG_W-1:0] cmd_tag=0;reg s_last=0;
 wire cmd_ready,s_ready,m_valid,m_last,m_clip,m_inexact,busy;
 wire signed [7:0] m_data;wire [15:0] m_row;wire [TAG_W-1:0] m_tag;wire [1:0] m_error;
 int4_weight_matvec #(.MAX_ROWS(MAX_ROWS),.MAX_COLS(MAX_COLS),.TAG_W(TAG_W)) dut(.*);
 integer fd,rv,op,a,b,c,d,e,f,g,h,j,k,ns,ne,received=0,expected_count=0;
 integer ed[0:MAX_ROWS],er[0:MAX_ROWS],el[0:MAX_ROWS],ec[0:MAX_ROWS];
 integer ei[0:MAX_ROWS],ee[0:MAX_ROWS],et[0:MAX_ROWS];
 integer xd[0:MAX_COLS],xl[0:MAX_COLS];
 integer cycles=0,results=0,stalls=0,frames=0,configs=0,resets=0;
 reg collecting=0,holding=0;
 reg [TAG_W+28:0] held;
 wire [TAG_W+28:0] payload={m_data,m_row,m_tag,m_last,m_clip,m_inexact,m_error};
 string vectors;
 always @(negedge clk) begin
  cycles=cycles+1;
  if(cycles>200000) $fatal(1,"bounded watchdog");
 end
 always @(posedge clk) if(!rst) begin
  if(holding && (!m_valid || payload!==held)) $fatal(1,"output changed under stall");
  holding=m_valid&&!m_ready;held=payload;
  if(m_valid&&!m_ready)stalls=stalls+1;
  if(m_valid&&m_ready)begin
   if(!collecting || received>=expected_count)$fatal(1,"unexpected output");
   if($signed(m_data)!==ed[received] || m_row!==er[received][15:0] ||
      m_last!==el[received][0] || m_clip!==ec[received][0] ||
      m_inexact!==ei[received][0] || m_error!==ee[received][1:0] ||
      m_tag!==et[received][TAG_W-1:0])
    $fatal(1,"result %0d got d%0d row%0d last%0d clip%0d inex%0d err%0d tag%0d expected d%0d row%0d last%0d clip%0d inex%0d err%0d tag%0d",
     received,$signed(m_data),m_row,m_last,m_clip,m_inexact,m_error,m_tag,
     ed[received],er[received],el[received],ec[received],ei[received],ee[received],et[received]);
   received=received+1;results=results+1;
  end
  if(busy && (cmd_ready||c_ready))$fatal(1,"configuration changed while busy");
 end
 task reset_core;
  begin
   @(negedge clk);rst=1;c_valid=0;cmd_valid=0;s_valid=0;m_ready=0;c_rsp_ready=0;
   collecting=0;holding=0;
   repeat(2)@(posedge clk);
   @(negedge clk);rst=0;resets=resets+1;
   @(posedge clk);if(m_valid||s_ready||c_rsp_valid||busy)$fatal(1,"reset did not cancel");
  end
 endtask
 task command(input integer nr,nc,z,t);
  begin
   @(negedge clk);cmd_rows=nr;cmd_cols=nc;cmd_x_zero=z;cmd_tag=t;cmd_valid=1;
   do @(posedge clk);while(!cmd_ready);
   @(negedge clk);cmd_valid=0;
  end
 endtask
 task sample(input integer value,last);
  begin
   @(negedge clk);s_data=value;s_last=last;s_valid=1;
   do @(posedge clk);while(!s_ready);
   @(negedge clk);s_valid=0;
  end
 endtask
 initial begin
  if(!$value$plusargs("vectors=%s",vectors))$fatal(1,"vectors required");
  fd=$fopen(vectors,"r");if(!fd)$fatal(1,"cannot open vectors");
  reset_core();
  while(!$feof(fd))begin
   rv=$fscanf(fd,"%d",op);
   if(rv==1)case(op)
    0:begin
     rv=$fscanf(fd,"%d %d %d %d %d %d %d %d %d",a,b,c,d,e,f,g,h,j);
     if(rv!=9)$fatal(1,"bad config record");
     @(negedge clk);c_op=a;c_row=b;c_word=c;c_weights=d;c_bias=e;
     c_scale=f;c_shift=g;c_zero=h;c_valid=1;
     do @(posedge clk);while(!c_ready);
     @(negedge clk);c_valid=0;
     do @(posedge clk);while(!c_rsp_valid);
     repeat(3)begin
      if(!c_rsp_valid||c_error!==j[1:0])$fatal(1,"config response");
      @(posedge clk);
     end
     @(negedge clk);c_rsp_ready=1;
     @(posedge clk);@(negedge clk);c_rsp_ready=0;configs=configs+1;
    end
    1:begin
     rv=$fscanf(fd,"%d %d %d %d %d %d",a,b,c,d,ns,ne);if(rv!=6)$fatal(1,"bad frame record");
     for(k=0;k<ns;k=k+1)begin rv=$fscanf(fd,"%d %d",xd[k],xl[k]);if(rv!=2)$fatal(1,"bad sample");end
     for(k=0;k<ne;k=k+1)begin
      rv=$fscanf(fd,"%d %d %d %d %d %d %d",ed[k],er[k],el[k],ec[k],ei[k],ee[k],et[k]);
      if(rv!=7)$fatal(1,"bad oracle");
     end
     collecting=1;received=0;expected_count=ne;m_ready=0;
     command(a,b,c,d);
     for(k=0;k<ns;k=k+1)begin
      repeat(k%3)@(negedge clk);
      sample(xd[k],xl[k]);
     end
     // Deliberately let the pipeline fill; one-row and error outputs are held too.
     repeat(80)@(negedge clk);
     while(received<ne)begin @(negedge clk);m_ready=(cycles%5>=2);end
     @(negedge clk);m_ready=0;collecting=0;frames=frames+1;
     if(busy)$fatal(1,"last output did not release command");
    end
    2:reset_core();
    3:begin
     // Reset four distinct live stages. Setup was supplied by previous records.
     rv=$fscanf(fd,"%d",a);if(rv!=1)$fatal(1,"bad reset phase");
     command(MAX_ROWS,MAX_COLS,123,0);
     if(a==0)begin repeat(1)@(negedge clk);end
     else if(a==1)begin
      do @(posedge clk);while(!s_ready);
      if(MAX_COLS>1)sample(7,0);
     end else begin
      for(k=0;k<MAX_COLS;k=k+1)sample(k,k==MAX_COLS-1);
      if(a==2)repeat(3)@(negedge clk);
      else begin do @(posedge clk);while(!m_valid);repeat(4)@(negedge clk);end
     end
     reset_core();
    end
    4:begin
     // Simultaneous offer: config response first, retained invalid command next.
     @(negedge clk);c_op=3;c_valid=1;cmd_valid=1;cmd_rows=0;cmd_cols=0;cmd_tag=0;
     @(posedge clk);if(!c_ready||cmd_ready)$fatal(1,"arbitration");
     @(negedge clk);c_valid=0;c_rsp_ready=1;
     do @(posedge clk);while(!c_rsp_valid);
     if(c_error!=2)$fatal(1,"arbitration config status");
     @(negedge clk);c_rsp_ready=0;
     do @(posedge clk);while(!cmd_ready);
     @(negedge clk);cmd_valid=0;
     ed[0]=0;er[0]=0;el[0]=1;ec[0]=0;ei[0]=0;ee[0]=1;et[0]=0;
     received=0;expected_count=1;collecting=1;m_ready=1;
     do @(negedge clk);while(received<1);
     m_ready=0;collecting=0;
    end
    default:$fatal(1,"unknown vector op");
   endcase
  end
  repeat(8)@(posedge clk);
  if(m_valid||busy)$fatal(1,"trailing state");
  $display("PASS int4_weight_matvec R=%0d C=%0d T=%0d frames=%0d rows=%0d configs=%0d stalls=%0d resets=%0d",MAX_ROWS,MAX_COLS,TAG_W,frames,results,configs,stalls,resets);
  $finish;
 end
endmodule
