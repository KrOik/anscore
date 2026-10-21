// Reversible single-level integer Haar lifting, d=b-a; s=a+floor(d/2).
module haar2d_lifting #(
 parameter WIDTH=8,HEIGHT=6,PIXEL_BITS=8,COEFF_W=PIXEL_BITS+3
)(
 input wire clk,rst_n,ce,
 input wire cfg_valid,cfg_inverse,output wire cfg_ready,output reg cfg_done,
 input wire signed [COEFF_W-1:0] s_data,input wire s_valid,s_sof,s_eol,output wire s_ready,
 output reg signed [COEFF_W-1:0] m_data,output reg m_valid,m_sof,m_eol,input wire m_ready,
 output wire busy,output reg done,output reg [3:0] error_code
);
 localparam CAP=0,READ_A=1,READ_B=2,CALCULATE=3,WRITE_A=4,WRITE_B=5,OUT_READ=6,OUT_LOAD=7,OUT_HOLD=8;
 reg [3:0] state;reg inverse,pass;
 integer x,y,line,pair_index;
 reg signed [COEFF_W-1:0] mem_a[0:WIDTH*HEIGHT-1],mem_b[0:WIDTH*HEIGHT-1];
 reg signed [COEFF_W-1:0] a,b,result_a,result_b,sample_q;
 wire horizontal=inverse?pass:!pass;
 wire [31:0] dimension=horizontal?WIDTH:HEIGHT;
 wire [31:0] lines=horizontal?HEIGHT:WIDTH;
 wire odd_tail=dimension[0] && pair_index==dimension/2;
 wire [31:0] low_count=(dimension+1)/2;
 wire [31:0] source_a=inverse?pair_index:2*pair_index;
 wire [31:0] source_b=inverse?low_count+pair_index:2*pair_index+1;
 wire [31:0] dest_a=inverse?2*pair_index:pair_index;
 wire [31:0] dest_b=inverse?2*pair_index+1:low_count+pair_index;
 wire [31:0] read_a=horizontal?line*WIDTH+source_a:source_a*WIDTH+line;
 wire [31:0] read_b=horizontal?line*WIDTH+source_b:source_b*WIDTH+line;
 wire [31:0] write_a=horizontal?line*WIDTH+dest_a:dest_a*WIDTH+line;
 wire [31:0] write_b=horizontal?line*WIDTH+dest_b:dest_b*WIDTH+line;
 wire signed [COEFF_W+1:0] ae={{2{a[COEFF_W-1]}},a},be={{2{b[COEFF_W-1]}},b};
 wire signed [COEFF_W+1:0] difference=be-ae;
 wire signed [COEFF_W+1:0] restored_a=ae-(be>>>1);
 wire signed [COEFF_W+1:0] computed_a=odd_tail?ae:(inverse?restored_a:ae+(difference>>>1));
 wire signed [COEFF_W+1:0] computed_b=inverse?be+restored_a:difference;
 wire signed [COEFF_W+1:0] max_coefficient=(1<<(COEFF_W-1))-1;
 wire signed [COEFF_W+1:0] min_coefficient=-(1<<(COEFF_W-1));
 wire signed [COEFF_W-1:0] max_pixel=(1<<(PIXEL_BITS-1))-1;
 wire signed [COEFF_W-1:0] min_pixel=-(1<<(PIXEL_BITS-1));
 wire overflow=computed_a>max_coefficient||computed_a<min_coefficient||
 (!odd_tail&&(computed_b>max_coefficient||computed_b<min_coefficient));
 assign busy=state!=CAP||x!=0||y!=0;
 assign cfg_ready=ce&&!busy;
 assign s_ready=ce&&state==CAP&&!(cfg_valid&&!busy);
 initial if(WIDTH<1||HEIGHT<1||PIXEL_BITS<2||PIXEL_BITS>16||COEFF_W<PIXEL_BITS+2||COEFF_W>24) $fatal(1,"invalid Haar parameters");
 always @(posedge clk) begin
 if(!rst_n) begin
 state<=CAP;inverse<=0;pass<=0;x<=0;y<=0;line<=0;pair_index<=0;
 a<=0;b<=0;result_a<=0;result_b<=0;sample_q<=0;
 cfg_done<=0;m_data<=0;m_valid<=0;m_sof<=0;m_eol<=0;done<=0;error_code<=0;
 end else if(ce) begin
 cfg_done<=0;done<=0;
 if(cfg_valid&&cfg_ready) begin inverse<=cfg_inverse;cfg_done<=1;end
 case(state)
 CAP:if(s_valid&&s_ready) begin
 if(x==0&&y==0) error_code<=0;
 if(s_sof!=(x==0&&y==0)||s_eol!=(x==WIDTH-1)||(!inverse&&(s_data>max_pixel||s_data<min_pixel))) begin
 error_code<=s_sof!=(x==0&&y==0)||s_eol!=(x==WIDTH-1)?4'd1:4'd2;
 x<=0;y<=0;done<=1;state<=CAP;
 end else begin
 mem_a[y*WIDTH+x]<=s_data;
 if(x==WIDTH-1) begin x<=0;
 if(y==HEIGHT-1) begin y<=0;line<=0;pair_index<=0;pass<=0;state<=READ_A;end
 else y<=y+1;
 end else x<=x+1;
 end end
 READ_A:begin a<=pass?mem_b[read_a]:mem_a[read_a];state<=odd_tail?CALCULATE:READ_B;end
 READ_B:begin b<=pass?mem_b[read_b]:mem_a[read_b];state<=CALCULATE;end
 CALCULATE:begin
 if(overflow||(inverse&&pass&&(computed_a>max_pixel||computed_a<min_pixel||(!odd_tail&&(computed_b>max_pixel||computed_b<min_pixel))))) begin error_code<=3;done<=1;state<=CAP;x<=0;y<=0;end
 else begin result_a<=computed_a[COEFF_W-1:0];result_b<=computed_b[COEFF_W-1:0];state<=WRITE_A;end
 end
 WRITE_A:begin
 if(pass) mem_a[write_a]<=result_a;else mem_b[write_a]<=result_a;
 state<=WRITE_B;
 end
 WRITE_B:begin
 if(!odd_tail) begin if(pass) mem_a[write_b]<=result_b;else mem_b[write_b]<=result_b;end
 if(pair_index==(dimension-1)/2) begin pair_index<=0;
 if(line==lines-1) begin line<=0;
 if(pass) begin x<=0;y<=0;state<=OUT_READ;end else begin pass<=1;state<=READ_A;end
 end else begin line<=line+1;state<=READ_A;end
 end else begin pair_index<=pair_index+1;state<=READ_A;end
 end
 OUT_READ:begin sample_q<=mem_a[y*WIDTH+x];state<=OUT_LOAD;end
 OUT_LOAD:begin
 if(inverse&&(sample_q>max_pixel||sample_q<min_pixel)) begin error_code<=3;done<=1;m_valid<=0;x<=0;y<=0;state<=CAP;end
 else begin m_data<=sample_q;m_sof<=x==0&&y==0;m_eol<=x==WIDTH-1;m_valid<=1;state<=OUT_HOLD;end
 end
 OUT_HOLD:if(m_ready) begin m_valid<=0;
 if(x==WIDTH-1) begin x<=0;
 if(y==HEIGHT-1) begin y<=0;state<=CAP;done<=1;end else begin y<=y+1;state<=OUT_READ;end
 end else begin x<=x+1;state<=OUT_READ;end
 end
 endcase
 end end
endmodule
