// Complete bounded-frame Canny: Gaussian -> Sobel L1 -> 4-direction NMS ->
// double threshold -> repeated 8-connected weak-edge propagation to a fixed
// point. In-place raster propagation is repeated, not a one-hop approximation.
// All frame memories have synchronous reads. Native shared-CE protocol.
module img_edge_canny #(parameter PIXEL_W=8,parameter MAX_WIDTH=64,parameter MAX_HEIGHT=64)(
    input wire clk, rst_n, clk_en,
    input wire cmd_valid, output wire cmd_ready,
    input wire [7:0] cmd_tag,
    input wire [15:0] cfg_width, cfg_height,
    input wire [PIXEL_W+3:0] cfg_low, cfg_high,
    output wire rsp_valid, input wire rsp_ready,
    output wire [7:0] rsp_tag, rsp_error,
    input wire [PIXEL_W-1:0] s_data,
    input wire s_valid, s_sof, s_eol, output wire s_ready,
    output wire [PIXEL_W-1:0] m_data,
    output wire m_valid, m_sof, m_eol, input wire m_ready
);
    localparam MW=PIXEL_W+4,N=MAX_WIDTH*MAX_HEIGHT;
    localparam IDLE=0,LOAD=1,BR=2,BC=3,BW=4,GR=5,GC=6,GW=7,
       NR=8,NC=9,NNR=10,NNC=11,NW=12,HR=13,HC=14,HNR=15,HNC=16,HW=17,
       ORQ=18,OC=19,OSEND=20,GSUM=21,GDIFF=22,GABS=23,GSCALE=24;
    reg [4:0] state;
    localparam XW=(MAX_WIDTH<2)?1:$clog2(MAX_WIDTH);
    localparam YW=(MAX_HEIGHT<2)?1:$clog2(MAX_HEIGHT);
    localparam WW=(MAX_WIDTH<1)?1:$clog2(MAX_WIDTH+1);
    localparam HWIDTH=(MAX_HEIGHT<1)?1:$clog2(MAX_HEIGHT+1);
    localparam AW=(N<2)?1:$clog2(N);
    localparam SW=(N<1)?1:$clog2(N+1);
    reg [WW-1:0] width;
    reg [HWIDTH-1:0] height;
    reg [MW-1:0] low,high;
    reg [7:0] tag,frame_error;
    reg response_valid,output_valid,output_sof,output_eol;
    reg [PIXEL_W-1:0] output_data;
    reg [AW-1:0] count,read_addr;
    reg [XW-1:0] x;
    reg [YW-1:0] y;
    reg [3:0] tap,tindex;
    reg signed [1:0] dx,dy;
    reg [SW-1:0] scans;
    reg changed,promote;
    reg [PIXEL_W-1:0] taps[0:8];
    reg [PIXEL_W-1:0] raw_q,blur_q;
    reg [MW+1:0] grad_q;
    reg [1:0] label_q,center_label,center_direction;
    reg [MW-1:0] center_mag,neighbor0,neighbor1;
    (* ram_style="block" *) reg [PIXEL_W-1:0] raw_mem[0:N-1];
    (* ram_style="block" *) reg [PIXEL_W-1:0] blur_mem[0:N-1];
    (* ram_style="block" *) reg [MW+1:0] gradient_mem[0:N-1];
    (* ram_style="block" *) reg [1:0] label_mem[0:N-1];
    // |Gx|, |Gy| <= 4*(2**PIXEL_W-1). Explicit signed extension
    // preserves the original integer expressions without a 32-bit cone.
    reg [PIXEL_W+1:0] xpos,xneg,ypos,yneg;
    reg signed [PIXEL_W+2:0] gx,gy;
    reg [PIXEL_W+8:0] ax106,ay106;
    reg [PIXEL_W+1:0] ax,ay;
    reg [MW-1:0] magnitude;
    reg [PIXEL_W+3:0] gaussian;
    reg [1:0] direction,classification;
    assign cmd_ready=rst_n && clk_en && state==IDLE && !response_valid;
    assign s_ready=rst_n && clk_en && state==LOAD;
    assign rsp_valid=response_valid;
    assign rsp_tag=tag;
    assign rsp_error=frame_error;
    assign m_valid=output_valid;assign m_data=output_data;
    assign m_sof=output_sof;assign m_eol=output_eol;
    function integer address;
        input integer px,py,ox,oy,w,h;
        integer xx,yy;
        begin
            xx=px+ox;yy=py+oy;
            if(xx<0)xx=0;else if(xx>=w)xx=w-1;
            if(yy<0)yy=0;else if(yy>=h)yy=h-1;
            address=yy*w+xx;
        end
    endfunction
    always @* begin
        dx=0;dy=0;tindex=tap;
        if(state==BR || state==GR) begin dx=(tap%3)-1;dy=(tap/3)-1;end
        if(state==HNR) begin
            tindex=(tap>=4)?tap+1:tap;dx=(tindex%3)-1;dy=(tindex/3)-1;
        end
        if(state==NNR) begin
            case(center_direction)
              0:begin dx=1;dy=0;end
              1:begin dx=1;dy=1;end
              2:begin dx=0;dy=1;end
              3:begin dx=1;dy=-1;end
            endcase
            if(tap==0)begin dx=-dx;dy=-dy;end
        end
        read_addr=address(x,y,dx,dy,width,height);
        // Registered Sobel lobes -> signed differences -> absolute values ->
        // Q8 direction products. Products and magnitudes belong to this pixel.
        if({ay,8'b0}<={1'b0,ax106})direction=0;
        else if({ax,8'b0}<={1'b0,ay106})direction=2;
        else if((gx<0)==(gy<0))direction=1;else direction=3;
        gaussian=taps[0]+2*taps[1]+taps[2]+2*taps[3]+4*taps[4]+2*taps[5]+taps[6]+2*taps[7]+taps[8];
        if(center_mag==0 || center_mag<neighbor0 || center_mag<neighbor1)classification=0;
        else if(center_mag>=high)classification=2;
        else if(center_mag>=low)classification=1;else classification=0;
    end
    always @(posedge clk) if(rst_n && clk_en) begin
        if(state==LOAD && s_valid && s_ready)raw_mem[count]<=s_data;
        if(state==BR)raw_q<=raw_mem[read_addr];
        if(state==BW)blur_mem[count]<=(gaussian+8)>>4;
        if(state==GR)blur_q<=blur_mem[read_addr];
        if(state==GW)gradient_mem[count]<={direction,magnitude[MW-1:0]};
        if(state==NR || state==NNR)grad_q<=gradient_mem[read_addr];
        if(state==NW)label_mem[count]<=classification;
        if(state==HR || state==HNR || state==ORQ)label_q<=label_mem[read_addr];
        if(state==HW && promote)label_mem[count]<=2;
    end
    task advance_pixel;
        input [4:0] next_state;
        begin
            if(x==width-1)begin x<=0;y<=y+1;end else x<=x+1;
            count<=count+1;tap<=0;state<=next_state;
        end
    endtask
    integer k;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n)begin
            state<=IDLE;width<=0;height<=0;low<=0;high<=0;tag<=0;frame_error<=0;
            response_valid<=0;output_valid<=0;output_data<=0;output_sof<=0;output_eol<=0;
            count<=0;x<=0;y<=0;tap<=0;scans<=0;changed<=0;promote<=0;
            center_label<=0;center_mag<=0;center_direction<=0;neighbor0<=0;neighbor1<=0;
            xpos<=0;xneg<=0;ypos<=0;yneg<=0;gx<=0;gy<=0;
            ax<=0;ay<=0;ax106<=0;ay106<=0;magnitude<=0;
            for(k=0;k<9;k=k+1)taps[k]<=0;
        end else if(clk_en)begin
            if(response_valid && rsp_ready)response_valid<=0;
            if(output_valid && m_ready)output_valid<=0;
            case(state)
              IDLE:if(cmd_valid && cmd_ready)begin
                  tag<=cmd_tag;frame_error<=0;count<=0;x<=0;y<=0;tap<=0;scans<=0;
                  if(cfg_width==0 || cfg_height==0 || cfg_width>MAX_WIDTH || cfg_height>MAX_HEIGHT ||
                     cfg_low>cfg_high || PIXEL_W>12 || PIXEL_W<1)begin frame_error<=1;response_valid<=1;end
                  else begin width<=cfg_width;height<=cfg_height;low<=cfg_low;high<=cfg_high;state<=LOAD;end
              end
              LOAD:if(s_valid && s_ready)begin
                  if(s_sof!= (count==0) || s_eol!=(x==width-1))frame_error[1]<=1;
                  if(count==width*height-1)begin count<=0;x<=0;y<=0;tap<=0;state<=BR;end
                  else advance_pixel(LOAD);
              end
              BR:state<=BC;
              BC:begin taps[tap]<=raw_q;if(tap==8)state<=BW;else begin tap<=tap+1;state<=BR;end end
              BW:if(count==width*height-1)begin count<=0;x<=0;y<=0;tap<=0;state<=GR;end else advance_pixel(BR);
              GR:state<=GC;
              GC:begin taps[tap]<=blur_q;if(tap==8)state<=GSUM;else begin tap<=tap+1;state<=GR;end end
              GSUM:begin
                  xpos<={2'b0,taps[2]}+({2'b0,taps[5]}<<1)+{2'b0,taps[8]};
                  xneg<={2'b0,taps[0]}+({2'b0,taps[3]}<<1)+{2'b0,taps[6]};
                  ypos<={2'b0,taps[6]}+({2'b0,taps[7]}<<1)+{2'b0,taps[8]};
                  yneg<={2'b0,taps[0]}+({2'b0,taps[1]}<<1)+{2'b0,taps[2]};
                  state<=GDIFF;
              end
              GDIFF:begin
                  gx<=$signed({1'b0,xpos})-$signed({1'b0,xneg});
                  gy<=$signed({1'b0,ypos})-$signed({1'b0,yneg});state<=GABS;
              end
              GABS:begin ax<=(gx<0)?-gx:gx;ay<=(gy<0)?-gy:gy;state<=GSCALE;end
              GSCALE:begin ax106<=ax*106;ay106<=ay*106;magnitude<=ax+ay;state<=GW;end
              GW:if(count==width*height-1)begin count<=0;x<=0;y<=0;tap<=0;state<=NR;end else advance_pixel(GR);
              NR:state<=NC;
              NC:begin center_mag<=grad_q[MW-1:0];center_direction<=grad_q[MW+1:MW];tap<=0;state<=NNR;end
              NNR:state<=NNC;
              NNC:begin
                  if(tap==0)begin neighbor0<=grad_q[MW-1:0];tap<=1;state<=NNR;end
                  else begin neighbor1<=grad_q[MW-1:0];state<=NW;end
              end
              NW:if(count==width*height-1)begin count<=0;x<=0;y<=0;tap<=0;changed<=0;state<=HR;end else advance_pixel(NR);
              HR:state<=HC;
              HC:begin
                  center_label<=label_q;promote<=0;tap<=0;
                  if(label_q==1)state<=HNR;else state<=HW;
              end
              HNR:state<=HNC;
              HNC:begin
                  if(label_q==2)promote<=1;
                  if(tap==7)state<=HW;else begin tap<=tap+1;state<=HNR;end
              end
              HW:begin
                  if(promote)changed<=1;
                  if(count==width*height-1)begin
                      count<=0;x<=0;y<=0;tap<=0;
                      if(changed || promote)begin
                          if(scans>=width*height)begin frame_error[2]<=1;state<=ORQ;end
                          else begin scans<=scans+1;changed<=0;state<=HR;end
                      end else state<=ORQ;
                  end else advance_pixel(HR);
              end
              ORQ:state<=OC;
              OC:begin
                  output_data<=(label_q==2)?{PIXEL_W{1'b1}}:0;
                  output_sof<=(count==0);output_eol<=(x==width-1);output_valid<=1;state<=OSEND;
              end
              OSEND:if(output_valid && m_ready)begin
                  if(count==width*height-1)begin response_valid<=1;state<=IDLE;end
                  else advance_pixel(ORQ);
              end
              default:begin frame_error<=8'h80;response_valid<=1;state<=IDLE;end
            endcase
        end
    end
endmodule
