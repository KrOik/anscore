// Catmull-Rom a=-0.5, asymmetric Q8 coordinates, clamped edges.
// Coefficients Q16 rounded toward -infinity; w3 closes exact unit sum.
module cip_image_bicubic_frame #(
 parameter DATA_W=24,TAG_W=8,MAX_WIDTH=64,MAX_HEIGHT=64,PIXEL_W=8
)(
 input wire clk,rst_n,clk_en,
 input wire cmd_valid,output wire cmd_ready,input wire [TAG_W-1:0] cmd_tag,
 input wire [15:0] cfg_width,cfg_height,cfg_dst_width,cfg_dst_height,
 output wire rsp_valid,input wire rsp_ready,output reg [TAG_W-1:0] rsp_tag,
 output reg [1:0] rsp_error,
 input wire [DATA_W-1:0] s_data,input wire s_valid,s_sof,s_eol,output wire s_ready,
 output reg [DATA_W-1:0] m_data,output wire m_valid,m_sof,m_eol,m_last,input wire m_ready
);
localparam LANES=DATA_W/(PIXEL_W>0?PIXEL_W:1);
localparam SUPPORTED=PIXEL_W>=1 && PIXEL_W<=16 && DATA_W>=PIXEL_W && DATA_W<=32 && DATA_W==LANES*PIXEL_W && MAX_WIDTH>=1 && MAX_HEIGHT>=1 && MAX_WIDTH<=65535 && MAX_HEIGHT<=65535 && 64'd1*MAX_WIDTH*MAX_HEIGHT<=1048576;
localparam DEPTH=SUPPORTED?MAX_WIDTH*MAX_HEIGHT:1;
localparam IDLE=0,LOAD=1,COORD=2,ADDRESS=3,READ=4,ACCUM=5,PACK=6,OUTPUT=7,RESPONSE=8,DIV_X_START=9,DIV_X_WAIT=10,DIV_Y_START=11,DIV_Y_WAIT=12,MUL_Y=13,ADD_TAP=14,COEFF_X=15,COEFF_CAPTURE_X=16,COEFF_Y=17,COEFF_CAPTURE_Y=18;
localparam ADD_TAP_1=19,ADD_TAP_2=20,ADD_TAP_3=21;
reg [4:0] state;
reg [DATA_W-1:0] ram[0:DEPTH-1];
reg [DATA_W-1:0] rd;
localparam AW=(DEPTH<2)?1:$clog2(DEPTH),XW=(MAX_WIDTH<2)?1:$clog2(MAX_WIDTH+1),YW=(MAX_HEIGHT<2)?1:$clog2(MAX_HEIGHT+1);
reg [AW-1:0] address,load_index;
reg [XW-1:0] sw;reg [YW-1:0] sh;reg [15:0] dw,dh,ix,iy,ox,oy;
reg [23:0] qx,qy;
reg [3:0] tap;
reg signed [17:0] wx[0:3],wy[0:3];
reg signed [PIXEL_W+18:0] product_x[0:LANES-1];
reg signed [PIXEL_W+36:0] product_xy[0:LANES-1];
reg [39:0] div_n;reg [15:0] div_d;wire [39:0] div_q;wire div_done,div_error;
geo_serial_divider #(.W(40),.D(16)) coordinate_divider(.clk(clk),.rst_n(rst_n),.clk_en(clk_en),.start(state==DIV_X_START || state==DIV_Y_START),.numerator(div_n),.denominator({24'd0,div_d}),.done(div_done),.error(div_error),.quotient(div_q));
reg signed [63:0] sums[0:LANES-1];
reg [LANES-1:0] sum_carry;
reg [16:0] partial_sum;
reg signed [63:0] extended_product;
reg signed [63:0] rounded;
integer lane;reg signed [17:0] xx,yy;
function signed [17:0] weight;
 input [7:0] t;input integer k;
 reg signed [63:0] a,b,c,n0,n1,n2;
 begin
 a=t;b=a*a;c=b*a;
 n0=(-65536*a+512*b-c)>>>9;
 n1=65536+((-1280*b+3*c)>>>9);
 n2=(65536*a+1024*b-3*c)>>>9;
 case(k)0:weight=n0;1:weight=n1;2:weight=n2;default:weight=65536-n0-n1-n2;endcase
 end
