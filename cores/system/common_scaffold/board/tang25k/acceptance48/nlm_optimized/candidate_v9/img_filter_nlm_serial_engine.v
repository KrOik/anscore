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
localparam IDLE=0,LOAD=1,MR=2,MC=3,MW=4,NR=5,NR1=6,NC=7,NWEIGHT=8,NFINISH=9,SEND=10,NDIV=11,NACC=12,NOUT=13,NPOS=14,NCLAMP=15,NADDR=16,NMUL=17,NDIVWORD=18,NPRODUCT=19,NCACC=20,NINDEXCHECK=21,NROUND=22,NNORMCHECK=23,NLOOKUP=24,NCOMBINE=25,NJOIN=26,NACCLO=27;
reg [4:0] state;
localparam CW=(MAX_WIDTH<2)?1:$clog2(MAX_WIDTH+1);
localparam HW=(MAX_HEIGHT<2)?1:$clog2(MAX_HEIGHT+1);
reg [CW-1:0] width;
reg [HW-1:0] height;
reg signed [17:0] source_x,source_y,search_x,search_y;
reg [CW-1:0] source_ax,search_ax;
reg [HW-1:0] source_ay,search_ay;
reg [31:0] source_address,search_address;
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
reg [63:0] denominator,mul_a,mul_b,mul_acc;
reg [6:0] mul_remaining;
reg mul_patch;
reg [1:0] mul_word;
reg mul_carry;
wire [15:0] mul_acc_word=mul_acc>>(mul_word*16);
wire [15:0] mul_a_word=mul_a>>(mul_word*16);
wire [16:0] mul_word_sum={1'b0,mul_acc_word}+{1'b0,(mul_b[0]?mul_a_word:16'b0)}+((mul_word==0)?1'b0:mul_carry);
wire [63:0] mul_final={mul_word_sum[15:0],mul_acc[47:0]};
localparam PATCH_COUNT=(2*((MAX_PATCH_RADIUS>255)?255:MAX_PATCH_RADIUS)+1)*(2*((MAX_PATCH_RADIUS>255)?255:MAX_PATCH_RADIUS)+1);
localparam SEARCH_COUNT=(2*((MAX_SEARCH_RADIUS>255)?255:MAX_SEARCH_RADIUS)+1)*(2*((MAX_SEARCH_RADIUS>255)?255:MAX_SEARCH_RADIUS)+1);
localparam SSD_W=2*PIXEL_W+$clog2(PATCH_COUNT);
localparam SW=16+$clog2(SEARCH_COUNT);
localparam WSW=SW+PIXEL_W;
reg [31:0] square_q;
reg [PIXEL_W+15:0] weighted_product;
reg [15:0] weight_q;
reg [PIXEL_W+3:0] product0,product1,product2,product3;
reg [PIXEL_W+7:0] product_lo,product_hi;
wire [PIXEL_W+7:0] product_lo_next={{4{1'b0}},product0}+({{4{1'b0}},product1}<<4);
wire [PIXEL_W+7:0] product_hi_next={{4{1'b0}},product2}+({{4{1'b0}},product3}<<4);
// Legal samples bound SSD by PATCH_COUNT*(2^PIXEL_W-1)^2.
// At most SEARCH_COUNT weights, each <=65535, bound both sums.
wire [SSD_W-1:0] next_ssd=ssd[SSD_W-1:0]+square_q;
wire [WSW-1:0] next_weighted_sum=weighted_sum[WSW-1:0]+weighted_product;
wire [SW-1:0] next_weight_sum=weight_sum[SW-1:0]+weight_q;
reg [15:0] weighted_low,weight_low;
reg weighted_carry,weight_carry;
wire [16:0] weighted_low_add={1'b0,weighted_sum[15:0]}+{1'b0,weighted_product[15:0]};
wire [16:0] weight_low_add={1'b0,weight_sum[15:0]}+{1'b0,weight_q};
localparam WH=(WSW>16)?WSW-16:1;
localparam SH=(SW>16)?SW-16:1;
wire [WH-1:0] weighted_high_add=(weighted_sum[WSW-1:0]>>16)+(weighted_product>>16)+weighted_carry;
wire [SH-1:0] weight_high_add=(weight_sum[SW-1:0]>>16)+weight_carry;
wire [WSW-1:0] merged_weighted={weighted_high_add,weighted_low};
wire [SW-1:0] merged_weight={weight_high_add,weight_low};
wire [WSW-1:0] rounded_sum=weighted_sum[WSW-1:0]+(weight_sum[SW-1:0]>>1);
// Shared exact unsigned restoring divider. All numerators retain the
// original 64-bit wrap, including ssd << 20 and rounded normalization.
reg [63:0] div_quotient,div_denominator,div_remainder;
reg [6:0] div_remaining;
reg div_normalize;
reg [63:0] div_work_a,div_work_b,div_work_result,div_original_trial;
reg [1:0] div_word;
reg div_borrow,div_overflow;
wire [16:0] div_word_sub={1'b0,div_work_a[15:0]}-{1'b0,div_work_b[15:0]}-div_borrow;
wire [63:0] div_final={div_word_sub[15:0],div_work_result[63:16]};
wire div_accept=div_overflow || !div_word_sub[16];
wire [63:0] index_numerator=ssd<<20;
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
    if(OP!=2 && state==MR)begin
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
    if(state==NR)raw_addr=source_address;
    if(state==NR1)raw_addr=search_address;
