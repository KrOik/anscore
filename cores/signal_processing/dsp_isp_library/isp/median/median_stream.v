module median_stream #(parameter BITS=8,WIDTH=32,HEIGHT=24,K=3,PAD_MODE=0,MAX_WIDTH=4096)(
 input wire clk,rst_n,input wire [BITS-1:0] s_tdata,input wire s_tvalid,s_tuser,s_tlast,
 output wire s_tready,output wire [BITS-1:0] m_tdata,output wire m_tvalid,m_tuser,m_tlast,
 input wire m_tready,output wire marker_error
);
 wire [K*K*BITS-1:0] window;wire valid,ready,sof,eol;
 stream_window_padded #(.DATA_WIDTH(BITS),.WIDTH(WIDTH),.HEIGHT(HEIGHT),.K(K),.PAD_MODE(PAD_MODE),.MAX_WIDTH(MAX_WIDTH)) win(
 .clk(clk),.rst_n(rst_n),.s_tdata(s_tdata),.s_tvalid(s_tvalid),.s_tuser(s_tuser),.s_tlast(s_tlast),.s_tready(s_tready),
 .m_tdata(window),.m_tvalid(valid),.m_tuser(sof),.m_tlast(eol),.m_tready(ready),.marker_error(marker_error));
 median_network #(.BITS(BITS),.K(K)) net(.clk(clk),.rst_n(rst_n),.s_tdata(window),.s_tvalid(valid),.s_tuser(sof),.s_tlast(eol),.s_tready(ready),.m_tdata(m_tdata),.m_tvalid(m_tvalid),.m_tuser(m_tuser),.m_tlast(m_tlast),.m_tready(m_tready));
 initial if((BITS!=8 && BITS!=10)||WIDTH<1||HEIGHT<1||(K!=3 && K!=5)||(PAD_MODE!=0 && PAD_MODE!=1))$fatal(1,"unsupported median_stream parameters");
endmodule
