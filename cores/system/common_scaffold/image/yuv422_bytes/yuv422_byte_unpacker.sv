// Frame-aware byte layout adapter; no chroma resampling or CSC.
module yuv422_byte_unpacker #(parameter WIDTH=16, HEIGHT=12)(
 input clk,rst_n,ce,input start_valid,output start_ready,input [1:0]cfg_order,input abort,
 input [7:0]s_data,input s_valid,output s_ready,input s_sof,s_eol,s_last,
 output [31:0]m_data,output m_valid,input m_ready,output m_sof,m_eol,m_last,
 output reg done_valid,input done_ready,output reg done_error,output reg [7:0]error_code,output busy);
localparam LEGAL=(WIDTH>=2 && WIDTH<=65534 && WIDTH%2==0 && HEIGHT>=1 && HEIGHT<=65535);
localparam ROW=WIDTH/2, TOTAL=ROW*HEIGHT;
reg active;reg [1:0]order,idx;reg [31:0]word;reg [31:0]count;
reg full;
assign busy=active;assign start_ready=!active&&!done_valid;
assign m_valid=active&&full;
assign s_ready=active&&!full;
assign m_data=word;
assign m_sof=count==0;
assign m_eol=count%ROW==ROW-1;
assign m_last=count==TOTAL-1;
task fail;input[7:0]code;begin active<=0;full<=0;done_valid<=1;done_error<=1;error_code<=code;end endtask
always @(posedge clk)begin
 if(!rst_n)begin active<=0;full<=0;done_valid<=0;done_error<=0;error_code<=0;order<=0;idx<=0;word<=0;count<=0;end
 else if(ce)begin
 if(done_valid&&done_ready)done_valid<=0;
 if(start_valid&&start_ready)begin
 order<=cfg_order;idx<=0;word<=0;count<=0;full<=0;done_error<=0;error_code<=0;
 if(!LEGAL)begin active<=0;done_valid<=1;done_error<=1;error_code<=1;end else active<=1;
 end
 if(active)begin
 if(abort)fail(2);
 else begin
if(s_valid&&s_ready)begin
if(s_sof!==(count==0&&idx==0)||s_eol!==(count%ROW==ROW-1&&idx==3)||s_last!==(count==TOTAL-1&&idx==3))fail(3);
else begin
case(order)
0:case(idx)0:word[31:24]<=s_data;1:word[15:8]<=s_data;2:word[23:16]<=s_data;3:word[7:0]<=s_data;endcase
1:case(idx)0:word[15:8]<=s_data;1:word[31:24]<=s_data;2:word[7:0]<=s_data;3:word[23:16]<=s_data;endcase
2:case(idx)0:word[31:24]<=s_data;1:word[7:0]<=s_data;2:word[23:16]<=s_data;3:word[15:8]<=s_data;endcase
3:case(idx)0:word[7:0]<=s_data;1:word[31:24]<=s_data;2:word[15:8]<=s_data;3:word[23:16]<=s_data;endcase
endcase
if(idx==3)begin full<=1;idx<=0;end else idx<=idx+1'b1;
end
end
if(m_valid&&m_ready)begin full<=0;if(count==TOTAL-1)begin active<=0;done_valid<=1;end else count<=count+1'b1;end
end
end
end
end
endmodule