end
always @(posedge clk) if(rst_n && clk_en)begin
    if(state==LOAD && s_valid && s_ready)raw[count]<=s_data;
    if((OP!=2 && state==MR && !second_pass) || state==NR || state==NR1)
        raw_rdata<=raw[raw_addr];
    if(OP!=2 && state==MR && second_pass)tmp_q<=temporary[tmp_addr];
    if(OP!=2 && state==MW && !second_pass)temporary[count]<=extreme;
    if(state==NR1)raw_q0<=raw_rdata;
end
task reset_neighborhood;
begin
    tap<=0;extreme<=maximum_pass?0:{PIXEL_W{1'b1}};
    cx<=-sr;cy<=-sr;px<=-pr;py<=-pr;ssd<=0;weighted_sum<=0;weight_sum<=0;
end
endtask
task advance;
    input [4:0] ns;
    begin count<=count+1;if(x==width-1)begin x<=0;y<=y+1;end else x<=x+1;state<=ns;end
endtask
always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
        denominator<=0;mul_a<=0;mul_b<=0;mul_acc<=0;mul_remaining<=0;mul_patch<=0;mul_word<=0;mul_carry<=0;
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
                  if(OP==2)begin
                      mul_a<=h;mul_b<=h;mul_acc<=0;mul_remaining<=64;mul_patch<=0;mul_word<=0;mul_carry<=0;state<=NMUL;
                  end else state<=MR;
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
          NMUL:begin
              mul_acc[mul_word*16+:16]<=mul_word_sum[15:0];mul_carry<=mul_word_sum[16];
              mul_word<=mul_word+1;
              if(mul_word==3)begin
                  mul_a<=mul_a<<1;mul_b<=mul_b>>1;mul_remaining<=mul_remaining-1;
                  if(mul_remaining==1)begin
                      if(!mul_patch)begin
                          mul_a<=mul_final;mul_b<=patch_size;mul_acc<=0;mul_remaining<=64;mul_patch<=1;
                      end else begin denominator<=mul_final;state<=NPOS;end
                  end
              end
          end
          NPOS:begin
              source_x<=x+px;source_y<=y+py;
              search_x<=x+cx+px;search_y<=y+cy+py;state<=NCLAMP;
          end
          NCLAMP:begin
              source_ax<=source_x<0?0:(source_x>=$signed({1'b0,width})?width-1:source_x);
              source_ay<=source_y<0?0:(source_y>=$signed({1'b0,height})?height-1:source_y);
              search_ax<=search_x<0?0:(search_x>=$signed({1'b0,width})?width-1:search_x);
              search_ay<=search_y<0?0:(search_y>=$signed({1'b0,height})?height-1:search_y);
              state<=NADDR;
          end
          NADDR:begin
              source_address<=source_ay*width+source_ax;
              search_address<=search_ay*width+search_ax;state<=NR;
          end
          NR:state<=NR1;
          NR1:state<=NC;
          NC:begin square_q<=squared_difference;state<=NCACC;end
          NCACC:begin
              ssd<=next_ssd;
              if(px==0 && py==0)candidate<=raw_rdata;
              if(px==pr && py==pr)state<=NWEIGHT;
              else begin if(px==pr)begin px<=-pr;py<=py+1;end else px<=px+1;state<=NPOS;end
          end
          NWEIGHT:begin
              div_quotient<={index_numerator[7:0],56'b0};div_denominator<=denominator;
              div_remainder<=index_numerator>>8;div_remaining<=8;div_normalize<=0;
              div_work_a<=index_numerator>>8;div_work_b<=denominator;div_word<=0;div_borrow<=0;
              if(denominator==0)begin div_quotient<=0;state<=NLOOKUP;end
              else state<=NINDEXCHECK;
          end
          NINDEXCHECK:begin
              div_work_a<=div_work_a>>16;div_work_b<=div_work_b>>16;
              div_borrow<=div_word_sub[16];div_word<=div_word+1;
              if(div_word==3)begin
                  if(!div_word_sub[16])begin div_quotient<=255;state<=NLOOKUP;end
                  else state<=NDIV;
              end
          end
          NDIV:begin
              div_original_trial<={div_remainder[62:0],div_quotient[63]};
              div_work_a<={div_remainder[62:0],div_quotient[63]};
              div_work_b<=div_denominator;div_work_result<=0;div_word<=0;
              div_overflow<=div_remainder[63];div_borrow<=0;state<=NDIVWORD;
          end
          NDIVWORD:begin
              div_work_a<=div_work_a>>16;div_work_b<=div_work_b>>16;
              div_work_result<=div_final;div_borrow<=div_word_sub[16];div_word<=div_word+1;
              if(div_word==3)begin
                  div_quotient<={div_quotient[62:0],div_accept};
                  div_remainder<=div_accept?div_final:div_original_trial;
                  div_remaining<=div_remaining-1;
                  if(div_remaining==1)state<=div_normalize?NOUT:NLOOKUP;
                  else state<=NDIV;
              end
          end
          NLOOKUP:begin weight_q<=candidate_weight;state<=NPRODUCT;end
          NPRODUCT:begin
              product0<=weight_q[3:0]*candidate;product1<=weight_q[7:4]*candidate;
              product2<=weight_q[11:8]*candidate;product3<=weight_q[15:12]*candidate;
              state<=NCOMBINE;
          end
          NCOMBINE:begin product_lo<=product_lo_next;product_hi<=product_hi_next;state<=NJOIN;end
          NJOIN:begin
              weighted_product<=({{8{1'b0}},product_lo})+({{8{1'b0}},product_hi}<<8);state<=NACCLO;
          end
          NACCLO:begin
              weighted_low<=weighted_low_add[15:0];weighted_carry<=weighted_low_add[16];
              weight_low<=weight_low_add[15:0];weight_carry<=weight_low_add[16];state<=NACC;
          end
          NACC:begin
              weighted_sum<=merged_weighted;
              weight_sum<=merged_weight;
              if(cx==sr && cy==sr)state<=NFINISH;
              else begin
                  if(cx==sr)begin cx<=-sr;cy<=cy+1;end else cx<=cx+1;
                  px<=-pr;py<=-pr;ssd<=0;state<=NPOS;
              end
          end
          NFINISH:begin
              // Preserve the original full 64-bit rounded-addition wrap.
              mul_acc<=weighted_sum;mul_a<=weight_sum>>1;mul_b<=1;mul_word<=0;mul_carry<=0;
              state<=NROUND;
          end
          NROUND:begin
              mul_acc[mul_word*16+:16]<=mul_word_sum[15:0];mul_carry<=mul_word_sum[16];mul_word<=mul_word+1;
              if(mul_word==3)begin
                  div_quotient<=mul_final<<(64-PIXEL_W);div_denominator<=weight_sum;
                  div_remainder<=mul_final>>PIXEL_W;div_remaining<=PIXEL_W;div_normalize<=1;
                  div_work_a<=mul_final>>PIXEL_W;div_work_b<=weight_sum;div_word<=0;div_borrow<=0;
                  if(weight_sum==0)begin div_quotient<=0;state<=NOUT;end
                  else state<=NNORMCHECK;
              end
          end
          NNORMCHECK:begin
              div_work_a<=div_work_a>>16;div_work_b<=div_work_b>>16;
              div_borrow<=div_word_sub[16];div_word<=div_word+1;
              if(div_word==3)begin
                  if(!div_word_sub[16])begin div_quotient<={PIXEL_W{1'b1}};state<=NOUT;end
                  else state<=NDIV;
              end
          end
          NOUT:begin
              out_data<=(norm_result>{PIXEL_W{1'b1}})?{PIXEL_W{1'b1}}:norm_result[PIXEL_W-1:0];
              out_valid<=1;out_sof<=(count==0);out_eol<=(x==width-1);state<=SEND;
          end
          SEND:if(out_valid && m_ready)begin
              if(count==width*height-1)begin response_valid<=1;state<=IDLE;end
              else begin
                  advance((OP==2)?NPOS:MR);tap<=0;
                  extreme<=maximum_pass?0:{PIXEL_W{1'b1}};
                  cx<=-sr;cy<=-sr;px<=-pr;py<=-pr;ssd<=0;weighted_sum<=0;weight_sum<=0;
              end
          end
          default:begin error_code<=8'h80;response_valid<=1;state<=IDLE;end
        endcase
    end
end
endmodule
