// Radix-2 DIT complex FFT/IFFT. Ordinary ready/valid, synchronous high reset.
// LOG_N=1..10, DATA_W=2..24, TAG_W>=1. Coefficients are signed Q2.16.
module stream_fft #(
 parameter integer LOG_N=6, DATA_W=16, TAG_W=16
)(
 input wire clk,rst,
 input wire s_valid,output wire s_ready,
 input wire signed [DATA_W-1:0] s_re,s_im,
 input wire s_last,s_inverse,
 input wire [LOG_N-1:0] s_scale_mask,
 input wire [TAG_W-1:0] s_tag,
 output wire m_valid,input wire m_ready,
 output wire signed [DATA_W-1:0] m_re,m_im,
 output wire m_keep,m_last,m_error,m_overflow,m_inexact,
 output wire [LOG_N-1:0] m_index,m_scale_mask,
 output wire m_inverse,output wire [TAG_W-1:0] m_tag
);
 localparam integer N=1<<LOG_N;
 localparam integer BF_W=(LOG_N>1)?LOG_N-1:1;
 localparam integer ST_W=(LOG_N>1)?$clog2(LOG_N):1;
 localparam integer PW=DATA_W+18,AW=PW+1,SW=PW+2;
 localparam [BF_W-1:0] BF_LAST=N/2-1;
 localparam [LOG_N-1:0] LAST_INDEX=N-1;
 localparam [LOG_N:0] BLOCK_SIZE=N;
 localparam [ST_W-1:0] LAST_STAGE=LOG_N-1;
 localparam [3:0] LOAD=0,READ_A=1,READ_B=2,CAP_B=3,
  M0=4,M1=5,M2=6,M3=7,JOIN=8,SUM_A=9,QUANT_A=10,
  WRITE_A=11,SUM_B=12,QUANT_B=13,WRITE_B=14,OUTPUT=15;
 // The error marker reuses OUTPUT with no RAM requests.
 reg [3:0] state;
 reg [LOG_N-1:0] load_index;
 reg [BF_W-1:0] bf;
 reg [ST_W-1:0] stage;
 reg inverse,frame_error,overflow_flag,inexact_flag;
 reg [LOG_N-1:0] scale_mask;
 reg [TAG_W-1:0] frame_tag;
 reg [LOG_N:0] read_count;
 reg q_valid,out_valid;
 reg [LOG_N-1:0] q_index,out_index;
 reg signed [DATA_W-1:0] out_re,out_im;
 reg out_keep,out_last;
 assign s_ready=!rst&&(state==LOAD);
 assign m_valid=!rst&&out_valid;
 assign m_re=out_re;assign m_im=out_im;
 assign m_keep=out_keep;assign m_last=out_last;assign m_index=out_index;
 assign m_error=frame_error;assign m_overflow=overflow_flag;assign m_inexact=inexact_flag;
 assign m_tag=frame_tag;assign m_scale_mask=scale_mask;assign m_inverse=inverse;
 wire output_ready=!out_valid||m_ready;
 wire q_ready=!q_valid||output_ready;
 wire issue_read=(state==OUTPUT)&&!frame_error&&q_ready&&(read_count<BLOCK_SIZE);
 wire bad_length=s_last!=(load_index==LAST_INDEX);
 wire [LOG_N-1:0] bf_wide={{(LOG_N-BF_W){1'b0}},bf};
 wire [LOG_N-1:0] half={{(LOG_N-1){1'b0}},1'b1}<<stage;
 wire [LOG_N-1:0] position=bf_wide&(half-1'b1);
 wire [ST_W:0] stage_plus_one={1'b0,stage}+1'b1;
 wire [LOG_N-1:0] addr_a=((bf_wide>>stage)<<stage_plus_one)|position;
 wire [LOG_N-1:0] addr_b=addr_a|half;
 wire [LOG_N-1:0] twiddle_k=position<<(LOG_N-1-stage);
 wire [9:0] phase={{(10-LOG_N){1'b0}},twiddle_k}<<(10-LOG_N);
 wire [9:0] cos_fold=(phase>10'd256)?10'd512-phase:phase;
 wire [9:0] sin_fold=(phase>=10'd256)?phase-10'd256:10'd256-phase;
  function [16:0] quarter_cos;
  input [8:0] index;
  begin case(index)
   9'd0:quarter_cos=17'd65536;
   9'd1:quarter_cos=17'd65535;
   9'd2:quarter_cos=17'd65531;
   9'd3:quarter_cos=17'd65525;
   9'd4:quarter_cos=17'd65516;
   9'd5:quarter_cos=17'd65505;
   9'd6:quarter_cos=17'd65492;
   9'd7:quarter_cos=17'd65476;
   9'd8:quarter_cos=17'd65457;
   9'd9:quarter_cos=17'd65436;
   9'd10:quarter_cos=17'd65413;
   9'd11:quarter_cos=17'd65387;
   9'd12:quarter_cos=17'd65358;
   9'd13:quarter_cos=17'd65328;
   9'd14:quarter_cos=17'd65294;
   9'd15:quarter_cos=17'd65259;
   9'd16:quarter_cos=17'd65220;
   9'd17:quarter_cos=17'd65180;
   9'd18:quarter_cos=17'd65137;
   9'd19:quarter_cos=17'd65091;
   9'd20:quarter_cos=17'd65043;
   9'd21:quarter_cos=17'd64993;
   9'd22:quarter_cos=17'd64940;
   9'd23:quarter_cos=17'd64884;
   9'd24:quarter_cos=17'd64827;
   9'd25:quarter_cos=17'd64766;
   9'd26:quarter_cos=17'd64704;
   9'd27:quarter_cos=17'd64639;
   9'd28:quarter_cos=17'd64571;
   9'd29:quarter_cos=17'd64501;
   9'd30:quarter_cos=17'd64429;
   9'd31:quarter_cos=17'd64354;
   9'd32:quarter_cos=17'd64277;
   9'd33:quarter_cos=17'd64197;
   9'd34:quarter_cos=17'd64115;
   9'd35:quarter_cos=17'd64031;
   9'd36:quarter_cos=17'd63944;
   9'd37:quarter_cos=17'd63854;
   9'd38:quarter_cos=17'd63763;
   9'd39:quarter_cos=17'd63668;
   9'd40:quarter_cos=17'd63572;
   9'd41:quarter_cos=17'd63473;
   9'd42:quarter_cos=17'd63372;
   9'd43:quarter_cos=17'd63268;
   9'd44:quarter_cos=17'd63162;
   9'd45:quarter_cos=17'd63054;
   9'd46:quarter_cos=17'd62943;
   9'd47:quarter_cos=17'd62830;
   9'd48:quarter_cos=17'd62714;
   9'd49:quarter_cos=17'd62596;
   9'd50:quarter_cos=17'd62476;
   9'd51:quarter_cos=17'd62353;
   9'd52:quarter_cos=17'd62228;
   9'd53:quarter_cos=17'd62101;
   9'd54:quarter_cos=17'd61971;
   9'd55:quarter_cos=17'd61839;
   9'd56:quarter_cos=17'd61705;
   9'd57:quarter_cos=17'd61568;
   9'd58:quarter_cos=17'd61429;
   9'd59:quarter_cos=17'd61288;
   9'd60:quarter_cos=17'd61145;
   9'd61:quarter_cos=17'd60999;
   9'd62:quarter_cos=17'd60851;
   9'd63:quarter_cos=17'd60700;
   9'd64:quarter_cos=17'd60547;
   9'd65:quarter_cos=17'd60392;
   9'd66:quarter_cos=17'd60235;
   9'd67:quarter_cos=17'd60075;
   9'd68:quarter_cos=17'd59914;
   9'd69:quarter_cos=17'd59750;
   9'd70:quarter_cos=17'd59583;
   9'd71:quarter_cos=17'd59415;
   9'd72:quarter_cos=17'd59244;
   9'd73:quarter_cos=17'd59071;
   9'd74:quarter_cos=17'd58896;
   9'd75:quarter_cos=17'd58718;
   9'd76:quarter_cos=17'd58538;
   9'd77:quarter_cos=17'd58356;
   9'd78:quarter_cos=17'd58172;
   9'd79:quarter_cos=17'd57986;
   9'd80:quarter_cos=17'd57798;
   9'd81:quarter_cos=17'd57607;
   9'd82:quarter_cos=17'd57414;
   9'd83:quarter_cos=17'd57219;
   9'd84:quarter_cos=17'd57022;
   9'd85:quarter_cos=17'd56823;
   9'd86:quarter_cos=17'd56621;
   9'd87:quarter_cos=17'd56418;
   9'd88:quarter_cos=17'd56212;
   9'd89:quarter_cos=17'd56004;
   9'd90:quarter_cos=17'd55794;
   9'd91:quarter_cos=17'd55582;
   9'd92:quarter_cos=17'd55368;
   9'd93:quarter_cos=17'd55152;
   9'd94:quarter_cos=17'd54934;
   9'd95:quarter_cos=17'd54714;
   9'd96:quarter_cos=17'd54491;
   9'd97:quarter_cos=17'd54267;
   9'd98:quarter_cos=17'd54040;
   9'd99:quarter_cos=17'd53812;
   9'd100:quarter_cos=17'd53581;
   9'd101:quarter_cos=17'd53349;
   9'd102:quarter_cos=17'd53114;
   9'd103:quarter_cos=17'd52878;
   9'd104:quarter_cos=17'd52639;
   9'd105:quarter_cos=17'd52398;
   9'd106:quarter_cos=17'd52156;
   9'd107:quarter_cos=17'd51911;
   9'd108:quarter_cos=17'd51665;
   9'd109:quarter_cos=17'd51417;
   9'd110:quarter_cos=17'd51166;
   9'd111:quarter_cos=17'd50914;
   9'd112:quarter_cos=17'd50660;
   9'd113:quarter_cos=17'd50404;
   9'd114:quarter_cos=17'd50146;
   9'd115:quarter_cos=17'd49886;
   9'd116:quarter_cos=17'd49624;
   9'd117:quarter_cos=17'd49361;
   9'd118:quarter_cos=17'd49095;
   9'd119:quarter_cos=17'd48828;
   9'd120:quarter_cos=17'd48559;
   9'd121:quarter_cos=17'd48288;
   9'd122:quarter_cos=17'd48015;
   9'd123:quarter_cos=17'd47741;
   9'd124:quarter_cos=17'd47464;
   9'd125:quarter_cos=17'd47186;
   9'd126:quarter_cos=17'd46906;
   9'd127:quarter_cos=17'd46624;
   9'd128:quarter_cos=17'd46341;
   9'd129:quarter_cos=17'd46056;
   9'd130:quarter_cos=17'd45769;
   9'd131:quarter_cos=17'd45480;
   9'd132:quarter_cos=17'd45190;
   9'd133:quarter_cos=17'd44898;
   9'd134:quarter_cos=17'd44604;
   9'd135:quarter_cos=17'd44308;
   9'd136:quarter_cos=17'd44011;
   9'd137:quarter_cos=17'd43713;
   9'd138:quarter_cos=17'd43412;
   9'd139:quarter_cos=17'd43110;
   9'd140:quarter_cos=17'd42806;
   9'd141:quarter_cos=17'd42501;
   9'd142:quarter_cos=17'd42194;
   9'd143:quarter_cos=17'd41886;
   9'd144:quarter_cos=17'd41576;
   9'd145:quarter_cos=17'd41264;
   9'd146:quarter_cos=17'd40951;
   9'd147:quarter_cos=17'd40636;
   9'd148:quarter_cos=17'd40320;
   9'd149:quarter_cos=17'd40002;
   9'd150:quarter_cos=17'd39683;
   9'd151:quarter_cos=17'd39362;
   9'd152:quarter_cos=17'd39040;
   9'd153:quarter_cos=17'd38716;
   9'd154:quarter_cos=17'd38391;
   9'd155:quarter_cos=17'd38064;
   9'd156:quarter_cos=17'd37736;
   9'd157:quarter_cos=17'd37407;
   9'd158:quarter_cos=17'd37076;
   9'd159:quarter_cos=17'd36744;
   9'd160:quarter_cos=17'd36410;
   9'd161:quarter_cos=17'd36075;
   9'd162:quarter_cos=17'd35738;
   9'd163:quarter_cos=17'd35401;
   9'd164:quarter_cos=17'd35062;
   9'd165:quarter_cos=17'd34721;
   9'd166:quarter_cos=17'd34380;
   9'd167:quarter_cos=17'd34037;
   9'd168:quarter_cos=17'd33692;
   9'd169:quarter_cos=17'd33347;
   9'd170:quarter_cos=17'd33000;
   9'd171:quarter_cos=17'd32652;
   9'd172:quarter_cos=17'd32303;
   9'd173:quarter_cos=17'd31952;
   9'd174:quarter_cos=17'd31600;
   9'd175:quarter_cos=17'd31248;
   9'd176:quarter_cos=17'd30893;
   9'd177:quarter_cos=17'd30538;
   9'd178:quarter_cos=17'd30182;
   9'd179:quarter_cos=17'd29824;
   9'd180:quarter_cos=17'd29466;
   9'd181:quarter_cos=17'd29106;
   9'd182:quarter_cos=17'd28745;
   9'd183:quarter_cos=17'd28383;
   9'd184:quarter_cos=17'd28020;
   9'd185:quarter_cos=17'd27656;
   9'd186:quarter_cos=17'd27291;
   9'd187:quarter_cos=17'd26925;
   9'd188:quarter_cos=17'd26558;
   9'd189:quarter_cos=17'd26190;
   9'd190:quarter_cos=17'd25821;
   9'd191:quarter_cos=17'd25451;
   9'd192:quarter_cos=17'd25080;
   9'd193:quarter_cos=17'd24708;
   9'd194:quarter_cos=17'd24335;
   9'd195:quarter_cos=17'd23961;
   9'd196:quarter_cos=17'd23586;
   9'd197:quarter_cos=17'd23210;
   9'd198:quarter_cos=17'd22834;
   9'd199:quarter_cos=17'd22457;
   9'd200:quarter_cos=17'd22078;
   9'd201:quarter_cos=17'd21699;
   9'd202:quarter_cos=17'd21320;
   9'd203:quarter_cos=17'd20939;
   9'd204:quarter_cos=17'd20557;
   9'd205:quarter_cos=17'd20175;
   9'd206:quarter_cos=17'd19792;
   9'd207:quarter_cos=17'd19409;
   9'd208:quarter_cos=17'd19024;
   9'd209:quarter_cos=17'd18639;
   9'd210:quarter_cos=17'd18253;
   9'd211:quarter_cos=17'd17867;
   9'd212:quarter_cos=17'd17479;
   9'd213:quarter_cos=17'd17091;
   9'd214:quarter_cos=17'd16703;
   9'd215:quarter_cos=17'd16314;
   9'd216:quarter_cos=17'd15924;
   9'd217:quarter_cos=17'd15534;
   9'd218:quarter_cos=17'd15143;
   9'd219:quarter_cos=17'd14751;
   9'd220:quarter_cos=17'd14359;
   9'd221:quarter_cos=17'd13966;
   9'd222:quarter_cos=17'd13573;
   9'd223:quarter_cos=17'd13180;
   9'd224:quarter_cos=17'd12785;
   9'd225:quarter_cos=17'd12391;
   9'd226:quarter_cos=17'd11996;
   9'd227:quarter_cos=17'd11600;
   9'd228:quarter_cos=17'd11204;
   9'd229:quarter_cos=17'd10808;
   9'd230:quarter_cos=17'd10411;
   9'd231:quarter_cos=17'd10014;
   9'd232:quarter_cos=17'd9616;
   9'd233:quarter_cos=17'd9218;
   9'd234:quarter_cos=17'd8820;
   9'd235:quarter_cos=17'd8421;
   9'd236:quarter_cos=17'd8022;
   9'd237:quarter_cos=17'd7623;
   9'd238:quarter_cos=17'd7224;
   9'd239:quarter_cos=17'd6824;
   9'd240:quarter_cos=17'd6424;
   9'd241:quarter_cos=17'd6023;
   9'd242:quarter_cos=17'd5623;
   9'd243:quarter_cos=17'd5222;
   9'd244:quarter_cos=17'd4821;
   9'd245:quarter_cos=17'd4420;
   9'd246:quarter_cos=17'd4019;
   9'd247:quarter_cos=17'd3617;
   9'd248:quarter_cos=17'd3216;
   9'd249:quarter_cos=17'd2814;
   9'd250:quarter_cos=17'd2412;
   9'd251:quarter_cos=17'd2010;
   9'd252:quarter_cos=17'd1608;
   9'd253:quarter_cos=17'd1206;
   9'd254:quarter_cos=17'd804;
   9'd255:quarter_cos=17'd402;
   9'd256:quarter_cos=17'd0;
   default:quarter_cos=0;
  endcase end
 endfunction
 wire [16:0] cos_mag=quarter_cos(cos_fold[8:0]);
 wire [16:0] sin_mag=quarter_cos(sin_fold[8:0]);
 wire signed [17:0] next_wr=(phase>10'd256)?-$signed({1'b0,cos_mag}):$signed({1'b0,cos_mag});
 wire signed [17:0] next_wi=inverse?$signed({1'b0,sin_mag}):-$signed({1'b0,sin_mag});
 function [LOG_N-1:0] reverse_bits;
  input [LOG_N-1:0] value;integer i;
  begin for(i=0;i<LOG_N;i=i+1)reverse_bits[i]=value[LOG_N-1-i];end
 endfunction
 reg signed [DATA_W-1:0] ar,ai,br,bi;
 reg signed [17:0] wr,wi;
 wire signed [DATA_W-1:0] mul_a=((state==M1)||(state==M3))?bi:br;
 wire signed [17:0] mul_b=((state==M1)||(state==M2))?wi:wr;
 // Exactly one shared signed real multiplier before technology mapping.
 wire signed [PW-1:0] multiply=mul_a*mul_b;
 reg signed [PW-1:0] product;
 reg signed [AW-1:0] real_acc,imag_acc;
 wire signed [AW-1:0] product_ext={product[PW-1],product};
 wire [SW-1:0] a_re_scaled={{(SW-DATA_W-16){ar[DATA_W-1]}},ar,16'b0};
 wire [SW-1:0] a_im_scaled={{(SW-DATA_W-16){ai[DATA_W-1]}},ai,16'b0};
 wire [SW-1:0] tr={{(SW-AW){real_acc[AW-1]}},real_acc};
 wire [SW-1:0] ti={{(SW-AW){imag_acc[AW-1]}},imag_acc};
 wire subtract=(state==SUM_B);
 wire [SW-1:0] rhs_re=tr^{SW{subtract}},rhs_im=ti^{SW{subtract}};
 wire signed [SW-1:0] butterfly_re=a_re_scaled+rhs_re+{{(SW-1){1'b0}},subtract};
 wire signed [SW-1:0] butterfly_im=a_im_scaled+rhs_im+{{(SW-1){1'b0}},subtract};
 reg signed [SW-1:0] sum_re,sum_im;
 function [DATA_W+1:0] quantize;
  input signed [SW-1:0] value;input scale;
  reg signed [SW-1:0] floor_value;
  reg signed [SW:0] rounded,low_limit,high_limit;
  reg guard_bit,sticky,inc,ov,ix;
  reg [DATA_W-1:0] result;
  begin
   floor_value=scale?(value>>>17):(value>>>16);
   guard_bit=scale?value[16]:value[15];
   sticky=scale?(|value[15:0]):(|value[14:0]);
   inc=guard_bit&&(sticky||floor_value[0]);
   rounded=$signed({floor_value[SW-1],floor_value})+$signed({{SW{1'b0}},inc});
   low_limit=-($signed({{SW{1'b0}},1'b1})<<<(DATA_W-1));
   high_limit=-low_limit-1'b1;
   ov=(rounded<low_limit)||(rounded>high_limit);ix=guard_bit||sticky||ov;
   result=(rounded<low_limit)?low_limit[DATA_W-1:0]:(rounded>high_limit)?high_limit[DATA_W-1:0]:rounded[DATA_W-1:0];
   quantize={ix,ov,result};
  end
 endfunction
 wire [DATA_W+1:0] quant_re=quantize(sum_re,scale_mask[stage]);
 wire [DATA_W+1:0] quant_im=quantize(sum_im,scale_mask[stage]);
 reg [DATA_W-1:0] quant_re_reg,quant_im_reg;
 wire loading=(state==LOAD)&&s_valid;
 wire write_enable=(loading&&!bad_length)||(state==WRITE_A)||(state==WRITE_B);
 wire read_enable=(state==READ_A)||(state==READ_B)||issue_read;
 wire [LOG_N-1:0] write_addr=loading?reverse_bits(load_index):(state==WRITE_A)?addr_a:addr_b;
 wire [LOG_N-1:0] read_addr=issue_read?read_count[LOG_N-1:0]:(state==READ_A)?addr_a:addr_b;
 wire [2*DATA_W-1:0] write_word=loading?{s_re,s_im}:{quant_re_reg,quant_im_reg};
 reg [2*DATA_W-1:0] memory[0:N-1];
 reg [2*DATA_W-1:0] read_word;
 // No read/write collision and no reset on RAM. A complete block overwrites it.
 always @(posedge clk)if(!rst)begin
  if(write_enable)memory[write_addr]<=write_word;
  if(read_enable)read_word<=memory[read_addr];
 end
 always @(posedge clk)begin
  if(rst)begin
   state<=LOAD;load_index<=0;bf<=0;stage<=0;out_valid<=0;q_valid<=0;
   read_count<=0;frame_error<=0;overflow_flag<=0;inexact_flag<=0;
  end else begin
   case(state)
    LOAD:if(s_valid)begin
     if(load_index==0)begin
      frame_tag<=s_tag;inverse<=s_inverse;scale_mask<=s_scale_mask;
      overflow_flag<=0;inexact_flag<=0;frame_error<=0;
     end
     if(bad_length)begin
      frame_error<=1;overflow_flag<=0;inexact_flag<=0;
      out_valid<=1;out_keep<=0;out_last<=1;out_index<=0;out_re<=0;out_im<=0;
      q_valid<=0;read_count<=BLOCK_SIZE;state<=OUTPUT;
     end else if(load_index==LAST_INDEX)begin bf<=0;stage<=0;state<=READ_A;end
     else load_index<=load_index+1'b1;
    end
    READ_A:state<=READ_B;
    READ_B:begin ar<=read_word[2*DATA_W-1:DATA_W];ai<=read_word[DATA_W-1:0];state<=CAP_B;end
    CAP_B:begin
     br<=read_word[2*DATA_W-1:DATA_W];bi<=read_word[DATA_W-1:0];
     wr<=next_wr;wi<=next_wi;state<=M0;
    end
    M0:begin product<=multiply;state<=M1;end
    M1:begin product<=multiply;real_acc<=product_ext;state<=M2;end
    M2:begin product<=multiply;real_acc<=real_acc-product_ext;state<=M3;end
    M3:begin product<=multiply;imag_acc<=product_ext;state<=JOIN;end
    JOIN:begin imag_acc<=imag_acc+product_ext;state<=SUM_A;end
    SUM_A:begin sum_re<=butterfly_re;sum_im<=butterfly_im;state<=QUANT_A;end
    QUANT_A,QUANT_B:begin
     quant_re_reg<=quant_re[DATA_W-1:0];quant_im_reg<=quant_im[DATA_W-1:0];
     overflow_flag<=overflow_flag||quant_re[DATA_W]||quant_im[DATA_W];
     inexact_flag<=inexact_flag||quant_re[DATA_W+1]||quant_im[DATA_W+1];
     state<=(state==QUANT_A)?WRITE_A:WRITE_B;
    end
    WRITE_A:state<=SUM_B;
    SUM_B:begin sum_re<=butterfly_re;sum_im<=butterfly_im;state<=QUANT_B;end
    WRITE_B:begin
     if(bf==BF_LAST)begin
      bf<=0;
      if(stage==LAST_STAGE)begin state<=OUTPUT;read_count<=0;q_valid<=0;out_valid<=0;end
      else begin stage<=stage+1'b1;state<=READ_A;end
     end else begin bf<=bf+1'b1;state<=READ_A;end
    end
    OUTPUT:begin
     if(output_ready)begin
      out_valid<=q_valid;
      if(q_valid)begin
       out_re<=read_word[2*DATA_W-1:DATA_W];out_im<=read_word[DATA_W-1:0];
       out_keep<=1;out_index<=q_index;out_last<=(q_index==LAST_INDEX);
      end
     end
     if(q_ready)begin q_valid<=issue_read;if(issue_read)q_index<=read_count[LOG_N-1:0];end
     if(issue_read)read_count<=read_count+1'b1;
     if(out_valid&&m_ready&&out_last)begin state<=LOAD;load_index<=0;out_valid<=0;q_valid<=0;end
    end
   endcase
  end
 end
endmodule
