// RGB8 <-> OpenCV HSV_FULL. Forward hue uses 256 turns; inverse uses 255.
// Serial shared divider, deterministic nearest/half-up rational arithmetic.
module rgb_hsv_full_stream #(parameter WIDTH=16,HEIGHT=16)(
 input wire clk,rst,ce,start_valid,cfg_inverse, output wire start_ready,
 input wire [23:0] s_data,input wire s_valid,s_sof,s_eol,output wire s_ready,
 output reg [23:0] m_data,output wire m_valid,output reg m_sof,m_eol,
 input wire m_ready,output reg done,error,output wire done_valid,input wire done_ready,output reg[3:0] error_code,output wire busy
);
 localparam IDLE=0,INPUT=1,SETUP=2,DIV=3,NEXT=4,OUTPUT=5,COMPLETE=6;
 reg[2:0] state;reg inverse;reg[23:0] pixel;
 reg[15:0] count,column;reg[1:0] phase;reg[2:0] sector;
 reg[7:0] vmax,delta,hue,sat,pval,qval,tval;
 reg[7:0] frac;reg[23:0] dividend,quotient,denominator;
 reg[24:0] remainder;reg[4:0] bitcount;
 wire[24:0] trial={remainder[23:0],dividend[23]};
 wire subtract=trial>={1'b0,denominator};
 wire[23:0] qnext={quotient[22:0],subtract};
 assign start_ready=ce&&!rst&&state==IDLE;
 assign s_ready=ce&&!rst&&state==INPUT;
 assign m_valid=!rst&&state==OUTPUT;
 assign busy=state!=IDLE;
 assign done_valid=!rst&&state==COMPLETE;
 function[23:0] mul8;
 input[7:0] a;input[15:0] b;integer k;reg[23:0] v;
 begin v=0;for(k=0;k<8;k=k+1)if(a[k])v=v+({8'b0,b}<<k);mul8=v;end
 endfunction
 reg[7:0] mx,mn,r,g,b;reg[18:0] hn;reg[15:0] hs;reg[2:0] sec;
 reg[23:0] num,den;
 always @* begin
 r=pixel[23:16];g=pixel[15:8];b=pixel[7:0];
 mx=r>g?r:g;if(b>mx)mx=b;mn=r<g?r:g;if(b<mn)mn=b;
 hn=0;hs=({8'b0,r}<<2)+({8'b0,r}<<1);sec=0;
 if(hs>=1275)begin sec=5;hs=hs-1275;end
 else if(hs>=1020)begin sec=4;hs=hs-1020;end
 else if(hs>=765)begin sec=3;hs=hs-765;end
 else if(hs>=510)begin sec=2;hs=hs-510;end
 else if(hs>=255)begin sec=1;hs=hs-255;end
 if(r==255)begin sec=0;hs=0;end
 if(r==mx)begin if(g>=b)hn=g-b;else hn=6*(mx-mn)+g-b;end
 else if(g==mx)hn=2*(mx-mn)+b-r;
 else hn=4*(mx-mn)+r-g;
 num=0;den=1;
 if(!inverse)begin
 if(phase==0)begin num=mul8(delta,255);den=vmax;end
 else begin num=hn<<8;den=6*delta;end
 end else case(phase)
 0:begin num=mul8(vmax,255-sat);den=255;end
 1:begin num=mul8(vmax,65025-mul8(sat,{8'b0,frac}));den=65025;end
 default:begin num=mul8(vmax,65025-mul8(sat,255-frac));den=65025;end
 endcase
 end
 initial if(WIDTH<1||HEIGHT<1||WIDTH>65536||HEIGHT>65536||WIDTH*HEIGHT>65536)$fatal(1,"invalid geometry");
 always @(posedge clk)begin
 if(rst)begin state<=IDLE;inverse<=0;pixel<=0;count<=0;column<=0;phase<=0;sector<=0;vmax<=0;delta<=0;hue<=0;sat<=0;pval<=0;qval<=0;tval<=0;frac<=0;dividend<=0;quotient<=0;denominator<=1;remainder<=0;bitcount<=0;m_data<=0;m_sof<=0;m_eol<=0;done<=0;error<=0;error_code<=0;end
 else if(ce)case(state)
 IDLE:if(start_valid)begin inverse<=cfg_inverse;count<=0;column<=0;done<=0;error<=0;error_code<=0;state<=INPUT;end
 INPUT:if(s_valid)begin pixel<=s_data;m_sof<=count==0;m_eol<=column==WIDTH-1;
 if(s_sof!=(count==0)||s_eol!=(column==WIDTH-1))begin error<=1;error_code<=error_code|{(s_eol&&column!=WIDTH-1),(!s_eol&&column==WIDTH-1),(s_sof&&count!=0),(!s_sof&&count==0)};end
 phase<=0;state<=NEXT;end
 NEXT:begin
 if(!inverse)begin vmax<=mx;delta<=mx-mn;
 if(mx==mn)begin m_data<={8'b0,8'b0,mx};state<=OUTPUT;end else state<=SETUP;
 end else begin vmax<=b;sat<=g;sector<=sec;frac<=hs[7:0];state<=SETUP;end
 end
 SETUP:begin dividend<=num+(den>>1);denominator<=den;remainder<=0;quotient<=0;bitcount<=23;state<=DIV;end
 DIV:begin
 dividend<=dividend<<1;quotient<=qnext;remainder<=subtract?trial-denominator:trial;
 if(bitcount==0)begin
 if(!inverse)begin
 if(phase==0)begin sat<=qnext[7:0];phase<=1;state<=SETUP;end
 else begin m_data<={qnext[7:0],sat,vmax};state<=OUTPUT;end
 end else if(phase==0)begin pval<=qnext[7:0];phase<=1;state<=SETUP;end
 else if(phase==1)begin qval<=qnext[7:0];phase<=2;state<=SETUP;end
 else begin
 case(sector)
 0:m_data<={vmax,qnext[7:0],pval};1:m_data<={qval,vmax,pval};
 2:m_data<={pval,vmax,qnext[7:0]};3:m_data<={pval,qval,vmax};
 4:m_data<={qnext[7:0],pval,vmax};default:m_data<={vmax,pval,qval};endcase
 state<=OUTPUT;end
 end else bitcount<=bitcount-1;
 end
 OUTPUT:if(m_ready)begin if(count==WIDTH*HEIGHT-1)begin done<=1;state<=COMPLETE;end else begin count<=count+1;column<=column==WIDTH-1?0:column+1;state<=INPUT;end end
 COMPLETE:if(done_ready)state<=IDLE;
 default:begin error<=1;error_code<=15;done<=1;state<=COMPLETE;end
 endcase
 end
endmodule


