module stream_secded_decode #(
 parameter integer DATA_W=64,
 parameter integer TAG_W=16,
 localparam integer PARITY_W=(DATA_W<=1)?2:(DATA_W<=4)?3:(DATA_W<=11)?4:
                            (DATA_W<=26)?5:(DATA_W<=57)?6:(DATA_W<=120)?7:8,
 localparam integer CODE_W=DATA_W+PARITY_W+1
)(
 input wire clk,input wire rst,
 input wire s_valid,output wire s_ready,
 input wire [CODE_W-1:0] s_code,input wire s_last,input wire [TAG_W-1:0] s_tag,
 output wire m_valid,input wire m_ready,
 output reg [DATA_W-1:0] m_data,output reg [CODE_W-1:0] m_code,
 output reg [1:0] m_status,output reg [PARITY_W-1:0] m_syndrome,
 output reg m_parity,output reg m_last,output reg [TAG_W-1:0] m_tag
);
 localparam integer N=CODE_W-1;
 reg first_valid,out_valid;
 reg [CODE_W-1:0] code1;
 reg [PARITY_W-1:0] syndrome1;
 reg parity1,last1;
 reg [TAG_W-1:0] tag1;
 wire ready2=!out_valid||m_ready;
 wire ready1=!first_valid||ready2;
 assign s_ready=!rst&&ready1;
 assign m_valid=!rst&&out_valid;
 // Interleaved code positions1..N use parity at powers of two; bitN is overall parity.
 reg [PARITY_W-1:0] syndrome_in;
 integer row,pos;
 always @* begin
  syndrome_in=0;
  for(row=0;row<PARITY_W;row=row+1)
   for(pos=1;pos<=N;pos=pos+1)
    if((pos&(1<<row))!=0)syndrome_in[row]=syndrome_in[row]^s_code[pos-1];
 end
 wire correctable=parity1&&(syndrome1<=N);
 wire uncorrectable=(!parity1&&(syndrome1!=0))||(parity1&&(syndrome1>N));
 reg [CODE_W-1:0] corrected;
 reg [DATA_W-1:0] extracted;
 integer bit_pos,data_pos;
 always @* begin
  corrected=code1;
  if(correctable)begin
   if(syndrome1==0)corrected[N]=!code1[N];
   else begin
    for(bit_pos=1;bit_pos<=N;bit_pos=bit_pos+1)
     if(syndrome1==bit_pos)corrected[bit_pos-1]=!code1[bit_pos-1];
   end
  end
  extracted=0;data_pos=0;
  for(bit_pos=1;bit_pos<=N;bit_pos=bit_pos+1)begin
   if((bit_pos&(bit_pos-1))!=0)begin
    extracted[data_pos]=corrected[bit_pos-1];data_pos=data_pos+1;
   end
  end
 end
 always @(posedge clk)begin
  if(rst)begin first_valid<=0;out_valid<=0;end
  else begin
   if(ready1)begin
    first_valid<=s_valid;
    if(s_valid)begin code1<=s_code;syndrome1<=syndrome_in;parity1<=^s_code;last1<=s_last;tag1<=s_tag;end
   end
   if(ready2)begin
    out_valid<=first_valid;
    if(first_valid)begin
     m_data<=extracted;m_code<=corrected;
     m_status<=uncorrectable?2'd2:correctable?2'd1:2'd0;
     m_syndrome<=syndrome1;m_parity<=parity1;m_last<=last1;m_tag<=tag1;
    end
   end
  end
 end
 initial begin
  if(DATA_W<1||DATA_W>128||TAG_W<1)$fatal(1,"illegal parameters");
 end
endmodule
