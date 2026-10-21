// Already Huffman-coded entropy bits -> JPEG stuffed bytes. No codebook lookup.
module jpeg_entropy_bitpacker(
 input wire clk,rst_n,ce,
 input wire [15:0] s_code,s_amplitude,
 input wire [4:0] s_code_bits,s_amplitude_bits,
 input wire s_flush,s_valid,output wire s_ready,
 output reg [7:0] m_data,output reg m_valid,m_last,input wire m_ready,
 output reg input_error,flush_done,output wire [6:0] pending_bits
);
 localparam IDLE=0,DRAIN=1,HOLD=2,STUFF=3;
 reg [1:0] state;
 reg [63:0] buffer;
 reg [6:0] count;
 reg flushing;
 wire [5:0] token_bits={1'b0,s_code_bits}+{1'b0,s_amplitude_bits};
 wire [7:0] next_byte=buffer>>(count-8);
 reg [63:0] appended;
 integer new_count,padding;
 wire bad=s_code_bits>16 || s_amplitude_bits>16 ||
   (s_code >> s_code_bits)!=0 || (s_amplitude >> s_amplitude_bits)!=0 ||
   (s_code_bits==0 && (!s_flush || s_amplitude_bits!=0));
 assign s_ready=rst_n&&ce&&state==IDLE;
 assign pending_bits=count;
 always @* begin
  appended=(buffer<<token_bits) |
           ({48'b0,s_code}<<s_amplitude_bits) | {48'b0,s_amplitude};
  new_count=count+token_bits;
  padding=0;
  if(s_flush) begin
   padding=(8-(new_count%8))%8;
   appended=(appended<<padding)|((64'd1<<padding)-1'b1);
   new_count=new_count+padding;
  end
 end
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   state<=IDLE;buffer<=0;count<=0;flushing<=0;
   m_data<=0;m_valid<=0;m_last<=0;input_error<=0;flush_done<=0;
  end else if(ce) begin
   input_error<=0;flush_done<=0;
   case(state)
    IDLE: if(s_valid&&s_ready) begin
     if(bad) input_error<=1;
     else begin buffer<=appended;count<=new_count;flushing<=s_flush;state<=DRAIN;end
    end
    DRAIN: if(count>=8) begin
     m_data<=next_byte;m_valid<=1;
     m_last<=flushing&&count==8&&next_byte!=8'hff;
     count<=count-8;state<=HOLD;
    end else begin
     if(flushing) flush_done<=1;
     flushing<=0;state<=IDLE;
    end
    HOLD: if(m_ready) begin
     m_valid<=0;m_last<=0;
     if(m_data==8'hff) state<=STUFF;else state<=DRAIN;
    end
    STUFF: begin
     m_data<=0;m_valid<=1;m_last<=flushing&&count==0;state<=HOLD;
    end
   endcase
  end
 end
endmodule
