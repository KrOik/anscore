// Bounded-frame synchronous-memory engine.
// OP=0: grayscale 3x3 opening; OP=1: closing; OP=2: patch-distance NLM.
// NLM uses exp(-mean_patch_SSD/h^2) with a Q0.16 exponential LUT (step 1/16).
// Replicate border for every pass; no host replay or external window required.
module img_filter_nlm_serial_engine #(
    parameter PIXEL_W=8,parameter MAX_WIDTH=64,parameter MAX_HEIGHT=64,
    parameter OP=0,parameter MAX_PATCH_RADIUS=1,parameter MAX_SEARCH_RADIUS=3
)(
    input wire clk,rst_n,clk_en,
    input wire cmd_valid,output wire cmd_ready,input wire [7:0] cmd_tag,
    input wire [15:0] cfg_width,cfg_height,
    input wire [8:0] cfg_structuring_element,
    input wire [7:0] cfg_patch_radius,cfg_search_radius,
    input wire [PIXEL_W+7:0] cfg_h_q8,
    output wire rsp_valid,input wire rsp_ready,output wire [7:0] rsp_tag,rsp_error,
    input wire [PIXEL_W-1:0] s_data,input wire s_valid,s_sof,s_eol,output wire s_ready,
    output wire [PIXEL_W-1:0] m_data,output wire m_valid,m_sof,m_eol,input wire m_ready
);
localparam N=MAX_WIDTH*MAX_HEIGHT;
localparam IDLE=0,LOAD=1,MR=2,MC=3,MW=4,NR=5,NR1=6,NC=7,NWEIGHT=8,NFINISH=9,SEND=10,NDIV=11,NACC=12,NOUT=13;
reg [3:0] state;
reg [15:0] width,height;
reg [8:0] se;
reg [PIXEL_W+7:0] h;
reg [7:0] tag,error_code;
reg response_valid,out_valid,out_sof,out_eol,second_pass;
reg [PIXEL_W-1:0] out_data,extreme,raw_q0,raw_rdata,tmp_q,candidate;
reg [63:0] ssd,weighted_sum,weight_sum;
integer count,x,y,tap,pr,sr,px,py,cx,cy,raw_addr,tmp_addr,difference;
(* ram_style="block" *) reg [PIXEL_W-1:0] raw[0:N-1];
(* ram_style="block" *) reg [PIXEL_W-1:0] temporary[0:N-1];
wire maximum_pass=(OP==0)?second_pass:!second_pass;
wire [PIXEL_W-1:0] morph_sample=second_pass?tmp_q:raw_rdata;
wire [63:0] patch_size=(2*pr+1)*(2*pr+1);
wire [63:0] h_squared=h*h;
// Shared exact unsigned restoring divider. All numerators retain the
// original 64-bit wrap, including ssd << 20 and rounded normalization.
reg [63:0] div_quotient,div_denominator,div_remainder;
reg [6:0] div_remaining;
reg div_normalize;
wire [64:0] div_trial={div_remainder,div_quotient[63]};
wire div_take=div_trial>={1'b0,div_denominator};
wire [63:0] div_next_q={div_quotient[62:0],div_take};
wire [63:0] index_wide=div_quotient;
wire [7:0] weight_index=(index_wide>255)?255:index_wide[7:0];
wire [15:0] candidate_weight;
wire [63:0] norm_result=div_quotient;
// Finish signed squaring at its native width before unsigned accumulation.
// Unsigned 64-bit context would zero-extend a negative 32-bit difference.
wire [31:0] squared_difference=difference*difference;
img_filter_exp_weight weights(.index(weight_index),.weight(candidate_weight));
assign cmd_ready=rst_n && clk_en && state==IDLE && !response_valid;
assign s_ready=rst_n && clk_en && state==LOAD;
assign rsp_valid=response_valid;assign rsp_tag=tag;assign rsp_error=error_code;
assign m_data=out_data;assign m_valid=out_valid;assign m_sof=out_sof;assign m_eol=out_eol;
function integer address;
    input integer xx,yy,w,hh;
    integer ax,ay;
    begin ax=xx;ay=yy;if(ax<0)ax=0;else if(ax>=w)ax=w-1;
      if(ay<0)ay=0;else if(ay>=hh)ay=hh-1;address=ay*w+ax;end
endfunction
always @* begin
    raw_addr=count;tmp_addr=count;
    difference=$signed({1'b0,raw_q0})-$signed({1'b0,raw_rdata});
    // Erosion samples x+b; dilation samples x-b (reflected SE). This also
    // gives proper opening/closing for nonsymmetric structuring elements.
    if(state==MR)begin
        if(second_pass)
            tmp_addr=maximum_pass?
                address(x-((tap%3)-1),y-((tap/3)-1),width,height):
                address(x+(tap%3)-1,y+(tap/3)-1,width,height);
        else
            raw_addr=maximum_pass?
                address(x-((tap%3)-1),y-((tap/3)-1),width,height):
                address(x+(tap%3)-1,y+(tap/3)-1,width,height);
    end
    // The frame RAM has one synchronous read address. NLM reads the source
    // and search-patch pixels in adjacent states; NR1 preserves the first
    // result while the second read is issued.
    if(state==NR)raw_addr=address(x+px,y+py,width,height);
    if(state==NR1)raw_addr=address(x+cx+px,y+cy+py,width,height);
end
always @(posedge clk) if(rst_n && clk_en)begin
    if(state==LOAD && s_valid && s_ready)raw[count]<=s_data;
    if((state==MR && !second_pass) || state==NR || state==NR1)
        raw_rdata<=raw[raw_addr];
    if(state==MR && second_pass)tmp_q<=temporary[tmp_addr];
    if(state==MW && !second_pass)temporary[count]<=extreme;
    if(state==NR1)raw_q0<=raw_rdata;
end
task reset_neighborhood;
begin
    tap<=0;extreme<=maximum_pass?0:{PIXEL_W{1'b1}};
    cx<=-sr;cy<=-sr;px<=-pr;py<=-pr;ssd<=0;weighted_sum<=0;weight_sum<=0;
end
endtask
task advance;
    input [3:0] ns;
    begin count<=count+1;if(x==width-1)begin x<=0;y<=y+1;end else x<=x+1;state<=ns;end
endtask
always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
        div_quotient<=0;div_denominator<=0;div_remainder<=0;div_remaining<=0;div_normalize<=0;
        state<=IDLE;width<=0;height<=0;se<=0;h<=0;tag<=0;error_code<=0;
        response_valid<=0;out_valid<=0;out_data<=0;out_sof<=0;out_eol<=0;second_pass<=0;
        extreme<=0;candidate<=0;ssd<=0;weighted_sum<=0;weight_sum<=0;
        count<=0;x<=0;y<=0;tap<=0;pr<=0;sr<=0;px<=0;py<=0;cx<=0;cy<=0;
    end else if(clk_en)begin
        if(response_valid && rsp_ready)response_valid<=0;
        if(out_valid && m_ready)out_valid<=0;
        case(state)
          IDLE:if(cmd_valid && cmd_ready)begin
              tag<=cmd_tag;error_code<=0;count<=0;x<=0;y<=0;second_pass<=0;
              if(cfg_width==0 || cfg_height==0 || cfg_width>MAX_WIDTH || cfg_height>MAX_HEIGHT ||
                 OP<0 || OP>2 || PIXEL_W<1 || PIXEL_W>12 ||
                 (OP!=2 && cfg_structuring_element==0) ||
                 (OP==2 && (cfg_h_q8==0 || cfg_patch_radius>MAX_PATCH_RADIUS || cfg_search_radius>MAX_SEARCH_RADIUS)))begin
                  error_code<=1;response_valid<=1;
              end else begin
                  width<=cfg_width;height<=cfg_height;se<=cfg_structuring_element;
                  h<=cfg_h_q8;pr<=cfg_patch_radius;sr<=cfg_search_radius;state<=LOAD;
              end
          end
          LOAD:if(s_valid && s_ready)begin
              if(s_sof!=(count==0) || s_eol!=(x==width-1))error_code[1]<=1;
              if(count==width*height-1)begin
                  count<=0;x<=0;y<=0;tap<=0;
                  extreme<=(OP==1)?0:{PIXEL_W{1'b1}};
                  cx<=-sr;cy<=-sr;px<=-pr;py<=-pr;ssd<=0;weighted_sum<=0;weight_sum<=0;
                  state<=(OP==2)?NR:MR;
              end else advance(LOAD);
          end
          MR:state<=MC;
          MC:begin
              if(se[tap] && (maximum_pass?(morph_sample>extreme):(morph_sample<extreme)))extreme<=morph_sample;
              if(tap==8)state<=MW;else begin tap<=tap+1;state<=MR;end
          end
          MW:begin
              if(!second_pass)begin
                  // A complete intermediate frame is produced before pass two.
                  if(count==width*height-1)begin
                      second_pass<=1;count<=0;x<=0;y<=0;tap<=0;
                      extreme<=(OP==0)?0:{PIXEL_W{1'b1}};state<=MR;
                  end else begin
                      extreme<=(OP==1)?0:{PIXEL_W{1'b1}};tap<=0;advance(MR);
                  end
              end else begin out_data<=extreme;out_valid<=1;out_sof<=(count==0);out_eol<=(x==width-1);state<=SEND;end
          end
          NR:state<=NR1;
          NR1:state<=NC;
          NC:begin
              ssd<=ssd+squared_difference;
              if(px==0 && py==0)candidate<=raw_rdata;
              if(px==pr && py==pr)state<=NWEIGHT;
              else begin if(px==pr)begin px<=-pr;py<=py+1;end else px<=px+1;state<=NR;end
          end
          NWEIGHT:begin
              div_quotient<=ssd<<20;div_denominator<=patch_size*h_squared;
              div_remainder<=0;div_remaining<=64;div_normalize<=0;
              if(h_squared==0)begin div_quotient<=0;state<=NACC;end
              else state<=NDIV;
          end
          NDIV:begin
              div_quotient<=div_next_q;
              div_remainder<=div_take?(div_trial-{1'b0,div_denominator}):div_trial;
              div_remaining<=div_remaining-1;
              if(div_remaining==1)state<=div_normalize?NOUT:NACC;
          end
          NACC:begin
              weighted_sum<=weighted_sum+candidate_weight*candidate;
              weight_sum<=weight_sum+candidate_weight;
              if(cx==sr && cy==sr)state<=NFINISH;
              else begin
                  if(cx==sr)begin cx<=-sr;cy<=cy+1;end else cx<=cx+1;
                  px<=-pr;py<=-pr;ssd<=0;state<=NR;
              end
          end
          NFINISH:begin
              div_quotient<=weighted_sum+(weight_sum>>1);div_denominator<=weight_sum;
              div_remainder<=0;div_remaining<=64;div_normalize<=1;
              if(weight_sum==0)begin div_quotient<=0;state<=NOUT;end
              else state<=NDIV;
          end
          NOUT:begin
              out_data<=(norm_result>{PIXEL_W{1'b1}})?{PIXEL_W{1'b1}}:norm_result[PIXEL_W-1:0];
              out_valid<=1;out_sof<=(count==0);out_eol<=(x==width-1);state<=SEND;
          end
          SEND:if(out_valid && m_ready)begin
              if(count==width*height-1)begin response_valid<=1;state<=IDLE;end
              else begin
                  advance((OP==2)?NR:MR);tap<=0;
                  extreme<=maximum_pass?0:{PIXEL_W{1'b1}};
                  cx<=-sr;cy<=-sr;px<=-pr;py<=-pr;ssd<=0;weighted_sum<=0;weight_sum<=0;
              end
          end
          default:begin error_code<=8'h80;response_valid<=1;state<=IDLE;end
        endcase
    end
end
endmodule
