// Native BCLK domain, rising-edge capture. CDC belongs outside this core.
module tdm_audio_rx #(
 parameter SLOTS=8,SLOT_BITS=32,SAMPLE_BITS=24,FS_POLARITY=1,
 parameter FS_PULSE_BITS=1,DELAY_BITS=1,FIFO_FRAMES=4)(
 input wire bclk,rst_n,ce,fs,sd,error_clear,
 output wire [SAMPLE_BITS-1:0] m_sample,output wire [3:0] m_slot,
 output wire m_sof,m_last,m_valid,input wire m_ready,
 output reg overflow_sticky,framing_sticky,
 output reg [31:0] overflow_count,framing_count);
 localparam FB=SLOTS*SLOT_BITS,FW=SLOTS*SAMPLE_BITS,AW=$clog2(FIFO_FRAMES+1),BCW=$clog2(FB+2);
 reg [FW-1:0] mem[0:FIFO_FRAMES],work,out_frame;
 reg [AW-1:0] wp,rp;reg [AW:0] count;
 reg qvalid,fs_d,locked,bad,complete;
 reg [BCW-1:0] phase,pulse;reg [3:0] out_slot;
 wire active=fs==FS_POLARITY;
 wire fs_start=active&&!fs_d;
 wire consume=ce&&m_ready&&qvalid;
 wire fetch=(!qvalid||(consume&&out_slot==SLOTS-1))&&count!=0;
 // DELAY=1/full slot ends the old frame at the next FS edge.
 wire wrap_sample=DELAY_BITS==1&&SAMPLE_BITS==SLOT_BITS;
 wire good=locked&&phase==FB&&!bad&&(complete||wrap_sample);
 wire commit=fs_start&&good;
 wire push=commit&&(count<FIFO_FRAMES||fetch);
 wire [FW-1:0] final_frame=wrap_sample?((work<<1)|sd):work;
 assign m_sample=out_frame[FW-1 -: SAMPLE_BITS];
 assign m_slot=out_slot;assign m_sof=out_slot==0;assign m_last=out_slot==SLOTS-1;assign m_valid=qvalid;
 always @(posedge bclk)begin
  if(push)mem[wp]<=final_frame;
  if(fetch)out_frame<=mem[rp];else if(consume)out_frame<=out_frame<<SAMPLE_BITS;
 end
 wire [BCW-1:0] rel=phase-DELAY_BITS;
 wire [BCW-1:0] pos=rel%SLOT_BITS;
 always @(posedge bclk)begin
 if(!rst_n)begin wp<=0;rp<=0;count<=0;qvalid<=0;out_slot<=0;work<=0;fs_d<=0;locked<=0;bad<=0;complete<=0;phase<=0;pulse<=0;overflow_sticky<=0;framing_sticky<=0;overflow_count<=0;framing_count<=0;end
 else begin
  fs_d<=active;
  if(ce&&error_clear)begin overflow_sticky<=0;framing_sticky<=0;end
  if(fetch)begin qvalid<=1;out_slot<=0;rp<=rp==FIFO_FRAMES?0:rp+1'b1;end
  else if(consume)begin if(out_slot==SLOTS-1)begin qvalid<=0;out_slot<=0;end else out_slot<=out_slot+1;end
  if(push)wp<=wp==FIFO_FRAMES?0:wp+1'b1;
  case({push,fetch})2'b10:count<=count+1'b1;2'b01:count<=count-1'b1;default:begin end endcase
  if(commit&&!push)begin overflow_sticky<=1;overflow_count<=overflow_count+1'b1;end
  if(fs_start)begin
   if(locked&&!good)begin framing_sticky<=1;framing_count<=framing_count+1'b1;end
   locked<=1;bad<=0;complete<=0;phase<=1;pulse<=1;
   work<=DELAY_BITS==0?{{(FW-1){1'b0}},sd}:0;
  end else if(locked)begin
   if(active)begin
    if(pulse<FB+1)pulse<=pulse+1;
    if(pulse==FS_PULSE_BITS)begin bad<=1;framing_sticky<=1;framing_count<=framing_count+1'b1;end
   end else if(fs_d&&pulse!=FS_PULSE_BITS)begin bad<=1;framing_sticky<=1;framing_count<=framing_count+1'b1;end
   if(phase>=FB)begin locked<=0;bad<=1;framing_sticky<=1;framing_count<=framing_count+1'b1;end
   else begin
    if(phase>=DELAY_BITS)begin
     if(pos<SAMPLE_BITS)begin work<=(work<<1)|sd;if(rel==(SLOTS-1)*SLOT_BITS+SAMPLE_BITS-1)complete<=1;end
    end
    phase<=phase+1;
   end
  end
 end end
 initial if(SLOTS<2||SLOTS>16||(SLOT_BITS!=16&&SLOT_BITS!=24&&SLOT_BITS!=32)||SAMPLE_BITS<1||SAMPLE_BITS>SLOT_BITS||(FS_POLARITY!=0&&FS_POLARITY!=1)||FS_PULSE_BITS<1||FS_PULSE_BITS>=FB||(DELAY_BITS!=0&&DELAY_BITS!=1)||FIFO_FRAMES<2||FIFO_FRAMES>8)$fatal(1,"invalid TDM RX parameters");
endmodule
