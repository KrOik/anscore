// One elastic beat. rst_n is synchronous; sidebands travel with data.
module stream_elastic #(parameter DATA_WIDTH=16, USER_WIDTH=1)(
 input wire clk, rst_n,
 input wire [DATA_WIDTH-1:0] s_tdata,
 input wire [USER_WIDTH-1:0] s_tuser,
 input wire s_tlast,s_tvalid, output wire s_tready,
 output reg [DATA_WIDTH-1:0] m_tdata,
 output reg [USER_WIDTH-1:0] m_tuser,
 output reg m_tlast,m_tvalid, input wire m_tready
);
 assign s_tready = !m_tvalid || m_tready;
 always @(posedge clk) begin
   if (!rst_n) m_tvalid <= 0;
   else if (s_tready) begin
     m_tvalid <= s_tvalid;
     if(s_tvalid) begin
       m_tdata<=s_tdata; m_tuser<=s_tuser; m_tlast<=s_tlast;
     end
   end
 end
 initial begin
   if(DATA_WIDTH<1 || USER_WIDTH<1) $fatal(1,"invalid width");
 end
endmodule