endfunction
// Exact precomputed Q16 Catmull-Rom coefficients; one synchronous ROM port.
(* rom_style="block",ram_style="block",syn_ramstyle="block_ram" *) reg [71:0] coefficient_rom[0:255];
reg [71:0] coefficient_q;
initial begin
coefficient_rom[8'd0]=72'h000000000400000000;
coefficient_rom[8'd1]=72'h0000800813fff7ff80;
coefficient_rom[8'd2]=72'h0000001073ffdbff03;
coefficient_rom[8'd3]=72'hffff801913ffa7fe88;
coefficient_rom[8'd4]=72'hfffe8021f3ff63fe0f;
coefficient_rom[8'd5]=72'hfffd402b13ff0bfd98;
coefficient_rom[8'd6]=72'hfffc003463fe9ffd23;
coefficient_rom[8'd7]=72'hfffa803df3fe1ffcb0;
coefficient_rom[8'd8]=72'hfff84047d3fd8ffc3f;
coefficient_rom[8'd9]=72'hfff6c051d3fce7fbcf;
coefficient_rom[8'd10]=72'hfff4405c23fc2ffb62;
coefficient_rom[8'd11]=72'hfff1c066a3fb67faf6;
coefficient_rom[8'd12]=72'hffef407153fa8bfa8c;
coefficient_rom[8'd13]=72'hffec407c53f99bfa24;
coefficient_rom[8'd14]=72'hffe9408773f89bf9be;
coefficient_rom[8'd15]=72'hffe5c092e3f787f95a;
coefficient_rom[8'd16]=72'hffe2009e83f663f8f8;
coefficient_rom[8'd17]=72'hffde80aa53f52bf897;
coefficient_rom[8'd18]=72'hffdac0b653f3e3f838;
coefficient_rom[8'd19]=72'hffd6c0c293f287f7db;
coefficient_rom[8'd20]=72'hffd240cf13f11bf780;
coefficient_rom[8'd21]=72'hffce00dbb3ef9ff726;
coefficient_rom[8'd22]=72'hffc900e893ee13f6cf;
coefficient_rom[8'd23]=72'hffc440f5a3ec73f679;
coefficient_rom[8'd24]=72'hffbec102f3eac7f625;
coefficient_rom[8'd25]=72'hffb9c11063e907f5d2;
coefficient_rom[8'd26]=72'hffb4811e13e733f581;
coefficient_rom[8'd27]=72'hffaf012be3e553f532;
coefficient_rom[8'd28]=72'hffa90139f3e363f4e5;
coefficient_rom[8'd29]=72'hffa3014833e163f499;
coefficient_rom[8'd30]=72'hff9d015693df53f44f;
coefficient_rom[8'd31]=72'hff96c16533dd33f406;
coefficient_rom[8'd32]=72'hff90017403db03f3c0;
coefficient_rom[8'd33]=72'hff89c182f3d8c3f37a;
coefficient_rom[8'd34]=72'hff83019213d673f337;
coefficient_rom[8'd35]=72'hff7c41a163d413f2f5;
coefficient_rom[8'd36]=72'hff7541b0e3d1a7f2b4;
coefficient_rom[8'd37]=72'hff6dc1c093cf2bf276;
coefficient_rom[8'd38]=72'hff66c1d063cc9ff238;
coefficient_rom[8'd39]=72'hff5f01e063ca07f1fd;
coefficient_rom[8'd40]=72'hff5741f093c75ff1c3;
coefficient_rom[8'd41]=72'hff4fc200e3c4a7f18a;
coefficient_rom[8'd42]=72'hff48021153c1e3f153;
coefficient_rom[8'd43]=72'hff40022203bf0ff11d;
coefficient_rom[8'd44]=72'hff380232c3bc2ff0e9;
coefficient_rom[8'd45]=72'hff2f8243c3b93ff0b7;
coefficient_rom[8'd46]=72'hff278254d3b643f085;
coefficient_rom[8'd47]=72'hff1f026613b337f056;
coefficient_rom[8'd48]=72'hff16027783b023f028;
coefficient_rom[8'd49]=72'hff0dc28903acfbeffb;
coefficient_rom[8'd50]=72'hff05029ab3a9cbefcf;
coefficient_rom[8'd51]=72'hfefc42ac83a68befa5;
coefficient_rom[8'd52]=72'hfef302be83a33fef7d;
coefficient_rom[8'd53]=72'hfeea02d0939fe7ef56;
coefficient_rom[8'd54]=72'hfee0c2e2d39c83ef30;
coefficient_rom[8'd55]=72'hfed742f5339913ef0c;
coefficient_rom[8'd56]=72'hfecdc307b39597eee9;
coefficient_rom[8'd57]=72'hfec4c31a43920beec7;
coefficient_rom[8'd58]=72'hfebb432d038e77eea6;
coefficient_rom[8'd59]=72'hfeb1c33fe38ad3ee87;
coefficient_rom[8'd60]=72'hfea7c352e38727ee6a;
coefficient_rom[8'd61]=72'hfe9e036603836fee4d;
coefficient_rom[8'd62]=72'hfe944379337fabee32;
coefficient_rom[8'd63]=72'hfe8a838c837bdbee18;
coefficient_rom[8'd64]=72'hfe8003a0037803ee00;
coefficient_rom[8'd65]=72'hfe7683b383741bede8;
coefficient_rom[8'd66]=72'hfe6c43c733702bedd2;
coefficient_rom[8'd67]=72'hfe6243daf36c2fedbd;
coefficient_rom[8'd68]=72'hfe5803eed3682beda9;
coefficient_rom[8'd69]=72'hfe4d8402d3641bed97;
coefficient_rom[8'd70]=72'hfe434416e35fffed86;
coefficient_rom[8'd71]=72'hfe39442b035bdbed75;
coefficient_rom[8'd72]=72'hfe2e443f5357afed67;
coefficient_rom[8'd73]=72'hfe244453a35373ed59;
coefficient_rom[8'd74]=72'hfe19c468134f33ed4c;
coefficient_rom[8'd75]=72'hfe0f047ca34ae7ed41;
coefficient_rom[8'd76]=72'hfe04c491334693ed36;
coefficient_rom[8'd77]=72'hfdfa04a5f34233ed2d;
coefficient_rom[8'd78]=72'hfdef84bab33dcbed25;
coefficient_rom[8'd79]=72'hfde4c4cf93395bed1e;
coefficient_rom[8'd80]=72'hfdda04e48334e3ed18;
coefficient_rom[8'd81]=72'hfdcf84f983305fed13;
coefficient_rom[8'd82]=72'hfdc5050e932bd3ed0f;
coefficient_rom[8'd83]=72'hfdba8523b3273fed0c;
coefficient_rom[8'd84]=72'hfdafc538f322a3ed0a;
coefficient_rom[8'd85]=72'hfda5454e331dffed09;
coefficient_rom[8'd86]=72'hfd9a8563931953ed09;
coefficient_rom[8'd87]=72'hfd900578f3149fed0a;
coefficient_rom[8'd88]=72'hfd84c58e730fe7ed0d;
coefficient_rom[8'd89]=72'hfd7a45a3f30b23ed10;
coefficient_rom[8'd90]=72'hfd6fc5b9830657ed14;
coefficient_rom[8'd91]=72'hfd6545cf230183ed19;
coefficient_rom[8'd92]=72'hfd5a85e4d2fcabed1f;
coefficient_rom[8'd93]=72'hfd5045fa82f7cbed25;
coefficient_rom[8'd94]=72'hfd45861052f2e3ed2d;
coefficient_rom[8'd95]=72'hfd3ac62622edf7ed36;
coefficient_rom[8'd96]=72'hfd30063c02e903ed40;
coefficient_rom[8'd97]=72'hfd25c651e2e407ed4a;
coefficient_rom[8'd98]=72'hfd1b8667d2df03ed55;
coefficient_rom[8'd99]=72'hfd11467dc2d9fbed61;
coefficient_rom[8'd100]=72'hfd06c693c2d4efed6e;
coefficient_rom[8'd101]=72'hfcfc46a9d2cfdbed7c;
coefficient_rom[8'd102]=72'hfcf206bfd2cac3ed8b;
coefficient_rom[8'd103]=72'hfce7c6d5f2c5a3ed9a;
coefficient_rom[8'd104]=72'hfcdd46ec12c07fedab;
coefficient_rom[8'd105]=72'hfcd3470232bb53edbc;
coefficient_rom[8'd106]=72'hfcc9871852b623edcd;
coefficient_rom[8'd107]=72'hfcbf472e82b0efede0;
coefficient_rom[8'd108]=72'hfcb58744a2abb7edf3;
coefficient_rom[8'd109]=72'hfcabc75ad2a677ee07;
coefficient_rom[8'd110]=72'hfca1c77112a133ee1c;
coefficient_rom[8'd111]=72'hfc984787429bebee31;
coefficient_rom[8'd112]=72'hfc8e079d8296a3ee48;
coefficient_rom[8'd113]=72'hfc8507b3b2914fee5e;
coefficient_rom[8'd114]=72'hfc7b47c9f28bfbee76;
coefficient_rom[8'd115]=72'hfc7207e02286a3ee8e;
coefficient_rom[8'd116]=72'hfc6887f6628147eea7;
coefficient_rom[8'd117]=72'hfc5f880c927be7eec0;
coefficient_rom[8'd118]=72'hfc564822c27687eeda;
coefficient_rom[8'd119]=72'hfc4d083902711feef5;
coefficient_rom[8'd120]=72'hfc43c84f326bb7ef11;
coefficient_rom[8'd121]=72'hfc3b8865526647ef2c;
coefficient_rom[8'd122]=72'hfc32887b8260d7ef49;
coefficient_rom[8'd123]=72'hfc29c891a25b67ef66;
coefficient_rom[8'd124]=72'hfc2148a7c255efef84;
coefficient_rom[8'd125]=72'hfc1908bdd25077efa2;
coefficient_rom[8'd126]=72'hfc1088d3f24afbefc1;
coefficient_rom[8'd127]=72'hfc0888e9f2457fefe0;
coefficient_rom[8'd128]=72'hfc000900024003f000;
coefficient_rom[8'd129]=72'hfbf88915f23a7ff020;
coefficient_rom[8'd130]=72'hfbf0c92be234fff040;
coefficient_rom[8'd131]=72'hfbe90941d22f77f062;
coefficient_rom[8'd132]=72'hfbe18957b229f3f083;
coefficient_rom[8'd133]=72'hfbd9c96d92246bf0a6;
coefficient_rom[8'd134]=72'hfbd2c983521ee3f0c8;
coefficient_rom[8'd135]=72'hfbcbc999121957f0eb;
coefficient_rom[8'd136]=72'hfbc449aed213cff10f;
coefficient_rom[8'd137]=72'hfbbdc9c4720e43f132;
coefficient_rom[8'd138]=72'hfbb709da1208b3f157;
coefficient_rom[8'd139]=72'hfbb0c9ef920327f17b;
coefficient_rom[8'd140]=72'hfbaa4a0511fd9bf1a0;
coefficient_rom[8'd141]=72'hfba44a1a81f80bf1c5;
coefficient_rom[8'd142]=72'hfb9e0a2fe1f27ff1eb;
coefficient_rom[8'd143]=72'hfb984a4531eceff211;
coefficient_rom[8'd144]=72'hfb920a5a81e763f238;
coefficient_rom[8'd145]=72'hfb8d0a6fa1e1d3f25e;
coefficient_rom[8'd146]=72'hfb878a84c1dc47f285;
coefficient_rom[8'd147]=72'hfb828a99d1d6b7f2ac;
coefficient_rom[8'd148]=72'hfb7d4aaed1d12bf2d4;
coefficient_rom[8'd149]=72'hfb784ac3b1cba3f2fc;
coefficient_rom[8'd150]=72'hfb73cad881c617f324;
coefficient_rom[8'd151]=72'hfb6f4aed41c08ff34c;
coefficient_rom[8'd152]=72'hfb6acb01f1bb07f375;
coefficient_rom[8'd153]=72'hfb670b1681b57ff39d;
coefficient_rom[8'd154]=72'hfb634b2b01aff7f3c6;
coefficient_rom[8'd155]=72'hfb5f8b3f61aa77f3ef;
coefficient_rom[8'd156]=72'hfb5c0b53b1a4f3f419;
coefficient_rom[8'd157]=72'hfb590b67e19f73f442;
coefficient_rom[8'd158]=72'hfb55cb7c0199f7f46c;
coefficient_rom[8'd159]=72'hfb52cb9011947bf496;
coefficient_rom[8'd160]=72'hfb500ba4018f03f4c0;
coefficient_rom[8'd161]=72'hfb4dcbb7d1898bf4ea;
coefficient_rom[8'd162]=72'hfb4bcbcb818417f514;
coefficient_rom[8'd163]=72'hfb4a0bdf217ea3f53e;
coefficient_rom[8'd164]=72'hfb484bf2a17937f568;
coefficient_rom[8'd165]=72'hfb46cc060173cbf593;
coefficient_rom[8'd166]=72'hfb458c19516e63f5bd;
coefficient_rom[8'd167]=72'hfb444c2c8168fff5e8;
coefficient_rom[8'd168]=72'hfb434c3f91639ff613;
coefficient_rom[8'd169]=72'hfb434c52715e3ff63d;
coefficient_rom[8'd170]=72'hfb42cc654158e7f668;
coefficient_rom[8'd171]=72'hfb430c77f1538ff692;
coefficient_rom[8'd172]=72'hfb430c8a814e3ff6bd;
coefficient_rom[8'd173]=72'hfb438c9cf148eff6e8;
coefficient_rom[8'd174]=72'hfb444caf4143a7f712;
coefficient_rom[8'd175]=72'hfb450cc1713e63f73d;
coefficient_rom[8'd176]=72'hfb460cd3813923f768;
coefficient_rom[8'd177]=72'hfb47cce56133e7f792;
coefficient_rom[8'd178]=72'hfb49ccf7212eaff7bc;
coefficient_rom[8'd179]=72'hfb4b8d08c1297ff7e7;
coefficient_rom[8'd180]=72'hfb4e0d1a41244ff811;
coefficient_rom[8'd181]=72'hfb508d2b911f2bf83b;
coefficient_rom[8'd182]=72'hfb538d3cc11a07f865;
coefficient_rom[8'd183]=72'hfb56cd4dc114ebf88f;
coefficient_rom[8'd184]=72'hfb59cd5eb10fd7f8b9;
coefficient_rom[8'd185]=72'hfb5e0d6f610ac3f8e2;
coefficient_rom[8'd186]=72'hfb620d7ff105bbf90b;
coefficient_rom[8'd187]=72'hfb660d906100b7f935;
coefficient_rom[8'd188]=72'hfb6acda0a0fbb7f95e;
coefficient_rom[8'd189]=72'hfb700db0b0f6bff986;
coefficient_rom[8'd190]=72'hfb750dc0a0f1cff9af;
coefficient_rom[8'd191]=72'hfb7acdd060ece3f9d7;
coefficient_rom[8'd192]=72'hfb800de000e803fa00;
coefficient_rom[8'd193]=72'hfb86cdef60e323fa27;
coefficient_rom[8'd194]=72'hfb8d0dfea0de4ffa4f;
coefficient_rom[8'd195]=72'hfb93ce0db0d983fa76;
coefficient_rom[8'd196]=72'hfb9b0e1c90d4bbfa9d;
coefficient_rom[8'd197]=72'hfba28e2b40cffbfac4;
coefficient_rom[8'd198]=72'hfbaa0e39d0cb43faeb;
coefficient_rom[8'd199]=72'hfbb24e4820c693fb11;
coefficient_rom[8'd200]=72'hfbba4e5650c1effb37;
coefficient_rom[8'd201]=72'hfbc34e6440bd4ffb5c;
coefficient_rom[8'd202]=72'hfbcc8e7200b8b7fb81;
coefficient_rom[8'd203]=72'hfbd60e7f90b427fba6;
coefficient_rom[8'd204]=72'hfbdfce8cf0afa3fbca;
coefficient_rom[8'd205]=72'hfbea0e9a20ab23fbee;
coefficient_rom[8'd206]=72'hfbf44ea720a6affc12;
coefficient_rom[8'd207]=72'hfbff4eb3e0a243fc35;
coefficient_rom[8'd208]=72'hfc0a0ec0809de3fc58;
coefficient_rom[8'd209]=72'hfc160eccd09987fc7a;
coefficient_rom[8'd210]=72'hfc21ced9009537fc9c;
coefficient_rom[8'd211]=72'hfc2e0ee4f090f3fcbd;
coefficient_rom[8'd212]=72'hfc3acef0b08cb3fcde;
coefficient_rom[8'd213]=72'hfc47cefc308883fcfe;
coefficient_rom[8'd214]=72'hfc554f07808457fd1e;
coefficient_rom[8'd215]=72'hfc62cf1290803bfd3e;
coefficient_rom[8'd216]=72'hfc70cf1d707c27fd5d;
coefficient_rom[8'd217]=72'hfc7f8f2810781bfd7b;
coefficient_rom[8'd218]=72'hfc8e8f3270741bfd99;
coefficient_rom[8'd219]=72'hfc9dcf3ca07027fdb6;
coefficient_rom[8'd220]=72'hfcad8f46906c3bfdd3;
coefficient_rom[8'd221]=72'hfcbdcf5040685bfdef;
coefficient_rom[8'd222]=72'hfcce4f59c06487fe0a;
coefficient_rom[8'd223]=72'hfcdf0f630060bffe25;
coefficient_rom[8'd224]=72'hfcf00f6c005d03fe40;
coefficient_rom[8'd225]=72'hfd020f74c0594ffe59;
coefficient_rom[8'd226]=72'hfd144f7d4055a7fe72;
coefficient_rom[8'd227]=72'hfd268f8580520ffe8b;
coefficient_rom[8'd228]=72'hfd39cf8d804e7ffea2;
coefficient_rom[8'd229]=72'hfd4d4f95404afbfeb9;
coefficient_rom[8'd230]=72'hfd60cf9cc04787fed0;
coefficient_rom[8'd231]=72'hfd74cfa410441bfee6;
coefficient_rom[8'd232]=72'hfd894fab1040bffefb;
coefficient_rom[8'd233]=72'hfd9ecfb1c03d6bff0f;
coefficient_rom[8'd234]=72'hfdb44fb8403a27ff22;
coefficient_rom[8'd235]=72'hfdca4fbe7036efff35;
coefficient_rom[8'd236]=72'hfde08fc46033c7ff47;
coefficient_rom[8'd237]=72'hfdf78fca1030a7ff58;
coefficient_rom[8'd238]=72'hfe0e8fcf802d97ff69;
coefficient_rom[8'd239]=72'hfe260fd4a02a97ff79;
coefficient_rom[8'd240]=72'hfe3e0fd98027a3ff88;
coefficient_rom[8'd241]=72'hfe56cfde1024bbff96;
coefficient_rom[8'd242]=72'hfe700fe26021dfffa3;
coefficient_rom[8'd243]=72'hfe898fe6601f17ffaf;
coefficient_rom[8'd244]=72'hfea38fea201c57ffbb;
coefficient_rom[8'd245]=72'hfebdcfed9019abffc6;
coefficient_rom[8'd246]=72'hfed90ff0b0170bffcf;
coefficient_rom[8'd247]=72'hfef48ff3901477ffd8;
coefficient_rom[8'd248]=72'hff0fcff63011f7ffe1;
coefficient_rom[8'd249]=72'hff2c8ff8700f7fffe8;
coefficient_rom[8'd250]=72'hff494ffa700d1bffee;
coefficient_rom[8'd251]=72'hff668ffc200ac7fff3;
coefficient_rom[8'd252]=72'hff844ffd80087ffff8;
coefficient_rom[8'd253]=72'hffa2cffe900647fffb;
coefficient_rom[8'd254]=72'hffc14fff60041ffffe;
coefficient_rom[8'd255]=72'hffe0cfffd00207ffff;
end
wire [7:0] coefficient_address=(state==COEFF_Y)?qy[7:0]:qx[7:0];
always @(posedge clk)if(clk_en && (state==COEFF_X || state==COEFF_Y))
 coefficient_q<=coefficient_rom[coefficient_address];
`ifndef SYNTHESIS
integer phase,component;
initial begin
 for(phase=0;phase<256;phase=phase+1)
  for(component=0;component<4;component=component+1)
   if($signed(coefficient_rom[phase][component*18+:18])!==weight(phase,component))$fatal(1,"coefficient ROM mismatch");
end
`endif
assign cmd_ready=rst_n && state==IDLE;
assign rsp_valid=rst_n && state==RESPONSE;
assign s_ready=rst_n && state==LOAD;
assign m_valid=rst_n && state==OUTPUT;
assign m_sof=m_valid && ox==0 && oy==0;
assign m_eol=m_valid && ox==dw-1;
assign m_last=m_valid && ox==dw-1 && oy==dh-1;
// Both accesses are clocked and gated; coefficient/frame RAM has no asynchronous read.
always @(posedge clk)if(clk_en)begin
 if(state==LOAD && s_valid && s_ready)ram[load_index]<=s_data;
 if(state==READ)rd<=ram[address];
end
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
 state<=IDLE;div_n<=0;div_d<=1;rsp_tag<=0;rsp_error<=0;m_data<=0;sw<=0;sh<=0;dw<=0;dh<=0;ix<=0;iy<=0;ox<=0;oy<=0;load_index<=0;address<=0;qx<=0;qy<=0;tap<=0;
 for(lane=0;lane<LANES;lane=lane+1)sums[lane]<=0;
 for(lane=0;lane<4;lane=lane+1)begin wx[lane]<=0;wy[lane]<=0;end
 end else if(clk_en)case(state)
 IDLE:if(cmd_valid)begin
 rsp_tag<=cmd_tag;rsp_error<=0;
 if(!SUPPORTED || cfg_width==0 || cfg_height==0 || cfg_width>MAX_WIDTH || cfg_height>MAX_HEIGHT || cfg_dst_width==0 || cfg_dst_height==0)begin rsp_error<=2;state<=RESPONSE;end
 else begin sw<=cfg_width;sh<=cfg_height;dw<=cfg_dst_width;dh<=cfg_dst_height;ix<=0;iy<=0;ox<=0;oy<=0;load_index<=0;state<=LOAD;end
 end
 LOAD:if(s_valid)begin
 if(s_sof!=(ix==0 && iy==0) || s_eol!=(ix==sw-1))begin rsp_error<=2;state<=RESPONSE;end
 else if(ix==sw-1)begin ix<=0;iy<=iy+1;if(iy==sh-1)state<=COORD;end
 else ix<=ix+1;
 load_index<=load_index+1;
 end
 COORD:begin
 // 64-bit numerator prevents overflow for 16-bit destination positions.
 div_n<=40'd256*ox*sw;div_d<=dw;
 for(lane=0;lane<LANES;lane=lane+1)sums[lane]<=0;
 tap<=0;state<=DIV_X_START;
 end
 DIV_X_START:state<=DIV_X_WAIT;
 DIV_X_WAIT:if(div_done)begin
  if(div_error)begin rsp_error<=3;state<=RESPONSE;end
  else begin qx<=div_q;div_n<=40'd256*oy*sh;div_d<=dh;state<=DIV_Y_START;end
 end
 DIV_Y_START:state<=DIV_Y_WAIT;
 DIV_Y_WAIT:if(div_done)begin
  if(div_error)begin rsp_error<=3;state<=RESPONSE;end
  else begin qy<=div_q;state<=COEFF_X;end
 end
 COEFF_X:state<=COEFF_CAPTURE_X;
 COEFF_CAPTURE_X:begin
 for(lane=0;lane<4;lane=lane+1)wx[lane]<=coefficient_q[lane*18+:18];
 state<=COEFF_Y;
 end
 COEFF_Y:state<=COEFF_CAPTURE_Y;
 COEFF_CAPTURE_Y:begin
 for(lane=0;lane<4;lane=lane+1)wy[lane]<=coefficient_q[lane*18+:18];
 state<=ADDRESS;
 end
 ADDRESS:begin
 xx=$signed({1'b0,qx[23:8]})+$signed({1'b0,tap[1:0]})-1;
 yy=$signed({1'b0,qy[23:8]})+$signed({1'b0,tap[3:2]})-1;
 if(xx<0)xx=0;else if(xx>=sw)xx=sw-1;
 if(yy<0)yy=0;else if(yy>=sh)yy=sh-1;
 address<=yy*sw+xx;state<=READ;
 end
 READ:state<=ACCUM;
 ACCUM:begin
 for(lane=0;lane<LANES;lane=lane+1)product_x[lane]<=$signed({1'b0,rd[lane*PIXEL_W+:PIXEL_W]})*$signed(wx[tap[1:0]]);
 state<=MUL_Y;
 end
 MUL_Y:begin
 for(lane=0;lane<LANES;lane=lane+1)product_xy[lane]<=product_x[lane]*$signed(wy[tap[3:2]]);
 state<=ADD_TAP;
 end
 ADD_TAP:begin
 for(lane=0;lane<LANES;lane=lane+1)begin
 extended_product=product_xy[lane];
 partial_sum={1'b0,sums[lane][15:0]}+{1'b0,extended_product[15:0]};
 sums[lane][15:0]<=partial_sum[15:0];sum_carry[lane]<=partial_sum[16];
 end
 state<=ADD_TAP_1;
 end
 ADD_TAP_1:begin
 for(lane=0;lane<LANES;lane=lane+1)begin
 extended_product=product_xy[lane];
 partial_sum={1'b0,sums[lane][31:16]}+{1'b0,extended_product[31:16]}+sum_carry[lane];
 sums[lane][31:16]<=partial_sum[15:0];sum_carry[lane]<=partial_sum[16];
 end
 state<=ADD_TAP_2;
 end
 ADD_TAP_2:begin
 for(lane=0;lane<LANES;lane=lane+1)begin
 extended_product=product_xy[lane];
 partial_sum={1'b0,sums[lane][47:32]}+{1'b0,extended_product[47:32]}+sum_carry[lane];
 sums[lane][47:32]<=partial_sum[15:0];sum_carry[lane]<=partial_sum[16];
 end
 state<=ADD_TAP_3;
 end
 ADD_TAP_3:begin
 for(lane=0;lane<LANES;lane=lane+1)begin
 extended_product=product_xy[lane];
 partial_sum={1'b0,sums[lane][63:48]}+{1'b0,extended_product[63:48]}+sum_carry[lane];
 sums[lane][63:48]<=partial_sum[15:0];
 end
 if(tap==15)state<=PACK;else begin tap<=tap+1;state<=ADDRESS;end
 end
 PACK:begin
 for(lane=0;lane<LANES;lane=lane+1)begin
 rounded=(sums[lane]+64'sd2147483648)>>>32;
 if(rounded<0)m_data[lane*PIXEL_W+:PIXEL_W]<=0;
 else if(rounded>((64'd1<<PIXEL_W)-1))m_data[lane*PIXEL_W+:PIXEL_W]<={PIXEL_W{1'b1}};
 else m_data[lane*PIXEL_W+:PIXEL_W]<=rounded[PIXEL_W-1:0];
 end
 state<=OUTPUT;
 end
 OUTPUT:if(m_ready)begin
 if(ox==dw-1)begin ox<=0;if(oy==dh-1)state<=RESPONSE;else begin oy<=oy+1;state<=COORD;end end
 else begin ox<=ox+1;state<=COORD;end
 end
 RESPONSE:if(rsp_ready)state<=IDLE;
 default:begin state<=RESPONSE;rsp_error<=3;end
 endcase
end
endmodule
