// Synthesizable finite dual-source/dual-sink test. Reusable after completion.
module buffer_dma_selftest #(parameter FRAME_COUNT=32, SLOT_WORDS=256, TIMEOUT=2000000)(
 input wire clk,rst_n,start,input wire [31:0] seed,input wire stalls_enable,
 output wire start_ready,output wire done,output reg error,
 output reg [31:0] checked_words,check_errors,run_cycles,
 output wire [7:0] probe,
 input wire csr_valid,csr_write,input wire [7:0] csr_addr,
 input wire [31:0] csr_data,input wire [3:0] csr_strobe,
 output wire csr_ready,csr_resp_valid,csr_resp_error,
 output wire [31:0] csr_resp_data,input wire csr_resp_ready
);
 localparam IDLE=0,CLEAR=1,RUN=2,FINISHED=3;
 reg [1:0] phase;
 reg [31:0] run_seed,lfsr;
 reg stall_mode;
 wire local_reset=rst_n&&phase!=CLEAR;
 assign start_ready=rst_n&&(phase==IDLE||phase==FINISHED);
 assign done=phase==FINISHED;
 wire [1:0] wv,wr,destination,sv,sr,sl,cv,ce,mv,mr,ml;
 wire [31:0] frame_ids,lengths;
 wire [63:0] sd,md;
 wire [7:0] mk;
 wire [131:0] descriptors;
 wire [31:0] published,released,aborted,invalid;
 wire [1:0] writer_finished;
 assign probe={done,error,mv[1],mr[1],mv[0],mr[0],sv[0],sr[0]};
 frame_buffer_reference #(.SLOT_WORDS(SLOT_WORDS)) buffer(
 .clk(clk),.rst_n(local_reset),.w_valid(wv),.w_destination(destination),
 .w_frame_id(frame_ids),.w_length(lengths),.w_ready(wr),
 .s_valid(sv),.s_data(sd),.s_keep(8'hff),.s_last(sl),.s_ready(sr),
 .complete_valid(cv),.complete_error(ce),.complete_ready(2'b11),
 .m_valid(mv),.m_ready(mr),.m_data(md),.m_keep(mk),.m_last(ml),.m_descriptor(descriptors),
 .published(published),.released(released),.aborted(aborted),.invalid_requests(invalid),
 .csr_valid(csr_valid),.csr_write(csr_write),.csr_addr(csr_addr),.csr_data(csr_data),
 .csr_strobe(csr_strobe),.csr_ready(csr_ready),.csr_resp_valid(csr_resp_valid),
 .csr_resp_error(csr_resp_error),.csr_resp_data(csr_resp_data),.csr_resp_ready(csr_resp_ready));
 genvar c;
 generate for(c=0;c<2;c=c+1)begin: writers
  reg [1:0] state;
  reg [15:0] frame,offset;
  reg [31:0] frame_base,word_term;
  assign frame_ids[c*16+:16]=frame;
  assign lengths[c*16+:16]={12'd0,frame[3:0]}+16'd1;
  assign destination[c]=c^frame[0];
  assign wv[c]=phase==RUN&&state==0;
  // Valid may only rise when the deterministic gap gate allows it; once
  // asserted it remains high throughout this word's backpressure interval.
  reg pending;
  assign sv[c]=phase==RUN&&state==1&&pending;
  assign sd[c*32+:32]=run_seed^(c*32'h17351)^word_term;
  assign sl[c]=offset=={12'd0,frame[3:0]};
  assign writer_finished[c]=state==3;
  always @(posedge clk or negedge local_reset)begin
   if(!local_reset)begin state<=0;frame<=0;offset<=0;pending<=0;frame_base<=0;word_term<=0;end
   else if(phase==RUN)case(state)
    0:if(wr[c])begin state<=1;offset<=0;end
    1:begin
     if(!pending&&(!stall_mode||lfsr[c+4]))pending<=1;
     if(sv[c]&&sr[c])begin
      pending<=0;
      word_term<=word_term+32'h71a3;
      if(sl[c])state<=2;else offset<=offset+1'b1;
     end
    end
    2:if(cv[c])begin
     if(frame==FRAME_COUNT-1)state<=3;
     else begin frame<=frame+1'b1;state<=0;
      frame_base<=frame_base+32'h103397;word_term<=frame_base+32'h103397;
     end
    end
   endcase
  end
 end endgenerate
 assign mr[0]=phase==RUN&&(!stall_mode||lfsr[0]);
 assign mr[1]=phase==RUN&&(!stall_mode||lfsr[1]);
 reg [15:0] offsets[0:1],next_frame[0:3];
 reg [31:0] next_base[0:3],offset_term[0:1];
 reg [63:0] expected_q,actual_q;
 reg [1:0] check_valid,metadata_bad_q,metadata_bad;
 wire [1:0] bad={metadata_bad_q[1]||(expected_q[63:32]!=actual_q[63:32]),
                  metadata_bad_q[0]||(expected_q[31:0]!=actual_q[31:0])};
 integer k,source;reg [15:0] f,n;reg [65:0] d;
 always @*begin
  metadata_bad=0;d=0;f=0;n=0;source=0;
  for(k=0;k<2;k=k+1)begin
   d=descriptors[k*66+:66];f=d[65:50];source=d[49];n={12'd0,f[3:0]}+16'd1;
   metadata_bad[k]=d[48]!=k||k!=(source^f[0])||f>=FRAME_COUNT||
    f!=next_frame[k*2+source]||d[15:0]!=n||d[47:16]>=4*SLOT_WORDS*4||
    mk[k*4+:4]!=15||ml[k]!=(offsets[k]==n-1);
  end
 end
 integer j;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin phase<=IDLE;run_seed<=0;stall_mode<=0;lfsr<=1;
   error<=0;checked_words<=0;check_errors<=0;run_cycles<=0;
   check_valid<=0;metadata_bad_q<=0;expected_q<=0;actual_q<=0;
   for(j=0;j<2;j=j+1)begin offsets[j]<=0;offset_term[j]<=0;end
   for(j=0;j<4;j=j+1)begin next_frame[j]<=(j/2)^(j%2);next_base[j]<=((j/2)^(j%2))*32'h103397;end
  end else begin
   if(start&&start_ready)begin
    phase<=CLEAR;run_seed<=seed;stall_mode<=stalls_enable;lfsr<=seed==0?1:seed;
    error<=0;checked_words<=0;check_errors<=0;run_cycles<=0;
    check_valid<=0;metadata_bad_q<=0;expected_q<=0;actual_q<=0;
    for(j=0;j<2;j=j+1)begin offsets[j]<=0;offset_term[j]<=0;end
    for(j=0;j<4;j=j+1)begin next_frame[j]<=(j/2)^(j%2);next_base[j]<=((j/2)^(j%2))*32'h103397;end
   end else if(phase==CLEAR)phase<=RUN;
   else if(phase==RUN)begin
    run_cycles<=run_cycles+1'b1;
    lfsr<={lfsr[30:0],lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
    checked_words<=checked_words+{31'd0,mv[0]&&mr[0]}+{31'd0,mv[1]&&mr[1]};
    check_valid<=mv&mr;
    metadata_bad_q<=metadata_bad;actual_q<=md;
    check_errors<=check_errors+{31'd0,check_valid[0]&&bad[0]}+{31'd0,check_valid[1]&&bad[1]};
    if((|(cv&ce))||(|(bad&check_valid))||aborted!=0||invalid!=0)error<=1;
    for(j=0;j<2;j=j+1)if(mv[j]&&mr[j])begin
     expected_q[j*32+:32]<=run_seed^(descriptors[j*66+49]?32'h17351:32'd0)^
      (next_base[j*2+descriptors[j*66+49]]+offset_term[j]);
     if(ml[j])begin
      offsets[j]<=0;offset_term[j]<=0;
      next_frame[j*2+descriptors[j*66+49]]<=next_frame[j*2+descriptors[j*66+49]]+2;
      next_base[j*2+descriptors[j*66+49]]<=next_base[j*2+descriptors[j*66+49]]+32'h20672e;
     end else begin offsets[j]<=offsets[j]+1'b1;offset_term[j]<=offset_term[j]+32'h71a3;end
    end
    if((&writer_finished)&&released==2*FRAME_COUNT&&check_valid==0)begin
     phase<=FINISHED;
     if(published!=2*FRAME_COUNT)error<=1;
    end else if(run_cycles==TIMEOUT-1)begin error<=1;phase<=FINISHED;end
   end
  end
 end
 initial if(FRAME_COUNT<2||FRAME_COUNT>65534||FRAME_COUNT%2||SLOT_WORDS<16||TIMEOUT<1)
  $fatal(1,"invalid selftest parameters");
endmodule
