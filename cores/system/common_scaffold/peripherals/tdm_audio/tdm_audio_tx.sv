// Native BCLK domain, falling-edge launch and stream handshakes. CDC external.
module tdm_audio_tx #(
 parameter SLOTS=8,SLOT_BITS=32,SAMPLE_BITS=24,FS_POLARITY=1,
 parameter FS_PULSE_BITS=1,DELAY_BITS=1,FIFO_FRAMES=4)(
 input wire bclk,rst_n,ce,fs,error_clear,
 input wire [SAMPLE_BITS-1:0] s_sample,input wire [3:0] s_slot,
 input wire s_sof,s_last,s_valid,output wire s_ready,
 output reg sd,output reg underrun_sticky,input_error_sticky,framing_sticky,
 output reg [31:0] underrun_count,input_error_count,framing_count);
 localparam FB=SLOTS*SLOT_BITS,FW=SLOTS*SAMPLE_BITS,AW=$clog2(FIFO_FRAMES+1),BCW=$clog2(FB+2);
 reg [FW-1:0] mem[0:FIFO_FRAMES],assembly,pending;
 reg [FB-1:0] bits;
 reg [AW-1:0] wp,rp;reg [AW:0] count;
 reg pending_valid,fs_d,locked;reg [BCW-1:0] phase,pulse;reg [3:0] in_slot;
 wire active=fs==FS_POLARITY,fs_start=active&&!fs_d;
 wire take=ce&&s_valid&&s_ready;
 wire markers=s_slot==in_slot&&s_sof==(in_slot==0)&&s_last==(in_slot==SLOTS-1);
 wire push=take&&markers&&in_slot==SLOTS-1;
 wire use_pending=fs_start&&pending_valid;
 wire fetch=(!pending_valid||use_pending)&&count!=0;
 wire [FW-1:0] assembled=(assembly<<SAMPLE_BITS)|s_sample;
 reg [FB-1:0] padded;
 integer i;
 always @*begin
  padded=0;
  for(i=0;i<SLOTS;i=i+1)padded[FB-1-i*SLOT_BITS -: SAMPLE_BITS]=pending[FW-1-i*SAMPLE_BITS -: SAMPLE_BITS];
 end
 assign s_ready=count<FIFO_FRAMES;
 always @(negedge bclk)begin
  if(push)mem[wp]<=assembled;
  if(fetch)pending<=mem[rp];
 end
 always @(negedge bclk)begin
 if(!rst_n)begin wp<=0;rp<=0;count<=0;assembly<=0;bits<=0;pending_valid<=0;in_slot<=0;sd<=0;fs_d<=0;locked<=0;phase<=0;pulse<=0;underrun_sticky<=0;input_error_sticky<=0;framing_sticky<=0;underrun_count<=0;input_error_count<=0;framing_count<=0;end
 else begin
  fs_d<=active;
  if(ce&&error_clear)begin underrun_sticky<=0;input_error_sticky<=0;framing_sticky<=0;end
  if(fetch)begin pending_valid<=1;rp<=rp==FIFO_FRAMES?0:rp+1'b1;end else if(use_pending)pending_valid<=0;
  if(push)wp<=wp==FIFO_FRAMES?0:wp+1'b1;
  case({push,fetch})2'b10:count<=count+1'b1;2'b01:count<=count-1'b1;default:begin end endcase
  if(take)begin
   if(markers)begin assembly<=assembled;in_slot<=in_slot==SLOTS-1?0:in_slot+1;end
   else begin
    input_error_sticky<=1;input_error_count<=input_error_count+1'b1;in_slot<=0;assembly<=0;
    // A valid new SOF restarts immediately after an interrupted partial frame.
    if(s_sof&&s_slot==0&&!s_last)begin assembly<=s_sample;in_slot<=1;end
   end
  end
  if(fs_start)begin
   if(locked&&phase!=FB)begin framing_sticky<=1;framing_count<=framing_count+1'b1;end
   locked<=1;phase<=1;pulse<=1;
   if(DELAY_BITS==0)begin sd<=pending_valid?padded[FB-1]:0;bits<=pending_valid?(padded<<1):0;end
   else begin sd<=locked&&phase==FB?bits[FB-1]:0;bits<=pending_valid?padded:0;end
   if(!pending_valid)begin underrun_sticky<=1;underrun_count<=underrun_count+1'b1;end
  end else if(locked)begin
   if(active)begin
    if(pulse<FB+1)pulse<=pulse+1;
    if(pulse==FS_PULSE_BITS)begin framing_sticky<=1;framing_count<=framing_count+1'b1;end
   end else if(fs_d&&pulse!=FS_PULSE_BITS)begin framing_sticky<=1;framing_count<=framing_count+1'b1;end
   if(phase>=FB)begin locked<=0;sd<=0;bits<=0;framing_sticky<=1;framing_count<=framing_count+1'b1;end
   else begin sd<=bits[FB-1];bits<=bits<<1;phase<=phase+1;end
  end else sd<=0;
 end end
 initial if(SLOTS<2||SLOTS>16||(SLOT_BITS!=16&&SLOT_BITS!=24&&SLOT_BITS!=32)||SAMPLE_BITS<1||SAMPLE_BITS>SLOT_BITS||(FS_POLARITY!=0&&FS_POLARITY!=1)||FS_PULSE_BITS<1||FS_PULSE_BITS>=FB||(DELAY_BITS!=0&&DELAY_BITS!=1)||FIFO_FRAMES<2||FIFO_FRAMES>8)$fatal(1,"invalid TDM TX parameters");
endmodule
