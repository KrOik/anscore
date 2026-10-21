// Baseline sequential 8-bit three-component YCbCr JPEG decoder. No third-party RTL.
// Whole-file capture, canonical Huffman entropy, wide separable serial IDCT.
module jpeg_color_decoder #(
 parameter integer MAX_SIDE=32, MAX_BYTES=8192,
 parameter COEFF_FILE="cores/system/common_scaffold/image/jpeg_color_decoder/idct_coeff.hex"
)(input wire clk,rst_n,ce,input wire start_valid,output wire start_ready,
 input wire abort,input wire [7:0] s_data,input wire s_valid,s_last,output wire s_ready,
 output wire [23:0] m_data,output wire m_valid,m_sof,m_eol,m_last,input wire m_ready,
 output reg [15:0] width,height,output wire done_valid,input wire done_ready,
 output reg done_error,output reg [7:0] error_code,output wire busy);
 localparam integer AW=$clog2(MAX_BYTES+1), FW=$clog2(MAX_SIDE*MAX_SIDE+1);
 localparam IDLE=0,CAP=1,FETCH=2,FETCHED=3,SOI0=4,SOI1=5,MARK0=6,MARK1=7,
 LEN0=8,LEN1=9,SEG=10,TABLE_CLEAR=11,ENT_START=12,BIT=13,ENT_BYTE=14,ENT_FF=15,
 HUFF=16,SYM_WAIT=17,SYM=18,AMPL=19,COEF_WRITE=20,BLOCK_CLEAR=21,
 TRANS_PREP=22,TRANS_READ=23,TRANS_MUL=24,TRANS_ACC=25,TRANS_SAVE=26,
 EMIT_BLOCK=27,EOI0=28,EOI1=29,OUT_ADDR=30,OUT_DATA=31,OUT_HOLD=32,DONE=33,OUT_TAP=34;
 reg [5:0] state,ret_state,bit_ret;
 reg [7:0] bytes[0:MAX_BYTES-1];reg [7:0] plane_y[0:MAX_SIDE*MAX_SIDE-1],plane_cb[0:MAX_SIDE*MAX_SIDE-1],plane_cr[0:MAX_SIDE*MAX_SIDE-1];
 reg [7:0] quant[0:255]; reg [7:0] hsym[0:2047];reg [7:0] hcount[0:127];
 reg signed[23:0] coef[0:63],middle[0:63];reg signed[27:0] matrix[0:63];
 initial $readmemh(COEFF_FILE,matrix);
 reg[AW-1:0] captured,pos;reg[7:0] byte_q,marker;reg[15:0] seglen,segidx;
 reg[7:0] temp_hi,component;reg[1:0] qid,dcid,acid;
 reg fail_flag,adobe_possible;reg[1:0] component_qid[0:2],component_dc[0:2],component_ac[0:2];reg hsub,vsub;reg[15:0] chroma_width,chroma_height,mcu_x,mcu_y;reg[1:0] comp_idx,block_idx;reg[15:0] out_x,out_y;reg[3:0] qvalid;reg[7:0] hvalid;reg seen_sof,seen_sos;
 reg[3:0] table_id;reg table_ac;reg[8:0] table_n,table_total,table_idx;
 reg[4:0] table_len;reg[16:0] slots;
 reg[7:0] bitbuf;reg[3:0] bits_left;reg bit_value;
 reg[15:0] hcode,hfirst;reg[8:0] hbase;reg[4:0] hlen;reg decoding_ac;
 reg[10:0] sym_addr;reg[7:0] sym_q,symbol;
 reg[3:0] amplitude_left;reg[15:0] amplitude;
 reg signed[15:0] predictors[0:2];wire signed[15:0] predictor=predictors[comp_idx];reg signed[15:0] decoded;
 reg[6:0] k,clear_i;reg[5:0] natural;reg[7:0] quant_q;
 reg[15:0] bx,by;reg phase;reg[2:0] tx,ty,tu;
 reg signed[23:0] sample;reg signed[27:0] factor;
 reg[55:0] mul_shift,mul_sum;reg[27:0] mul_bits;reg mul_neg;reg[4:0] mul_step;
 reg signed[55:0] accumulator,product;reg signed[55:0] rounded;
 reg[5:0] emit_i;reg[FW-1:0] out_pos;reg[23:0] out_data;reg[7:0] yq,cbtap[0:3],crtap[0:3];reg[1:0] tap;

 wire[15:0] cx=out_x>>hsub,cy=out_y>>vsub;
 wire[15:0] nx=hsub?((!out_x[0])?((cx==0)?16'd0:cx-16'd1):((cx+1>=chroma_width)?cx:cx+16'd1)):cx;
 wire[15:0] ny=vsub?((!out_y[0])?((cy==0)?16'd0:cy-16'd1):((cy+1>=chroma_height)?cy:cy+16'd1)):cy;
 wire[31:0] tap_addr=(tap[1]?ny:cy)*chroma_width+(tap[0]?nx:cx);
 wire fancy=chroma_width>2;
 wire[3:0] wx=(hsub&&fancy)?4'd3:4'd4,wy=(vsub&&fancy)?4'd3:4'd4;
 wire[3:0] ux=(hsub&&fancy)?4'd1:4'd0,uy=(vsub&&fancy)?4'd1:4'd0;
 wire[15:0] cb_sum=cbtap[0]*wx*wy+cbtap[1]*ux*wy+cbtap[2]*wx*uy+cbtap[3]*ux*uy;
 wire[15:0] cr_sum=crtap[0]*wx*wy+crtap[1]*ux*wy+crtap[2]*wx*uy+crtap[3]*ux*uy;
 wire signed[9:0] cb_center=$signed({1'b0,((cb_sum+16'd8)>>4)})-10'sd128;
 wire signed[9:0] cr_center=$signed({1'b0,((cr_sum+16'd8)>>4)})-10'sd128;
 wire signed[31:0] red=$signed({1'b0,yq})+((cr_center*32'sd91881+32'sd32768)>>>16);
 wire signed[31:0] green=$signed({1'b0,yq})+((-cb_center*32'sd22554-cr_center*32'sd46802+32'sd32768)>>>16);
 wire signed[31:0] blue=$signed({1'b0,yq})+((cb_center*32'sd116130+32'sd32768)>>>16);
 function[7:0] clip8;input signed[31:0] a;begin clip8=(a<0)?0:(a>255)?255:a[7:0];end endfunction
 wire [3:0] selected_table={1'b0,(decoding_ac?acid:dcid)}+(decoding_ac?4'd4:4'd0);
 wire [6:0] count_addr={selected_table[2:0],4'b0}+hlen-1;
 wire [7:0] this_count=hcount[count_addr];
 assign start_ready=rst_n&&ce&&!abort&&state==IDLE;
 assign s_ready=rst_n&&ce&&!abort&&state==CAP;
 assign busy=state!=IDLE&&state!=DONE;
 assign done_valid=state==DONE;
 assign m_valid=state==OUT_HOLD&&!abort;
 assign m_data=out_data;assign m_sof=out_pos==0;
 assign m_eol=out_x==width-1;assign m_last=out_pos==width*height-1;
 function[5:0] zig;input[5:0] z;begin case(z)
 0:zig=0;1:zig=1;2:zig=8;3:zig=16;4:zig=9;5:zig=2;6:zig=3;7:zig=10;
 8:zig=17;9:zig=24;10:zig=32;11:zig=25;12:zig=18;13:zig=11;14:zig=4;15:zig=5;
 16:zig=12;17:zig=19;18:zig=26;19:zig=33;20:zig=40;21:zig=48;22:zig=41;23:zig=34;
 24:zig=27;25:zig=20;26:zig=13;27:zig=6;28:zig=7;29:zig=14;30:zig=21;31:zig=28;
 32:zig=35;33:zig=42;34:zig=49;35:zig=56;36:zig=57;37:zig=50;38:zig=43;39:zig=36;
 40:zig=29;41:zig=22;42:zig=15;43:zig=23;44:zig=30;45:zig=37;46:zig=44;47:zig=51;
 48:zig=58;49:zig=59;50:zig=52;51:zig=45;52:zig=38;53:zig=31;54:zig=39;55:zig=46;
 56:zig=53;57:zig=60;58:zig=61;59:zig=54;60:zig=47;61:zig=55;62:zig=62;default:zig=63;
 endcase end endfunction
 task fail;input[7:0] code;begin fail_flag=1;done_error<=1;error_code<=code;state<=DONE;end endtask
 task getbyte;input[5:0] target;begin ret_state<=target;state<=FETCH;end endtask
 task getbit;input[5:0] target;begin bit_ret<=target;state<=BIT;end endtask
 task begin_huff;input ac;begin decoding_ac<=ac;hlen<=1;hcode<=0;hfirst<=0;hbase<=0;getbit(HUFF);end endtask
 always @(posedge clk)begin
 if(!rst_n)begin state<=IDLE;done_error<=0;error_code<=0;width<=0;height<=0;out_pos<=0;end
 else if(ce)begin
 fail_flag=0;
 if(abort&&state!=IDLE&&state!=DONE)fail(8'h93);
 else case(state)
 IDLE:if(start_valid&&!abort)begin
 state<=TABLE_CLEAR;clear_i<=0;done_error<=0;error_code<=0;captured<=0;pos<=0;
 qvalid<=0;hvalid<=0;seen_sof<=0;seen_sos<=0;width<=0;height<=0;out_pos<=0;
 end
 TABLE_CLEAR:begin hcount[clear_i]<=0;if(clear_i==127)begin
 if(MAX_SIDE<1||MAX_SIDE>256||MAX_BYTES<64)fail(8'h80);else state<=CAP;
 end else clear_i<=clear_i+1;end
 CAP:if(s_valid)begin
 bytes[captured]<=s_data;
 if(s_last)begin captured<=captured+1;pos<=0;getbyte(SOI0);end
 else if(captured==MAX_BYTES-1)fail(8'h81);else captured<=captured+1;
 end
 FETCH:if(pos>=captured)fail(8'h82);else begin byte_q<=bytes[pos];pos<=pos+1;state<=FETCHED;end
 FETCHED:state<=ret_state;
 SOI0:if(byte_q!=8'hff)fail(8'h83);else getbyte(SOI1);
 SOI1:if(byte_q!=8'hd8)fail(8'h83);else getbyte(MARK0);
 MARK0:if(byte_q!=8'hff)fail(8'h84);else getbyte(MARK1);
 MARK1:if(byte_q==8'hff)getbyte(MARK1);else if(byte_q==8'hdb||byte_q==8'hc4||byte_q==8'hc0||byte_q==8'hda||byte_q==8'hdd||byte_q==8'hfe||(byte_q>=8'he0&&byte_q<=8'hef))begin marker<=byte_q;getbyte(LEN0);end else fail(8'h85);
 LEN0:begin temp_hi<=byte_q;getbyte(LEN1);end
 LEN1:begin seglen<={temp_hi,byte_q}-2;segidx<=0;table_idx<=0;adobe_possible<=marker==8'hee;
 if({temp_hi,byte_q}<2)fail(8'h86);
 else if(marker==8'hdd&&{temp_hi,byte_q}!=4)fail(8'h86);
 else if(marker==8'hdb&&{temp_hi,byte_q}<67)fail(8'h89);
 else if(marker==8'hc4&&{temp_hi,byte_q}<20)fail(8'h8a);
 else if(marker==8'hc0&&({temp_hi,byte_q}!=17||seen_sof))fail(8'h87);
 else if(marker==8'hda&&({temp_hi,byte_q}!=12||!seen_sof||seen_sos))fail(8'h88);
 else if({temp_hi,byte_q}==2)getbyte(MARK0);else getbyte(SEG);end
 SEG:begin
 // Each segment is bounded by its declared byte count; tables may repeat.
 if(marker==8'hdd)begin if(byte_q!=0)fail(8'h85);end
 else if(marker==8'hee)begin
 case(segidx)
 0:if(byte_q!=8'h41)adobe_possible<=0;
 1:if(byte_q!=8'h64)adobe_possible<=0;
 2:if(byte_q!=8'h6f)adobe_possible<=0;
 3:if(byte_q!=8'h62)adobe_possible<=0;
 4:if(byte_q!=8'h65)adobe_possible<=0;
 11:if(adobe_possible&&byte_q!=1)fail(8'h85);
 endcase
 end else if(marker==8'hdb)begin
 if(table_idx==0)begin
 if(byte_q[7:4]!=0||byte_q[3:0]>3||seglen-segidx<65)fail(8'h89);
 else begin qid<=byte_q[1:0];table_idx<=1;qvalid[byte_q[1:0]]<=0;end
 end else begin
 if(byte_q==0)fail(8'h89);else begin quant[{qid,6'b0}+table_idx-1]<=byte_q;
 if(table_idx==64)begin qvalid[qid]<=1;table_idx<=0;end else table_idx<=table_idx+1;end end
 end else if(marker==8'hc4)begin
 if(table_idx==0)begin
 if(byte_q[7:5]!=0||byte_q[3:0]>3||seglen-segidx<17)fail(8'h8a);
 else begin table_ac<=byte_q[4];table_id<=byte_q[3:0]+(byte_q[4]?4:0);table_idx<=1;table_total<=0;slots<=1;hvalid[byte_q[3:0]+(byte_q[4]?4:0)]<=0;end
 end else if(table_idx<=16)begin
 hcount[{table_id[2:0],4'b0}+table_idx-1]<=byte_q;
 table_total<=table_total+byte_q;slots<=slots*2-byte_q;
 if(byte_q>=slots*2||table_total+byte_q>256)fail(8'h8a);
 else if(table_idx==16)begin
 if(table_total+byte_q==0||seglen-segidx-1<table_total+byte_q)fail(8'h8a);
 else begin table_idx<=17;table_n<=0;end
 end else table_idx<=table_idx+1;
 end else begin
 hsym[{table_id[2:0],8'b0}+table_n]<=byte_q;
 if(table_n+1==table_total)begin hvalid[table_id]<=1;table_idx<=0;end else table_n<=table_n+1;
 end
 end else if(marker==8'hc0)begin
 case(segidx)
 0:if(byte_q!=8)fail(8'h87);
 1:temp_hi<=byte_q;
 2:begin height<={temp_hi,byte_q};if({temp_hi,byte_q}==0||{temp_hi,byte_q}>MAX_SIDE)fail(8'h87);end
 3:temp_hi<=byte_q;
 4:begin width<={temp_hi,byte_q};if({temp_hi,byte_q}==0||{temp_hi,byte_q}>MAX_SIDE)fail(8'h87);end
 5:if(byte_q!=3)fail(8'h87);
 6:if(byte_q!=1)fail(8'h87);
 7:begin if(byte_q!=8'h11&&byte_q!=8'h21&&byte_q!=8'h22)fail(8'h87);hsub<=byte_q[5];vsub<=byte_q[1];end
 8:begin component_qid[0]<=byte_q[1:0];if(byte_q>3)fail(8'h87);end
 9:if(byte_q!=2)fail(8'h87);
 10:if(byte_q!=8'h11)fail(8'h87);
 11:begin component_qid[1]<=byte_q[1:0];if(byte_q>3)fail(8'h87);end
 12:if(byte_q!=3)fail(8'h87);
 13:if(byte_q!=8'h11)fail(8'h87);
 14:begin component_qid[2]<=byte_q[1:0];seen_sof<=1;if(byte_q>3)fail(8'h87);end
 endcase
 end else if(marker==8'hda)begin
 case(segidx)
 0:if(byte_q!=3)fail(8'h88);
 1:if(byte_q!=1)fail(8'h88);
 2:begin component_dc[0]<=byte_q[5:4];component_ac[0]<=byte_q[1:0];if(byte_q[7:4]>3||byte_q[3:0]>3)fail(8'h88);end
 3:if(byte_q!=2)fail(8'h88);
 4:begin component_dc[1]<=byte_q[5:4];component_ac[1]<=byte_q[1:0];if(byte_q[7:4]>3||byte_q[3:0]>3)fail(8'h88);end
 5:if(byte_q!=3)fail(8'h88);
 6:begin component_dc[2]<=byte_q[5:4];component_ac[2]<=byte_q[1:0];if(byte_q[7:4]>3||byte_q[3:0]>3)fail(8'h88);end
 7:if(byte_q!=0)fail(8'h88);
 8:if(byte_q!=63)fail(8'h88);
 9:if(byte_q!=0)fail(8'h88);
 endcase
 end
 // Error assignments above take precedence over next-state only via explicit guard.
 segidx<=segidx+1;
 if(segidx+1<seglen)begin ret_state<=SEG;state<=FETCH;end
 else if(marker==8'hee&&adobe_possible&&segidx>=4&&seglen<12)fail(8'h86);
 else if(marker==8'hdb&&table_idx!=64)fail(8'h89);
 else if(marker==8'hc4&&(table_idx<17||table_n+1!=table_total))fail(8'h8a);
 else if(marker==8'hda)begin seen_sos<=1;state<=ENT_START;end
 else begin ret_state<=MARK0;state<=FETCH;end
 end
 ENT_START:begin
 if(!qvalid[component_qid[0]]||!qvalid[component_qid[1]]||!qvalid[component_qid[2]]||
 !hvalid[component_dc[0]]||!hvalid[component_dc[1]]||!hvalid[component_dc[2]]||
 !hvalid[component_ac[0]+4]||!hvalid[component_ac[1]+4]||!hvalid[component_ac[2]+4])fail(8'h8b);
 else begin bits_left<=0;predictors[0]<=0;predictors[1]<=0;predictors[2]<=0;
 bx<=0;by<=0;mcu_x<=0;mcu_y<=0;comp_idx<=0;block_idx<=0;
 chroma_width<=(width+hsub)>>hsub;chroma_height<=(height+vsub)>>vsub;
 qid<=component_qid[0];dcid<=component_dc[0];acid<=component_ac[0];
 clear_i<=0;state<=BLOCK_CLEAR;end end
 BLOCK_CLEAR:begin coef[clear_i]<=0;if(clear_i==63)begin k<=0;begin_huff(0);end else clear_i<=clear_i+1;end
 BIT:if(bits_left!=0)begin bit_value<=bitbuf[7];bitbuf<={bitbuf[6:0],1'b0};bits_left<=bits_left-1;state<=bit_ret;end else getbyte(ENT_BYTE);
 ENT_BYTE:if(byte_q==8'hff)getbyte(ENT_FF);else begin bitbuf<=byte_q;bits_left<=8;state<=BIT;end
 ENT_FF:if(byte_q!=0)fail(8'h8c);else begin bitbuf<=8'hff;bits_left<=8;state<=BIT;end
 HUFF:begin
 if(({1'b0,hcode}*2+bit_value)>={1'b0,hfirst}&&({1'b0,hcode}*2+bit_value)<{1'b0,hfirst}+this_count)begin
 sym_addr<={selected_table[2:0],8'b0}+hbase+(hcode*2+bit_value-hfirst);state<=SYM_WAIT;
 end else if(hlen==16)fail(8'h8d);
 else begin hcode<=hcode*2+bit_value;hfirst<=(hfirst+this_count)*2;hbase<=hbase+this_count;hlen<=hlen+1;getbit(HUFF);end end
 SYM_WAIT:begin sym_q<=hsym[sym_addr];state<=SYM;end
 SYM:begin symbol<=sym_q;amplitude<=0;
 if(!decoding_ac)begin
 if(sym_q>11)fail(8'h8e);else if(sym_q==0)begin decoded<=predictor;state<=COEF_WRITE;end
 else begin amplitude_left<=sym_q;getbit(AMPL);end
 end else if(sym_q==0)begin tx<=0;ty<=0;tu<=0;phase<=0;accumulator<=0;state<=TRANS_PREP;end
 else if(sym_q==8'hf0)begin if(k+16>64)fail(8'h8f);else if(k+16==64)begin tx<=0;ty<=0;tu<=0;phase<=0;accumulator<=0;state<=TRANS_PREP;end else begin k<=k+16;begin_huff(1);end end
 else if(sym_q[3:0]==0||sym_q[3:0]>10||k+sym_q[7:4]>=64)fail(8'h8f);
 else begin k<=k+sym_q[7:4];amplitude_left<=sym_q[3:0];getbit(AMPL);end
 end
 AMPL:begin
 amplitude<=(amplitude<<1)|bit_value;
 if(amplitude_left==1)begin
 if(((amplitude<<1)|bit_value)<(16'd1<<(symbol[3:0]-1)))begin
 if(!decoding_ac)decoded<=predictor+$signed(((amplitude<<1)|bit_value)-(16'd1<<symbol[3:0])+1);
 else decoded<=$signed(((amplitude<<1)|bit_value)-(16'd1<<symbol[3:0])+1);
 end else begin if(!decoding_ac)decoded<=predictor+$signed((amplitude<<1)|bit_value);else decoded<=$signed((amplitude<<1)|bit_value);end
 state<=COEF_WRITE;
 end else begin amplitude_left<=amplitude_left-1;getbit(AMPL);end end
 COEF_WRITE:begin
 // Quant table is in JPEG zigzag order, coefficient storage is natural order.
 if(!decoding_ac&&(decoded< -2048||decoded>2047))fail(8'h90);
 else begin coef[zig(k[5:0])]<=$signed(decoded)*$signed({1'b0,quant[{qid,6'b0}+k]});
 if(!decoding_ac)predictors[comp_idx]<=decoded;
 if(k==63)begin tx<=0;ty<=0;tu<=0;phase<=0;accumulator<=0;state<=TRANS_PREP;end
 else begin k<=k+1;begin_huff(1);end end end
 TRANS_PREP:begin
 if(!phase)sample<=coef[{ty,tu}];else sample<=middle[{tu,tx}];
 if(!phase)factor<=matrix[{tx,tu}];else factor<=matrix[{ty,tu}];state<=TRANS_READ;end
 TRANS_READ:begin
 mul_shift<=sample[23]?-$signed(sample):sample;mul_bits<=factor[27]?-$signed(factor):factor;
 mul_neg<=sample[23]^factor[27];mul_sum<=0;mul_step<=0;state<=TRANS_MUL;end
 TRANS_MUL:begin
 if(mul_bits[0])mul_sum<=mul_sum+mul_shift;
 mul_shift<=mul_shift<<1;mul_bits<=mul_bits>>1;
 if(mul_step==27)begin
 if(mul_neg)product<=-$signed({1'b0,mul_sum+(mul_bits[0]?mul_shift:56'd0)});
 else product<=$signed({1'b0,mul_sum+(mul_bits[0]?mul_shift:56'd0)});
 state<=TRANS_ACC;end else mul_step<=mul_step+1;end
 TRANS_ACC:begin accumulator<=accumulator+product;
 if(tu==7)state<=TRANS_SAVE;else begin tu<=tu+1;state<=TRANS_PREP;end end
 TRANS_SAVE:begin
 if(!phase)middle[{ty,tx}]<=(accumulator+33554432)>>>26;
 else begin
 if(((accumulator+33554432)>>>26)+128<0)coef[{ty,tx}]<=0;
 else if(((accumulator+33554432)>>>26)+128>255)coef[{ty,tx}]<=255;
 else coef[{ty,tx}]<=((accumulator+33554432)>>>26)+128;
 end
 accumulator<=0;tu<=0;
 if(tx==7)begin tx<=0;if(ty==7)begin ty<=0;if(!phase)begin phase<=1;state<=TRANS_PREP;end else begin emit_i<=0;state<=EMIT_BLOCK;end end
 else begin ty<=ty+1;state<=TRANS_PREP;end end else begin tx<=tx+1;state<=TRANS_PREP;end end
 EMIT_BLOCK:begin
 if(comp_idx==0)begin
 if(bx+emit_i[2:0]<width&&by+emit_i[5:3]<height)plane_y[(by+emit_i[5:3])*width+bx+emit_i[2:0]]<=coef[emit_i][7:0];
 end else if(bx+emit_i[2:0]<chroma_width&&by+emit_i[5:3]<chroma_height)begin
 if(comp_idx==1)plane_cb[(by+emit_i[5:3])*chroma_width+bx+emit_i[2:0]]<=coef[emit_i][7:0];
 else plane_cr[(by+emit_i[5:3])*chroma_width+bx+emit_i[2:0]]<=coef[emit_i][7:0];end
 if(emit_i==63)begin
 clear_i<=0;state<=BLOCK_CLEAR;
 if(comp_idx==0&&block_idx+1<(1<<({1'b0,hsub}+{1'b0,vsub})))begin
 block_idx<=block_idx+1;
 bx<=mcu_x+(((block_idx+1)&(hsub?1:0))<<3);
 by<=mcu_y+(((block_idx+1)>>hsub)<<3);
 end else if(comp_idx<2)begin
 comp_idx<=comp_idx+1;block_idx<=0;bx<=mcu_x>>hsub;by<=mcu_y>>vsub;
 qid<=component_qid[comp_idx+1];dcid<=component_dc[comp_idx+1];acid<=component_ac[comp_idx+1];
 end else begin
 comp_idx<=0;block_idx<=0;qid<=component_qid[0];dcid<=component_dc[0];acid<=component_ac[0];
 if(mcu_x+(8<<hsub)>=width)begin
 mcu_x<=0;bx<=0;mcu_y<=mcu_y+(8<<vsub);by<=mcu_y+(8<<vsub);
 if(mcu_y+(8<<vsub)>=height)begin
 if(bits_left!=0&&bitbuf!=(8'hff<<(8-bits_left)))fail(8'h91);
 else begin bits_left<=0;getbyte(EOI0);end end
 end else begin mcu_x<=mcu_x+(8<<hsub);bx<=mcu_x+(8<<hsub);by<=mcu_y;end
 end
 end else emit_i<=emit_i+1;end
 EOI0:if(byte_q!=8'hff)fail(8'h91);else getbyte(EOI1);
 EOI1:if(byte_q==8'hff)getbyte(EOI1);else if(byte_q!=8'hd9||pos!=captured)fail(8'h91);else begin out_pos<=0;out_x<=0;out_y<=0;state<=OUT_ADDR;end
 OUT_ADDR:begin yq<=plane_y[out_pos];tap<=0;state<=OUT_TAP;end
 OUT_TAP:begin cbtap[tap]<=plane_cb[tap_addr];crtap[tap]<=plane_cr[tap_addr];
 if(tap==3)state<=OUT_DATA;else tap<=tap+1;end
 OUT_DATA:begin out_data<={clip8(red),clip8(green),clip8(blue)};state<=OUT_HOLD;end
 OUT_HOLD:if(m_ready)begin if(out_pos==width*height-1)state<=DONE;else begin out_pos<=out_pos+1;if(out_x==width-1)begin out_x<=0;out_y<=out_y+1;end else out_x<=out_x+1;state<=OUT_ADDR;end end
 DONE:if(done_ready)state<=IDLE;
 default:fail(8'h94);
 endcase
 if(fail_flag)state<=DONE;
 end
 end
endmodule

