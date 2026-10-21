// Frame-atomic video routing around unchanged canonical four-way switch.
// No CDC/buffering; all source fields must hold while valid&&!ready.
module video_route4(
 input wire clk,rst_n,
 input wire [95:0] s_rgb,input wire [127:0] s_frame,
 input wire [63:0] s_user,input wire [31:0] s_error,
 input wire [3:0] s_sof,s_eol,s_last,s_valid,output wire [3:0] s_ready,
 input wire [3:0] write_valid,output wire [3:0] write_ready,
 input wire [3:0] write_index,input wire [127:0] write_data,
 input wire [15:0] write_strb,input wire [3:0] commit_valid,
 output wire [3:0] commit_ready,pending,framing_error,
 output wire [127:0] config_version,
 output wire [95:0] m_rgb,output wire [127:0] m_frame,
 output wire [63:0] m_user,output wire [31:0] m_error,
 output wire [3:0] m_sof,m_eol,m_last,m_valid,input wire [3:0] m_ready,
 output wire [31:0] frames
);
wire [323:0] payload;wire [3:0] gv,gr,gs,gl;
wire [127:0] data,od;wire [31:0] tag,ot;wire [7:0] dest;
wire [15:0] keep;
genvar g;
generate for(g=0;g<4;g=g+1)begin: source
 wire [63:0] active;wire owned;
 frame_atomic_config #(.WORDS(2),.DATA_W(81)) gate(
 .clk(clk),.rst_n(rst_n),.write_valid(write_valid[g]),.write_ready(write_ready[g]),
 .write_index(write_index[g]),.write_data(write_data[g*32+:32]),.write_strb(write_strb[g*4+:4]),
 .commit_valid(commit_valid[g]),.commit_ready(commit_ready[g]),.active(active),
 .version(config_version[g*32+:32]),.pending(pending[g]),
 .s_valid(s_valid[g]),.s_ready(s_ready[g]),
 .s_data({s_error[g*8+:8],s_frame[g*32+:32],s_user[g*16+:16],s_eol[g],s_rgb[g*24+:24]}),
 .s_sof(s_sof[g]),.s_last(s_last[g]),.m_valid(gv[g]),.m_ready(gr[g]),
 .m_data(payload[g*81+:81]),.m_sof(gs[g]),.m_last(gl[g]),
 .in_frame(owned),.framing_error(framing_error[g]));
 assign data[g*32+:32]={payload[g*81+73+:8],payload[g*81+:24]};
 assign tag[g*8+:8]=g;
 assign dest[g*2+:2]=active[1:0];
 // Switch has no storage. Its source tag selects the same stable sideband
 // beat that supplied RGB/error, preserving full-width video metadata.
 wire [1:0] selected=ot[g*8+:2];
 assign m_rgb[g*24+:24]=od[g*32+:24];
 assign m_error[g*8+:8]=od[g*32+24+:8];
 assign m_eol[g]=payload[selected*81+24];
 assign m_user[g*16+:16]=payload[selected*81+25+:16];
 assign m_frame[g*32+:32]=payload[selected*81+41+:32];
 assign m_sof[g]=gs[selected];
end endgenerate
sys_frame_switch4 switch(clk,rst_n,data,16'hffff,gl,gv,gr,tag,dest,
 od,keep,m_last,m_valid,m_ready,ot,frames);
endmodule
