// Three live scanouts, runtime CSR configuration and coherent result mailboxes.
module video_control #(parameter [63:0] BUILD_ID=0)(
 input wire clk,rst_n,req_valid,req_write,input wire [9:0] req_addr,
 input wire [31:0] req_data,input wire [3:0] req_strobe,
 output wire req_ready,resp_valid,output wire resp_error,output wire [31:0] resp_data,
 input wire resp_ready,
 output wire [2:0] pixel_valid,de,hsync,vsync,output wire [71:0] rgb,
 output wire [7:0] probe
);
reg [31:0] timing[0:29];reg [15:0] phase[0:2];reg [31:0] produced[0:2];
reg local_response,local_error;reg [31:0] local_data;
wire mqready,mvalid,merror;wire [31:0] mdata;
wire [2:0] ready,run,done,err,wr,cr,pending,ov,rv,slots;
wire [95:0] versions,rf,rc,rp,sf;wire [23:0] re;wire [38:0] rver;
wire take=req_valid&&req_ready;
wire global_req=req_addr[9:8]==0;
wire [1:0] bank=req_addr[9:8]-1'b1;
wire aligned=req_addr[1:0]==0;
wire layer_addr=req_addr[7:0]>=8'h40&&req_addr[7:0]<=8'h5c;
wire full=req_strobe==15;
assign req_ready=rst_n&&!local_response&&mqready;
assign resp_valid=local_response||mvalid;
assign resp_error=local_response?local_error:merror;
assign resp_data=local_response?local_data:mdata;
assign probe={|ov,|err,|slots,|pending,|rv,run};
video_results_csr #(.BUILD_ID(BUILD_ID)) results(clk,rst_n,rv,rf,rc,rp,re,rver,
 req_valid&&global_req&&!local_response,req_write,req_addr[7:0],req_data,req_strobe,
 mqready,mvalid,merror,mdata,resp_ready&&!local_response,slots);
genvar g;
generate for(g=0;g<3;g=g+1)begin: lanes
 wire selected=take&&!global_req&&bank==g&&aligned&&req_write;
 wire launch=selected&&req_addr[7:0]==8'h30&&full&&req_data==1&&ready[g]&&!pending[g]&&versions[g*32+:32]!=0;
 wire halt=selected&&req_addr[7:0]==8'h30&&full&&req_data==2;
 wire cancel=selected&&req_addr[7:0]==8'h30&&full&&req_data==4;
 wire automatic_stop=run[g]&&sf[g*32+:32]>=timing[g*10+9]-1;
 wire commit=selected&&req_addr[7:0]==8'h38&&full&&req_data==1;
 wire [31:0] unused_frame;wire [12:0] unused_ver;wire [7:0] unused_error;
 wire unused_sof,unused_eol,unused_last;
 raster_osd_output output_lane(.clk(clk),.rst_n(rst_n),.pixel_tick(phase[g]==0),
 .start_valid(launch),.stop(halt||automatic_stop),.abort(cancel),.done_ready(1'b1),
 .start_ready(ready[g]),.running(run[g]),.done_valid(done[g]),.frame_error(err[g]),
 .h_active(timing[g*10][15:0]),.h_front(timing[g*10+1][15:0]),.h_sync(timing[g*10+2][15:0]),.h_back(timing[g*10+3][15:0]),
 .v_active(timing[g*10+4][15:0]),.v_front(timing[g*10+5][15:0]),.v_sync(timing[g*10+6][15:0]),.v_back(timing[g*10+7][15:0]),
 .h_positive(1'b1),.v_positive(1'b0),
 .write_valid(selected&&layer_addr),.write_ready(wr[g]),.write_index(req_addr[4:2]),
 .write_data(req_data),.write_strb(req_strobe),.commit_valid(commit),.commit_ready(cr[g]),.pending(pending[g]),
 .config_version(versions[g*32+:32]),.pixel_valid(pixel_valid[g]),.rgb(rgb[g*24+:24]),
 .out_de(de[g]),.out_hsync(hsync[g]),.out_vsync(vsync[g]),.out_sof(unused_sof),.out_eol(unused_eol),.out_last(unused_last),
 .out_frame(unused_frame),.out_version(unused_ver),.out_error(unused_error),
 .crc_valid(rv[g]),.crc_frame(rf[g*32+:32]),.crc_value(rc[g*32+:32]),.crc_pixels(rp[g*32+:32]),
 .crc_error(re[g*8+:8]),.crc_version(rver[g*13+:13]),.overflow(ov[g]),.source_frame(sf[g*32+:32]));
 always @(posedge clk)begin
  if(!rst_n)begin phase[g]<=0;produced[g]<=0;end
  else begin
   if(launch||phase[g]+32'd1>=timing[g*10+8])phase[g]<=0;else phase[g]<=phase[g]+1;
   if(launch)produced[g]<=0;else if(rv[g])produced[g]<=produced[g]+1;
  end
 end
end endgenerate
integer i,b;reg [7:0] offset;
always @(posedge clk)begin
 if(!rst_n)begin
  local_response<=0;local_error<=0;local_data<=0;
  for(i=0;i<3;i=i+1)begin
   timing[i*10]<=4+i;timing[i*10+1]<=1;timing[i*10+2]<=1;timing[i*10+3]<=2;
   timing[i*10+4]<=3;timing[i*10+5]<=1;timing[i*10+6]<=1;timing[i*10+7]<=1;
   timing[i*10+8]<=i+1;timing[i*10+9]<=1;
  end
 end else begin
  if(local_response&&resp_ready)local_response<=0;
  if(take&&!global_req)begin
   local_response<=1;local_error<=0;local_data<=0;b=bank;offset=req_addr[7:0];
   if(!aligned)local_error<=1;
   else if(req_write)begin
    if(offset<8'h28)begin
     if(!full||!ready[b]||req_data>65535||((offset==8'h20||offset==8'h24)&&req_data==0))local_error<=1;
     else timing[b*10+offset/4]<=req_data;
    end else if(layer_addr)begin if(!wr[b])local_error<=1;end
    else if(offset==8'h38)begin if(!full||req_data!=1||!cr[b])local_error<=1;end
    else if(offset==8'h30)begin
     if(!full||(req_data!=1&&req_data!=2&&req_data!=4))local_error<=1;
     else if(req_data==1&&(!ready[b]||pending[b]||versions[b*32+:32]==0))local_error<=1;
    end else local_error<=1;
   end else begin
    if(offset<8'h28)local_data<=timing[b*10+offset/4];
    else case(offset)
     8'h2c:local_data<={26'd0,pending[b],ov[b],err[b],done[b],run[b],ready[b]};
     8'h34:local_data<=versions[b*32+:32];
     8'h60:local_data<=produced[b];
     8'h64:local_data<=sf[b*32+:32];
     default:local_error<=1;
    endcase
   end
  end
 end
end
endmodule
