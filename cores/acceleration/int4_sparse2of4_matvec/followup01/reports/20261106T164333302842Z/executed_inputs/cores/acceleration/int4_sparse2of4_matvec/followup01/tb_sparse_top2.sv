`timescale 1ns/1ps
module tb_sparse_top2;
 localparam TW=8,PAYLOAD=TW+11;
 reg clk=0;always #5 clk=~clk;
 reg rst=1,s_valid=0,m_ready=0,force_stall=0;
 reg [31:0] s_features=0;
 reg [TW-1:0] s_tag=0;
 wire s_ready,m_valid,m_last;
 wire signed [7:0] m_score;
 wire [1:0] m_index;
 wire [TW-1:0] m_tag;
 four_feature_sparse_top2 #(.TAG_W(TW)) dut(.*);
 integer cycles=0,held=0,resets=0,vector_frames=0,vector_scored=0,recovery_scored=0;
 integer seen=0,mode=0,want_score[0:1],want_index[0:1];
 reg [TW-1:0] expected_tag;
 reg was_held=0;
 reg [PAYLOAD-1:0] held_payload;
 wire [PAYLOAD-1:0] payload={m_score,m_index,m_tag,m_last};
 always @(negedge clk)m_ready=!force_stall && cycles%7>2;
 always @(posedge clk)begin
  cycles=cycles+1;if(cycles>100000)$fatal(1,"watchdog");
  if(rst)was_held=0;
  else begin
   if(was_held)begin
    if(!m_valid || payload!==held_payload)$fatal(1,"held top2 changed");held=held+1;
   end
   was_held=m_valid && !m_ready;held_payload=payload;
   if(m_valid && m_ready)begin
    if(mode==0 || seen>=2)$fatal(1,"unexpected top2");
    if($signed(m_score)!==want_score[seen] || m_index!==want_index[seen] ||
       m_tag!==expected_tag || m_last!==(seen==1))
     $fatal(1,"top2 mismatch row=%0d got=%0d/%0d expected=%0d/%0d",seen,$signed(m_score),m_index,want_score[seen],want_index[seen]);
    seen=seen+1;if(mode==1)vector_scored=vector_scored+1;else recovery_scored=recovery_scored+1;
   end
  end
 end
 task reset_core;
 begin
  @(negedge clk);rst=1;s_valid=0;mode=0;
  repeat(3)@(negedge clk);if(s_ready || m_valid)$fatal(1,"reset gate");
  rst=0;resets=resets+1;@(negedge clk);
 end endtask
 task push(input [31:0] value,input integer tag_value);
 integer bound;
 begin
  @(negedge clk);s_valid=1;s_features=value;s_tag=tag_value;expected_tag=tag_value;seen=0;bound=0;
  do begin @(posedge clk);bound=bound+1;if(bound>200)$fatal(1,"input wait");end while(!s_ready);
  @(negedge clk);s_valid=0;
 end endtask
 task retire;
 integer bound;
 begin
  bound=0;
  while(!s_ready)begin @(negedge clk);bound=bound+1;if(bound>300)$fatal(1,"retire wait");end
  if(seen!=2)$fatal(1,"lost top2");mode=0;repeat(3)@(negedge clk);
 end endtask
 task recovery;
 begin
  force_stall=0;want_score[0]=0;want_score[1]=0;want_index[0]=0;want_index[1]=1;
  mode=2;push(32'd0,231);retire;
 end endtask
 integer fd,rc,total,i,j,tag_value,bound;
 reg [31:0] packed_input;
 reg [2047:0] vector_path,trailing_token;
 initial begin
  reset_core;repeat(2)@(negedge clk);reset_core;recovery;
  if(!$value$plusargs("VECTORS=%s",vector_path))$fatal(1,"missing vectors");
  fd=$fopen(vector_path,"r");if(!fd)$fatal(1,"open vectors");
  rc=$fscanf(fd,"%d",total);if(rc!=1 || total!=64)$fatal(1,"count");
  for(i=0;i<total;i=i+1)begin
   rc=$fscanf(fd,"%h %d",packed_input,tag_value);if(rc!=2)$fatal(1,"header");
   for(j=0;j<2;j=j+1)begin rc=$fscanf(fd,"%d %d",want_score[j],want_index[j]);if(rc!=2)$fatal(1,"golden");end
   mode=1;push(packed_input,tag_value);retire;vector_frames=vector_frames+1;
  end
  rc=$fscanf(fd,"%s",trailing_token);if(rc>0 || !$feof(fd))$fatal(1,"trailing vectors");$fclose(fd);
  mode=2;push(32'h12345678,80);repeat(6)@(negedge clk);
  if(s_ready || m_valid)$fatal(1,"active reset probe");reset_core;recovery;
  force_stall=1;mode=2;push(32'hff008001,81);bound=0;
  while(!m_valid)begin @(negedge clk);bound=bound+1;if(bound>300)$fatal(1,"held wait");end
  repeat(6)@(negedge clk);reset_core;recovery;
  $display("PASS SPARSE_TOP2 vector_frames=%0d vector_scored=%0d recovery_scored=%0d resets=%0d held=%0d cycles=%0d",vector_frames,vector_scored,recovery_scored,resets,held,cycles);
  $finish;
 end
endmodule
