// Four cardinal directions, exact Hirschmueller normalized recurrence.
// Descriptor frames are stored; all coefficient/cost RAM reads are synchronous.
module stereo_sgm #(
 parameter WIDTH=16, HEIGHT=8, DESC_BITS=24, DISPARITIES=8,
 parameter DISP_BITS=(DISPARITIES<=1?1:$clog2(DISPARITIES))
)(
 input wire clk,rst_n,ce,
 input wire start_valid,output wire start_ready,input wire[7:0] cfg_p1,cfg_p2,
 input wire[DESC_BITS-1:0] s_left,s_right,input wire s_left_border,s_right_border,
 input wire s_valid,output wire s_ready,input wire s_sof,s_eol,s_last,
 output reg[DISP_BITS-1:0] m_disparity,output reg[13:0] m_score,output reg m_invalid,
 output wire m_valid,input wire m_ready,output wire m_sof,m_eol,m_last,
 output wire done_valid,input wire done_ready,output reg done_error,output reg[2:0] error_code
);
 localparam N=WIDTH*HEIGHT,V=N*DISPARITIES;
 localparam IDLE=0,CAPTURE=1,LREAD=2,RREAD=3,COST=4,PREAD=5,PSCAN=6,AREAD=7,WRITE=8,NEXT=9,OREAD=10,OSCAN=11,HOLD=12,DONE=13;
 reg[3:0] state;
 reg[DESC_BITS:0] lm[0:N-1],rm[0:N-1];
 reg[11:0] paths[0:V-1];reg[13:0] aggregate[0:V-1];
 reg[DESC_BITS:0] lq,rq;reg[11:0] pq;reg[13:0] aq;
 reg[7:0] p1,p2;reg[1:0] direction;
 integer pixel,x,y,d,j,prev;reg boundary;
 reg[11:0] cost,minprev,same,lo,hi,path_value;
 reg[13:0] best;reg[DISP_BITS-1:0] bestd;reg anyvalid;
 integer k;reg[11:0] hamming,penalty,tmp;
 always @*begin
  hamming=0;for(k=0;k<DESC_BITS;k=k+1)hamming=hamming+(lq[k]^rq[k]);
  penalty=same;
  tmp=lo+p1;if(tmp<penalty)penalty=tmp;
  tmp=hi+p1;if(tmp<penalty)penalty=tmp;
  tmp=minprev+p2;if(tmp<penalty)penalty=tmp;
 end
 assign start_ready=rst_n&&ce&&state==IDLE;
 assign s_ready=rst_n&&ce&&state==CAPTURE;
 assign m_valid=rst_n&&state==HOLD;
 assign m_sof=m_valid&&pixel==0;assign m_eol=m_valid&&x==WIDTH-1;assign m_last=m_valid&&pixel==N-1;
 assign done_valid=rst_n&&state==DONE;
 initial begin
  if(WIDTH<1||HEIGHT<1||WIDTH>256||HEIGHT>256||N>4096||DESC_BITS<1||DESC_BITS>64||DISPARITIES<1||DISPARITIES>64||DISPARITIES>WIDTH||DISP_BITS<(DISPARITIES<=1?1:$clog2(DISPARITIES)))$fatal(1,"stereo_sgm invalid parameters");
 end
 always @(posedge clk)begin
  if(!rst_n)begin state<=IDLE;pixel<=0;x<=0;y<=0;d<=0;j<=0;direction<=0;done_error<=0;error_code<=0;m_disparity<=0;m_score<=0;m_invalid<=1;p1<=0;p2<=0;end
  else if(ce)begin
   case(state)
    IDLE:if(start_valid)begin
     done_error<=0;error_code<=0;pixel<=0;x<=0;y<=0;
     if(cfg_p1>cfg_p2)begin done_error<=1;error_code<=1;state<=DONE;end
     else begin p1<=cfg_p1;p2<=cfg_p2;state<=CAPTURE;end
    end
    CAPTURE:if(s_valid)begin
     if(s_sof!=(pixel==0)||s_eol!=(x==WIDTH-1)||s_last!=(pixel==N-1))begin done_error<=1;error_code<=2;state<=DONE;end
     else begin
      lm[pixel]<={s_left_border,s_left};rm[pixel]<={s_right_border,s_right};
      if(pixel==N-1)begin pixel<=0;x<=0;y<=0;direction<=0;d<=0;state<=LREAD;end
      else begin pixel<=pixel+1;if(x==WIDTH-1)begin x<=0;y<=y+1;end else x<=x+1;end
     end
    end
    LREAD:begin
     lq<=lm[pixel];
     case(direction)
      0:begin boundary<=x==0;prev<=pixel-1;end
      1:begin boundary<=x==WIDTH-1;prev<=pixel+1;end
      2:begin boundary<=y==0;prev<=pixel-WIDTH;end
      3:begin boundary<=y==HEIGHT-1;prev<=pixel+WIDTH;end
     endcase
     state<=RREAD;
    end
    RREAD:begin rq<=rm[pixel-(d<=x?d:0)];state<=COST;end
    COST:begin
     cost<=(lq[DESC_BITS]||rq[DESC_BITS]||d>x)?12'd1024:hamming;
     minprev<=4095;same<=4095;lo<=3584;hi<=3584;j<=0;
     if(boundary)state<=AREAD;else state<=PREAD;
    end
    PREAD:begin pq<=paths[prev*DISPARITIES+j];state<=PSCAN;end
    PSCAN:begin
     if(pq<minprev)minprev<=pq;
     if(j==d)same<=pq;if(j+1==d)lo<=pq;if(j==d+1)hi<=pq;
     if(j==DISPARITIES-1)state<=AREAD;else begin j<=j+1;state<=PREAD;end
    end
    AREAD:begin aq<=aggregate[pixel*DISPARITIES+d];path_value<=boundary?cost:cost+penalty-minprev;state<=WRITE;end
    WRITE:begin
     paths[pixel*DISPARITIES+d]<=path_value;
     aggregate[pixel*DISPARITIES+d]<=direction==0?{2'b0,path_value}:aq+path_value;
     state<=NEXT;
    end
    NEXT:begin
     if(d!=DISPARITIES-1)begin d<=d+1;state<=RREAD;end
     else begin
      d<=0;
      if((direction==0||direction==2)?pixel==N-1:pixel==0)begin
       if(direction==3)begin pixel<=0;x<=0;y<=0;best<=16383;bestd<=0;anyvalid<=0;state<=OREAD;end
       else begin direction<=direction+1;pixel<=(direction==0||direction==2)?N-1:0;x<=(direction==0||direction==2)?WIDTH-1:0;y<=(direction==0||direction==2)?HEIGHT-1:0;state<=LREAD;end
      end else begin
       if(direction==0||direction==2)begin pixel<=pixel+1;if(x==WIDTH-1)begin x<=0;y<=y+1;end else x<=x+1;end
       else begin pixel<=pixel-1;if(x==0)begin x<=WIDTH-1;y<=y-1;end else x<=x-1;end
       state<=LREAD;
      end
     end
    end
    OREAD:begin aq<=aggregate[pixel*DISPARITIES+d];lq<=lm[pixel];rq<=rm[pixel-(d<=x?d:0)];state<=OSCAN;end
    OSCAN:begin
     if(d<=x&&!lq[DESC_BITS]&&!rq[DESC_BITS])begin
      anyvalid<=1;if(aq<best)begin best<=aq;bestd<=d;end
     end
     if(d==DISPARITIES-1)begin
      m_invalid<=!(anyvalid||(d<=x&&!lq[DESC_BITS]&&!rq[DESC_BITS]));
      if(d<=x&&!lq[DESC_BITS]&&!rq[DESC_BITS]&&aq<best)begin m_score<=aq;m_disparity<=d;end
      else begin m_score<=best;m_disparity<=bestd;end
      state<=HOLD;
     end else begin d<=d+1;state<=OREAD;end
    end
    HOLD:if(m_ready)begin
     if(pixel==N-1)state<=DONE;
     else begin pixel<=pixel+1;if(x==WIDTH-1)begin x<=0;y<=y+1;end else x<=x+1;d<=0;best<=16383;bestd<=0;anyvalid<=0;state<=OREAD;end
    end
    DONE:if(done_ready)state<=IDLE;
    default:begin state<=DONE;done_error<=1;error_code<=3;end
   endcase
  end
 end
endmodule
