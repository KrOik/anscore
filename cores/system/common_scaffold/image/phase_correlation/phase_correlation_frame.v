// True phase-only 2D Fourier correlation. No spatial SAD/correlation approximation.
module phase_correlation_frame #(parameter SIDE=16,TWIDDLE_FILE="twiddle.mem")(
 input wire clk,rst,ce,start_valid,output wire start_ready,input wire cfg_remove_dc,
 input wire[7:0] s_a,s_b,input wire s_valid,s_sof,s_eol,output wire s_ready,
 output wire m_valid,input wire m_ready,output reg signed[6:0] m_dx,m_dy,
 output reg signed[31:0] m_peak,output reg[15:0] m_valid_bins,output reg m_invalid,
 output wire done_valid,input wire done_ready,output reg done_error,output reg[7:0] error_code,output wire busy
);
 localparam LG=$clog2(SIDE),N=SIDE*SIDE,AW=2*LG;
 localparam IDLE=0,INPUT_PIXEL=1,FFT_SETUP=2,FFT_READ=3,FFT_CAPTURE=4,
 F_MUL0=5,F_RET0=6,F_MUL1=7,F_RET1=8,F_MUL2=9,F_RET2=10,F_MUL3=11,F_RET3=12,F_OUT=13,F_WRITE=14,
 CROSS_READ=15,CROSS_CAPTURE=16,C_MUL0=17,C_RET0=18,C_MUL1=19,C_RET1=20,C_MUL2=21,C_RET2=22,C_MUL3=23,C_RET3=24,
 C_SQUARE0=25,C_SRET0=26,C_SQUARE1=27,C_SRET1=28,SQRT=29,NORM0=30,NRET0=31,NORM1=32,NRET1=33,C_STORE=34,
 PEAK_READ=35,PEAK_CAPTURE=36,PEAK_FINISH=37,HOLD=38,DONE=39,MULTIPLY=40,DIVIDE=41;
 reg[5:0] state,return_state;
 reg remove_dc,inverse,axis;reg[1:0] bank;reg[2:0] stage;
 reg[5:0] line,block_index,j;
 reg[AW-1:0] count,address0,address1,peak_index;
 reg[4:0] twiddle_address;
 reg[33:0] twiddle_rom[0:15],twiddle_q;
 reg[47:0] mem_a[0:N-1],mem_b[0:N-1],mem_c[0:N-1];
 reg[47:0] aq0,aq1,bq0,bq1,cq0,cq1;
 reg signed[23:0] ar,ai,br,bi,out0r,out0i,out1r,out1i,normr,normi;
 reg signed[16:0] wr,wi;
 reg signed[31:0] tr,ti,crossr,crossi;
 reg signed[63:0] temporary,product,cross_real_wide;
 reg[63:0] magnitude,multiplicand,magnitude_square,radicand;
 reg[31:0] multiplier,root;
 reg negative;reg[4:0] mul_bit,sqrt_bit;
 reg[65:0] sqrt_remainder;
 reg[63:0] dividend,quotient;
 reg[31:0] divisor;reg[64:0] remainder;reg[5:0] div_bit;
 reg[15:0] valid_bins,peak_ties;
 reg signed[31:0] peak;
 wire[6:0] length=7'd1<<stage,half_length=7'd1<<(stage-1);
 wire[6:0] position0=block_index+j,position1=block_index+j+half_length;
 wire[AW-1:0] next_address0=axis?((position0<<LG)+line):((line<<LG)+position0);
 wire[AW-1:0] next_address1=axis?((position1<<LG)+line):((line<<LG)+position1);
 function[AW-1:0] bit_reverse_2d;input[AW-1:0] value;integer k;
 begin for(k=0;k<LG;k=k+1)begin bit_reverse_2d[k]=value[LG-1-k];bit_reverse_2d[LG+k]=value[2*LG-1-k];end end endfunction
 wire capture=state==INPUT_PIXEL&&s_valid;
 wire cross_read=state==CROSS_READ;
 wire fft_read=state==FFT_READ;
 wire peak_read=state==PEAK_READ;
 // Identical physical addresses on each port's read/write sides allow true
 // dual-port BRAM inference; address multiplexing precedes the RAM ports.
 wire[AW-1:0] ab_port0_address=capture?bit_reverse_2d(count):(cross_read?count:address0);
 wire[AW-1:0] c_port0_address=state==C_STORE?bit_reverse_2d(count):(peak_read?count:address0);
 wire[47:0] a_write_data=capture?{4'b0,s_a,12'b0,24'b0}:{out0r,out0i};
 wire[47:0] b_write_data=capture?{4'b0,s_b,12'b0,24'b0}:{out0r,out0i};
 wire[47:0] c_write_data=state==C_STORE?{normr,normi}:{out0r,out0i};
 wire[47:0] q0=bank==0?aq0:(bank==1?bq0:cq0),q1=bank==0?aq1:(bank==1?bq1:cq1);
 wire[65:0] sqrt_trial={32'b0,root,2'b01};
 wire[65:0] sqrt_next_remainder={sqrt_remainder[63:0],radicand[63:62]};
 wire sqrt_subtract=sqrt_next_remainder>=sqrt_trial;
 wire[31:0] root_next={root[30:0],sqrt_subtract};
 wire[64:0] div_trial={remainder[63:0],dividend[63]};
 wire div_subtract=div_trial>={33'b0,divisor};
 wire[63:0] quotient_next={quotient[62:0],div_subtract};
 wire signed[31:0] scanned_real={{8{cq0[47]}},cq0[47:24]};
 wire[6:0] peak_x=peak_index&(SIDE-1),peak_y=peak_index>>LG;
 assign start_ready=ce&&!rst&&state==IDLE;assign s_ready=ce&&!rst&&state==INPUT_PIXEL;
 assign m_valid=!rst&&state==HOLD;assign done_valid=!rst&&state==DONE;assign busy=state!=IDLE;
 function signed[31:0] rounded;
 input signed[63:0] v;input[5:0] bits;
 begin if(v<0)rounded=-(((-v)+(64'sd1<<(bits-1)))>>>bits);else rounded=(v+(64'sd1<<(bits-1)))>>>bits;end endfunction
 task mul;input signed[31:0] a,b;input[5:0] next_state;
 begin magnitude<=0;multiplicand<={32'b0,(a<0?-a:a)};multiplier<=b<0?-b:b;negative<=a[31]^b[31];mul_bit<=0;return_state<=next_state;state<=MULTIPLY;end endtask
 task divide;input signed[31:0] v;input[5:0] next_state;
 reg[31:0] absolute_value;
 begin absolute_value=v<0?-v:v;dividend<=({32'b0,absolute_value}<<20)+(root>>1);divisor<=root;quotient<=0;remainder<=0;div_bit<=0;negative<=v[31];return_state<=next_state;state<=DIVIDE;end endtask
 task begin_fft;input[1:0] selected_bank;input inv;
 begin bank<=selected_bank;inverse<=inv;axis<=0;stage<=1;line<=0;block_index<=0;j<=0;state<=FFT_SETUP;end endtask
 initial begin
 if(SIDE!=8&&SIDE!=16&&SIDE!=32)$fatal(1,"phase correlation SIDE must be 8/16/32");
 $readmemh(TWIDDLE_FILE,twiddle_rom);
 end
 // Two synchronous read/write ports per complex coefficient RAM. No array reset.
 always @(posedge clk)if(ce&&!rst)begin
 if((fft_read&&bank==0)||cross_read)aq0<=mem_a[ab_port0_address];
 if(fft_read&&bank==0)aq1<=mem_a[address1];
 if((fft_read&&bank==1)||cross_read)bq0<=mem_b[ab_port0_address];
 if(fft_read&&bank==1)bq1<=mem_b[address1];
 if((fft_read&&bank==2)||peak_read)cq0<=mem_c[c_port0_address];
 if(fft_read&&bank==2)cq1<=mem_c[address1];
 if(fft_read)twiddle_q<=twiddle_rom[twiddle_address];
 if(capture||(state==F_WRITE&&bank==0))mem_a[ab_port0_address]<=a_write_data;
 if(state==F_WRITE&&bank==0)mem_a[address1]<={out1r,out1i};
 if(capture||(state==F_WRITE&&bank==1))mem_b[ab_port0_address]<=b_write_data;
 if(state==F_WRITE&&bank==1)mem_b[address1]<={out1r,out1i};
 if(state==C_STORE||(state==F_WRITE&&bank==2))mem_c[c_port0_address]<=c_write_data;
 if(state==F_WRITE&&bank==2)mem_c[address1]<={out1r,out1i};
 end
 always @(posedge clk)begin
 if(rst)begin
 state<=IDLE;return_state<=0;remove_dc<=0;inverse<=0;axis<=0;bank<=0;stage<=1;line<=0;block_index<=0;j<=0;
 count<=0;address0<=0;address1<=0;peak_index<=0;twiddle_address<=0;
 ar<=0;ai<=0;br<=0;bi<=0;out0r<=0;out0i<=0;out1r<=0;out1i<=0;normr<=0;normi<=0;wr<=0;wi<=0;tr<=0;ti<=0;crossr<=0;crossi<=0;
 temporary<=0;product<=0;cross_real_wide<=0;magnitude<=0;multiplicand<=0;magnitude_square<=0;radicand<=0;multiplier<=0;root<=0;negative<=0;mul_bit<=0;sqrt_bit<=0;sqrt_remainder<=0;
 dividend<=0;quotient<=0;divisor<=1;remainder<=0;div_bit<=0;valid_bins<=0;peak_ties<=0;peak<=-2147483647;
 m_dx<=0;m_dy<=0;m_peak<=0;m_valid_bins<=0;m_invalid<=0;done_error<=0;error_code<=0;
 end else if(ce)case(state)
 IDLE:if(start_valid)begin remove_dc<=cfg_remove_dc;count<=0;done_error<=0;error_code<=0;m_invalid<=0;valid_bins<=0;state<=INPUT_PIXEL;end
 INPUT_PIXEL:if(s_valid)begin
 if(s_sof!=(count==0)||s_eol!=((count&(SIDE-1))==SIDE-1))begin done_error<=1;error_code<=error_code|{4'b0,(s_eol&&((count&(SIDE-1))!=SIDE-1)),(!s_eol&&((count&(SIDE-1))==SIDE-1)),(s_sof&&count!=0),(!s_sof&&count==0)};end
 if(count==N-1)begin_fft(0,0);else count<=count+1'b1;end
 FFT_SETUP:begin address0<=next_address0;address1<=next_address1;twiddle_address<=j<<(5-stage);state<=FFT_READ;end
 FFT_READ:state<=FFT_CAPTURE;
 FFT_CAPTURE:begin ar<=q0[47:24];ai<=q0[23:0];br<=q1[47:24];bi<=q1[23:0];wr<=twiddle_q[33:17];wi<=inverse?-$signed(twiddle_q[16:0]):$signed(twiddle_q[16:0]);state<=F_MUL0;end
 F_MUL0:mul(arithmetic_extend(br),arithmetic_extend17(wr),F_RET0);
 F_RET0:begin temporary<=product;state<=F_MUL1;end
 F_MUL1:mul(arithmetic_extend(bi),arithmetic_extend17(wi),F_RET1);
 F_RET1:begin tr<=rounded(temporary-product,15);state<=F_MUL2;end
 F_MUL2:mul(arithmetic_extend(br),arithmetic_extend17(wi),F_RET2);
 F_RET2:begin temporary<=product;state<=F_MUL3;end
 F_MUL3:mul(arithmetic_extend(bi),arithmetic_extend17(wr),F_RET3);
 F_RET3:begin ti<=rounded(temporary+product,15);state<=F_OUT;end
 F_OUT:begin out0r<=rounded($signed(ar)+$signed(tr),1);out0i<=rounded($signed(ai)+$signed(ti),1);out1r<=rounded($signed(ar)-$signed(tr),1);out1i<=rounded($signed(ai)-$signed(ti),1);state<=F_WRITE;end
 F_WRITE:begin
 if(j+1<half_length)begin j<=j+1'b1;state<=FFT_SETUP;end
 else begin j<=0;
 if(block_index+length<SIDE)begin block_index<=block_index+length;state<=FFT_SETUP;end
 else begin block_index<=0;
 if(line+1<SIDE)begin line<=line+1'b1;state<=FFT_SETUP;end
 else begin line<=0;
 if(stage<LG)begin stage<=stage+1'b1;state<=FFT_SETUP;end
 else if(!axis)begin axis<=1;stage<=1;state<=FFT_SETUP;end
 else if(bank==0)begin_fft(1,0);
 else if(bank==1)begin count<=0;state<=CROSS_READ;end
 else begin count<=0;peak<=-2147483647;peak_ties<=0;peak_index<=0;state<=PEAK_READ;end
 end end end end
 CROSS_READ:state<=CROSS_CAPTURE;
 CROSS_CAPTURE:begin ar<=aq0[47:24];ai<=aq0[23:0];br<=bq0[47:24];bi<=bq0[23:0];
 if(count==0&&remove_dc)begin normr<=0;normi<=0;state<=C_STORE;end else state<=C_MUL0;end
 C_MUL0:mul(arithmetic_extend(ar),arithmetic_extend(br),C_RET0);
 C_RET0:begin temporary<=product;state<=C_MUL1;end
 C_MUL1:mul(arithmetic_extend(ai),arithmetic_extend(bi),C_RET1);
 C_RET1:begin cross_real_wide<=temporary+product;state<=C_MUL2;end
 C_MUL2:mul(arithmetic_extend(ai),arithmetic_extend(br),C_RET2);
 C_RET2:begin temporary<=product;state<=C_MUL3;end
 C_MUL3:mul(arithmetic_extend(ar),arithmetic_extend(bi),C_RET3);
 C_RET3:begin crossr<=rounded(cross_real_wide,12);crossi<=rounded(temporary-product,12);state<=C_SQUARE0;end
 C_SQUARE0:mul(crossr,crossr,C_SRET0);
 C_SRET0:begin magnitude_square<=product;state<=C_SQUARE1;end
 C_SQUARE1:mul(crossi,crossi,C_SRET1);
 C_SRET1:begin radicand<=magnitude_square+product;root<=0;sqrt_remainder<=0;sqrt_bit<=0;state<=SQRT;end
 SQRT:begin
 radicand<=radicand<<2;root<=root_next;sqrt_remainder<=sqrt_subtract?sqrt_next_remainder-sqrt_trial:sqrt_next_remainder;
 if(sqrt_bit==31)begin if(root_next==0)begin normr<=0;normi<=0;state<=C_STORE;end else begin valid_bins<=valid_bins+1'b1;state<=NORM0;end end else sqrt_bit<=sqrt_bit+1'b1;end
 NORM0:divide(crossr,NRET0);
 NRET0:begin normr<=negative?-$signed(quotient[23:0]):$signed(quotient[23:0]);state<=NORM1;end
 NORM1:divide(crossi,NRET1);
 NRET1:begin normi<=negative?-$signed(quotient[23:0]):$signed(quotient[23:0]);state<=C_STORE;end
 C_STORE:if(count==N-1)begin_fft(2,1);else begin count<=count+1'b1;state<=CROSS_READ;end
 PEAK_READ:state<=PEAK_CAPTURE;
 PEAK_CAPTURE:begin
 if(scanned_real>peak)begin peak<=scanned_real;peak_index<=count;peak_ties<=1;end else if(scanned_real==peak)peak_ties<=peak_ties+1'b1;
 if(count==N-1)state<=PEAK_FINISH;else begin count<=count+1'b1;state<=PEAK_READ;end end
 PEAK_FINISH:begin
 m_dx<=peak_x>=SIDE/2?$signed({1'b0,peak_x})-SIDE:$signed({1'b0,peak_x});
 m_dy<=peak_y>=SIDE/2?$signed({1'b0,peak_y})-SIDE:$signed({1'b0,peak_y});
 m_peak<=peak;m_valid_bins<=valid_bins;m_invalid<=done_error||valid_bins<3||peak_ties!=1||peak<=0;
 if(valid_bins<3||peak_ties!=1||peak<=0)begin done_error<=1;error_code<=error_code|8'h10;end
 state<=HOLD;end
 HOLD:if(m_ready)state<=DONE;
 DONE:if(done_ready)state<=IDLE;
 MULTIPLY:begin
 magnitude<=magnitude+(multiplier[0]?multiplicand:64'b0);multiplicand<=multiplicand<<1;multiplier<=multiplier>>1;
 if(mul_bit==31)begin product<=negative?-$signed(magnitude+(multiplier[0]?multiplicand:64'b0)):$signed(magnitude+(multiplier[0]?multiplicand:64'b0));state<=return_state;end else mul_bit<=mul_bit+1'b1;end
 DIVIDE:begin dividend<=dividend<<1;quotient<=quotient_next;remainder<=div_subtract?div_trial-divisor:div_trial;if(div_bit==63)state<=return_state;else div_bit<=div_bit+1'b1;end
 default:begin done_error<=1;error_code<=error_code|8'h20;state<=DONE;end
 endcase
 end
 function signed[31:0] arithmetic_extend;input signed[23:0] v;begin arithmetic_extend=v;end endfunction
 function signed[31:0] arithmetic_extend17;input signed[16:0] v;begin arithmetic_extend17=v;end endfunction
endmodule
