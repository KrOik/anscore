// One-shot synchronous ring capture. Trigger accompanies an accepted sample.
module sys_trigger_window #(parameter DEPTH=16,PRE=4,POST=4,WIDTH=32)(
 input wire clk,rst_n,arm,output wire arm_ready,
 input wire [WIDTH-1:0] s_data,input wire s_trigger,s_valid,output wire s_ready,
 output wire [WIDTH-1:0] m_data,output reg m_last,m_valid,input wire m_ready,
 output wire busy,output reg triggered,output reg [15:0] capture_length
);
localparam AW=$clog2(DEPTH);
(* ram_style="block" *) reg [WIDTH-1:0] mem[0:DEPTH-1];
reg [1:0] state;
reg [AW-1:0] write_ptr,read_ptr;
reg [15:0] history,post_left,issued;
reg [WIDTH-1:0] read_data;
wire push=s_valid&&s_ready;
wire fetch=(state==3)&&(issued<capture_length)&&(!m_valid||m_ready);
assign arm_ready=rst_n&&(state==0)&&!m_valid;
assign s_ready=rst_n&&(state==1||state==2);
assign busy=(state!=0);
assign m_data=read_data;
always @(posedge clk) if(push) mem[write_ptr]<=s_data;
always @(posedge clk) if(fetch) read_data<=mem[read_ptr];
always @(posedge clk or negedge rst_n) begin
 if(!rst_n) begin state<=0; write_ptr<=0; read_ptr<=0; history<=0; post_left<=0; issued<=0; triggered<=0; capture_length<=0; m_last<=0; m_valid<=0; end
 else begin
  if(arm&&arm_ready) begin state<=1; write_ptr<=0; history<=0; triggered<=0; capture_length<=0; issued<=0; end
  if(push) begin
   write_ptr<=write_ptr+1'b1;
   if(state==1) begin
    if(s_trigger) begin
     triggered<=1; read_ptr<=write_ptr-history[AW-1:0]; capture_length<=history+1+POST;
     post_left<=POST; state<=(POST==0)?3:2;
    end else if(history<PRE) history<=history+1'b1;
   end else if(state==2) begin
    post_left<=post_left-1'b1; if(post_left==1) state<=3;
   end
  end
  if(fetch) begin read_ptr<=read_ptr+1'b1; issued<=issued+1'b1; m_valid<=1; m_last<=(issued+1'b1==capture_length); end
  else if(m_valid&&m_ready) m_valid<=0;
  if(m_valid&&m_ready&&m_last) state<=0;
 end
end
initial if(DEPTH<2||(DEPTH&(DEPTH-1))!=0||PRE<0||POST<0||PRE+POST+1>DEPTH||WIDTH<1) $fatal(1,"invalid trigger window parameters");
endmodule
