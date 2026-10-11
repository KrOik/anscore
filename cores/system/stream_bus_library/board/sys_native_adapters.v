// Verification fixtures expose native IPs to a96-bit host stimulus record.
// These adapters/fixtures are NOT counted as independent IPs.
module sys_native_adapters(input wire clk,rst_n,input wire [5:0] selected,
 input wire [95:0] q_data,input wire q_valid,output wire q_ready,
 output wire [191:0] r_data,output wire r_valid,input wire r_ready);
wire [31:0] a=q_data[31:0],b=q_data[63:32],c=q_data[95:64];
wire [15:0] ready,valid;
wire [191:0] result[0:15];
assign q_ready=ready[selected[3:0]]; assign r_valid=valid[selected[3:0]]; assign r_data=result[selected[3:0]];
wire [15:0] v; genvar z;
generate for(z=0;z<16;z=z+1) begin:sel assign v[z]=q_valid&&(selected==z); end endgenerate

// 0: routed stream {data,keep,user,destination,last}.
wire [3:0] sw_sr,sw_mv,sw_last,sw_mr; wire [127:0] sw_data; wire [15:0] sw_keep; wire [31:0] sw_user,sw_frames;
reg [1:0] out_dest; integer j;
always @* begin out_dest=0; for(j=3;j>=0;j=j-1) if(sw_mv[j]) out_dest=j; end
assign sw_mr=(valid[0]&&r_ready&&(selected==0))?(4'b1<<out_dest):0;
assign ready[0]=sw_sr[b[1:0]]; assign valid[0]=|sw_mv;
assign result[0]={145'd0,sw_last[out_dest],out_dest,sw_user[out_dest*8+:8],sw_keep[out_dest*4+:4],sw_data[out_dest*32+:32]};
sys_frame_switch4 sw(.clk(clk),.rst_n(rst_n),.s_data({4{a}}),.s_keep({4{c[3:0]}}),
 .s_last({4{b[4]}}),.s_valid((4'b1<<b[1:0])&{4{v[0]}}),.s_ready(sw_sr),.s_user({4{c[15:8]}}),.s_dest({4{b[3:2]}}),
 .m_data(sw_data),.m_keep(sw_keep),.m_last(sw_last),.m_valid(sw_mv),.m_ready(sw_mr),.m_user(sw_user),.frames(sw_frames));
// 1: down-conversion, all byte masks.
wire [31:0] wc_data; wire [3:0] wc_keep; wire [7:0] wc_user; wire wc_last;
sys_width_converter wc(clk,rst_n,a,b[3:0],c[7:0],b[4],v[1],ready[1],wc_data,wc_keep,wc_user,wc_last,valid[1],r_ready&&(selected==1));
assign result[1]={147'd0,wc_last,wc_user,wc_keep,wc_data};
// 2: packet memory and toggle handshake. Same clock on this board fixture;
// independent clock ratios are exercised in the native simulation.
wire [31:0] pf_data,pf_drops; wire pf_last;
sys_packet_async_fifo #(.WIDTH(32)) pf(clk,clk,rst_n,a,b[0],v[2],ready[2],pf_data,pf_last,valid[2],r_ready&&(selected==2),pf_drops);
assign result[2]={127'd0,pf_drops,pf_last,pf_data};
// 3: full96-bit elastic isolation.
wire [95:0] iso_data;
sys_backpressure_isolator #(.WIDTH(96)) iso(clk,rst_n,q_data,v[3],ready[3],iso_data,valid[3],r_ready&&(selected==3));
assign result[3]={96'd0,iso_data};
// 4: independent AXI channels and four byte-strobed register slave fixtures.
sys_axi_fixture ax(clk,rst_n,q_data,v[4],ready[4],result[4],valid[4],r_ready&&(selected==4));
// 5: request deadlines and deliberately late responses.
sys_timeout_fixture tm(clk,rst_n,q_data,v[5],ready[5],result[5],valid[5],r_ready&&(selected==5));
// 6: commit with same-edge write; application delayed by c clocks.
reg cfg_busy,cfg_out; reg [15:0] cfg_age,cfg_delay; wire [127:0] cfg_active; wire [31:0] cfg_version; wire cfg_pending,cfg_wr,cfg_cr;
assign ready[6]=!cfg_busy&&!cfg_out;
wire cfg_take=v[6]&&ready[6]; wire cfg_safe=cfg_busy&&cfg_age>=cfg_delay;
sys_atomic_config cfg(clk,rst_n,cfg_take,cfg_wr,b[1:0],a,b[7:4],cfg_take,cfg_cr,cfg_safe,cfg_active,cfg_version,cfg_pending);
assign valid[6]=cfg_out; assign result[6]={32'd0,cfg_version,cfg_active};
always @(posedge clk or negedge rst_n) begin
 if(!rst_n) begin cfg_busy<=0; cfg_out<=0; cfg_age<=0; cfg_delay<=0; end
 else begin
  if(cfg_out&&r_ready&&selected==6) cfg_out<=0;
  if(cfg_take) begin cfg_busy<=1; cfg_age<=0; cfg_delay<=c[15:0]; end
  if(cfg_busy) begin cfg_age<=cfg_age+1'b1; if(cfg_safe) begin cfg_busy<=0; cfg_out<=1; end end
 end
end
// 7: coherent96-bit fixture registers, timestamp64.
wire [127:0] snap; wire [63:0] snap_time; wire [31:0] snap_id;
sys_register_snapshot sn(clk,rst_n,{32'd0,q_data},v[7],ready[7],r_ready&&(selected==7),valid[7],snap,snap_time,snap_id);
assign result[7]={snap_time,snap};
// 8: payload/tag with acceptance-time counter.
wire [31:0] ts_data; wire [15:0] ts_tag; wire [63:0] ts_time,ts_now;
sys_timestamp64 ts(clk,rst_n,v[8]&&ready[8]&&c[31],{33'd0,c[30:0]},a,b[15:0],v[8],ready[8],ts_data,ts_tag,ts_time,valid[8],r_ready&&(selected==8),ts_now);
assign result[8]={80'd0,ts_time,ts_tag,ts_data};
// 9: one host row per lane, full frame emitted once all four are present.
wire [3:0] al_ready,al_missing; wire [127:0] al_data; wire [31:0] al_epoch,al_stale;
sys_frame_align4 al(clk,rst_n,{4{a}},{4{b}},(4'b1<<c[1:0])&{4{v[9]}},al_ready,16'd0,
 al_data,al_epoch,al_missing,valid[9],r_ready&&(selected==9),al_stale);
assign ready[9]=al_ready[c[1:0]]; assign result[9]={28'd0,al_missing,al_epoch,al_data};
// 10: one-shot trigger,4pre+trigger+4post.
reg armed; wire arm_ready,tr_busy,tr_triggered,tr_last; wire [31:0] tr_data; wire [15:0] tr_length;
always @(posedge clk or negedge rst_n) if(!rst_n) armed<=0; else if(arm_ready) armed<=1;
sys_trigger_window tr(clk,rst_n,!armed,arm_ready,a,b[0],v[10],ready[10],tr_data,tr_last,valid[10],r_ready&&(selected==10),tr_busy,tr_triggered,tr_length);
assign result[10]={143'd0,tr_length,tr_last,tr_data};
// 11: signed calibration, tag=b[31:16], channel=c[25:24].
wire [23:0] cal_data; wire [1:0] cal_channel; wire [31:0] cal_tag; wire cal_sat;
sys_calibration24 cal(clk,rst_n,a[23:0],c[23:0],b[15:0],c[25:24],{16'd0,b[31:16]},v[11],ready[11],cal_data,cal_channel,cal_tag,cal_sat,valid[11],r_ready&&(selected==11));
assign result[11]={128'd0,cal_tag,5'd0,cal_sat,cal_channel,cal_data};
// 12: complete64-word March C-, synchronous RAM fixture, optional injected failure.
sys_march_fixture ma(clk,rst_n,q_data,v[12],ready[12],result[12],valid[12],r_ready&&(selected==12));
// 13: functional fault injection.
wire [31:0] fi_data,fi_count; wire fi_injected,fi_error;
sys_fault_injector fi(clk,rst_n,a,b,c[1:0],c[2],c[23:8],v[13],ready[13],fi_data,fi_injected,fi_error,valid[13],r_ready&&(selected==13),fi_count);
assign result[13]={96'd0,fi_count,30'd0,fi_error,fi_injected,fi_data};
// 14: stream_metrics in transport observes this registered identity fixture.
// 15: capture_replay in transport replays/records this registered identity fixture.
reg echo_valid; reg [95:0] echo;
assign ready[14]=!echo_valid||r_ready; assign ready[15]=ready[14];
assign valid[14]=echo_valid; assign valid[15]=echo_valid;
assign result[14]={96'd0,echo}; assign result[15]={96'd0,echo};
always @(posedge clk or negedge rst_n)
 if(!rst_n) begin echo_valid<=0; echo<=0; end
 else if(!echo_valid||r_ready) begin echo_valid<=v[14]||v[15]; if(v[14]||v[15]) echo<=q_data; end
endmodule

module sys_axi_fixture(input wire clk,rst_n,input wire [95:0] q,input wire v,output wire ready,
 output reg [191:0] result,output reg valid,input wire out_ready);
reg engaged,write,aw_sent,w_sent,ar_sent,w_first; reg [3:0] age;
reg [15:0] addr; reg [31:0] data; reg [3:0] strb; reg [2:0] prot;
wire awready,wready,arready,bvalid,rvalid; wire [1:0] bresp,rresp; wire [31:0] rdata;
wire [63:0] ma,ra; wire [11:0] mp,rp; wire [127:0] md; wire [15:0] ms;
wire [3:0] mav,mwv,mbr,rav,rr;
reg [3:0] mbv,mrv; reg [7:0] mbs,mrs; reg [127:0] mrd;
reg [3:0] ah,wh; reg [11:0] sa[0:3]; reg [31:0] sd[0:3],store[0:3]; reg [3:0] st[0:3];
wire take=v&&ready;
wire av=engaged&&write&&!aw_sent&&(age>=(w_first?3:0));
wire wv=engaged&&write&&!w_sent&&(age>=(w_first?0:3));
wire arv=engaged&&!write&&!ar_sent;
assign ready=!engaged&&!valid;
sys_axi_lite_interconnect ax(clk,rst_n,addr,prot,av,awready,data,strb,wv,wready,bresp,bvalid,1'b1,
 addr,prot,arv,arready,rdata,rresp,rvalid,1'b1,ma,mp,mav,4'hf,md,ms,mwv,4'hf,mbs,mbv,mbr,
 ra,rp,rav,4'hf,mrd,mrs,mrv,rr);
integer i,k;
always @(posedge clk or negedge rst_n) begin
 if(!rst_n) begin
  engaged<=0; valid<=0; result<=0; write<=0; aw_sent<=0; w_sent<=0; ar_sent<=0; w_first<=0;
  age<=0; addr<=0; data<=0; strb<=0; prot<=0; mbv<=0; mrv<=0; mbs<=0; mrs<=0; mrd<=0; ah<=0; wh<=0;
  for(i=0;i<4;i=i+1) begin sa[i]<=0; sd[i]<=0; st[i]<=0; store[i]<=0; end
 end else begin
  if(valid&&out_ready) valid<=0;
  if(take) begin engaged<=1; addr<=q[15:0]; write<=q[16]; prot<=q[19:17]; w_first<=q[20];
   data<=q[63:32]; strb<=q[67:64]; aw_sent<=0; w_sent<=0; ar_sent<=0; age<=0; end
  if(engaged&&age<15) age<=age+1'b1;
  if(av&&awready) aw_sent<=1; if(wv&&wready) w_sent<=1; if(arv&&arready) ar_sent<=1;
  if(engaged&&((write&&bvalid)||(!write&&rvalid))) begin
   engaged<=0; valid<=1;
   result<={128'd0,addr,13'd0,write,(write?bresp:rresp),
    (write?((addr[15:14]==0)?store[addr[13:12]]:32'd0):rdata)};
  end
  for(i=0;i<4;i=i+1) begin
   if(mbv[i]&&mbr[i]) mbv[i]<=0;
   if(mrv[i]&&rr[i]) mrv[i]<=0;
   if(mav[i]) begin ah[i]<=1; sa[i]<=ma[i*16+:12]; end
   if(mwv[i]) begin wh[i]<=1; sd[i]<=md[i*32+:32]; st[i]<=ms[i*4+:4]; end
   if(ah[i]&&wh[i]&&!mbv[i]) begin
    ah[i]<=0; wh[i]<=0; mbv[i]<=1; mbs[i*2+:2]<=sa[i][11]?2'd2:2'd0;
    for(k=0;k<4;k=k+1) if(st[i][k]) store[i][k*8+:8]<=sd[i][k*8+:8];
   end
   if(rav[i]) begin mrv[i]<=1; mrd[i*32+:32]<=store[i]; mrs[i*2+:2]<=ra[i*16+11]?2'd2:2'd0; end
  end
 end
end
endmodule

module sys_timeout_fixture(input wire clk,rst_n,input wire [95:0] q,input wire v,output wire ready,
 output wire [191:0] result,output reg valid,input wire out_ready);
reg busy; reg [15:0] count,delay,limit; reg overlap;
wire take=v&&ready; wire response=busy&&count==delay;
wire outstanding,timed_out,pulse; wire [15:0] age,max_age; wire [31:0] timeouts,overlaps,late;
assign ready=!busy&&!valid;
sys_bus_timeout_monitor tm(clk,rst_n,1'b0,take||(busy&&count==1&&overlap),1'b1,response,1'b1,limit,outstanding,timed_out,pulse,age,max_age,timeouts,overlaps,late);
assign result={80'd0,max_age,late,overlaps,timeouts};
always @(posedge clk or negedge rst_n) begin
 if(!rst_n) begin busy<=0; valid<=0; count<=0; delay<=0; limit<=0; overlap<=0; end
 else begin
  if(valid&&out_ready) valid<=0;
  if(take) begin busy<=1; count<=0; limit<=q[47:32]; delay<=q[79:64]; overlap<=q[0]; end
  if(busy) begin count<=count+1'b1; if(response) begin busy<=0; valid<=1; end end
 end
end
endmodule

module sys_march_fixture(input wire clk,rst_n,input wire [95:0] q,input wire v,output wire ready,
 output wire [191:0] result,output reg valid,input wire out_ready);
reg engaged; reg [2:0] injection; reg [31:0] cycles; wire busy,done,mv,mw,rr;
wire [5:0] address,first; wire [31:0] wd,errors; wire [2:0] phase;
reg rsp_valid; reg [31:0] ram_data; reg corrupt_read;
wire [31:0] rd=ram_data^(corrupt_read?32'd1:32'd0);
(* ram_style="block" *) reg [31:0] mem[0:63];
wire take=v&&ready; wire accept=mv&&!injection[2];
assign ready=!engaged&&!valid; assign result={119'd0,phase,first,cycles,errors};
sys_march_controller #(.TIMEOUT(128)) march(clk,rst_n,take,busy,done,mv,!injection[2],mw,address,wd,rsp_valid,rr,rd,injection[1],errors,first,phase);
always @(posedge clk) if(accept) begin
 if(mw) mem[address]<=wd;
 ram_data<=mem[address];
 corrupt_read<=injection[0]&&!mw&&address==3;
end
always @(posedge clk or negedge rst_n) begin
 if(!rst_n) begin engaged<=0; valid<=0; rsp_valid<=0; injection<=0; cycles<=0; end
 else begin
  if(valid&&out_ready) valid<=0;
  if(take) begin engaged<=1; injection<=q[2:0]; cycles<=0; end
  if(engaged) cycles<=cycles+1;
  if(done&&engaged&&!busy) begin engaged<=0; valid<=1; end
  if(rsp_valid&&rr) rsp_valid<=0;
  if(accept) rsp_valid<=1;
 end
end
endmodule
