// Strict canonical row coverage checker and binary run expander.
module binary_rle_decoder #(parameter WIDTH=32,HEIGHT=32)(
 input wire clk,rst,ce,
 input wire s_value,s_valid,s_sof,s_eol,s_last,
 input wire[((WIDTH<2)?1:$clog2(WIDTH))-1:0] s_start_x,
 input wire[((HEIGHT<2)?1:$clog2(HEIGHT))-1:0] s_y,
 input wire[$clog2(WIDTH+1)-1:0] s_length,output wire s_ready,
 output wire m_valid,input wire m_ready,output wire m_value,
 output wire[((WIDTH<2)?1:$clog2(WIDTH))-1:0] m_x,
 output wire[((HEIGHT<2)?1:$clog2(HEIGHT))-1:0] m_y,
 output wire m_sof,m_eol,m_last,
 output wire done_valid,input wire done_ready,output reg[5:0] error,output wire busy
);
 localparam XW=WIDTH<2?1:$clog2(WIDTH),YW=HEIGHT<2?1:$clog2(HEIGHT),LW=$clog2(WIDTH+1);
 localparam TOKEN=0,EXPAND=1,DONE=2;
 reg[1:0] state;
 reg[XW-1:0] expected_x,x;
 reg[YW-1:0] expected_y,y;
 reg[LW-1:0] remaining;
 reg value,token_eol,token_last,previous_value,previous_valid;
 wire[LW:0] token_end={1'b0,s_start_x}+{1'b0,s_length};
 wire expected_eol=token_end==WIDTH;
 wire expected_last=expected_eol&&s_y==HEIGHT-1;
 wire[5:0] token_error={previous_valid&&s_value==previous_value,
                       s_start_x>=WIDTH||s_y>=HEIGHT,
                       s_sof!=(s_start_x==0&&s_y==0)||s_eol!=expected_eol||s_last!=expected_last,
                       token_end>WIDTH,
                       s_start_x!=expected_x||s_y!=expected_y,
                       s_length==0};
 assign s_ready=!rst&&ce&&state==TOKEN;
 assign m_valid=!rst&&state==EXPAND;
 assign m_value=value;assign m_x=x;assign m_y=y;
 assign m_sof=m_valid&&x==0&&y==0;assign m_eol=m_valid&&x==WIDTH-1;assign m_last=m_eol&&y==HEIGHT-1;
 assign done_valid=!rst&&state==DONE;
 assign busy=state!=TOKEN||expected_x!=0||expected_y!=0;
 initial if(WIDTH<1||HEIGHT<1||WIDTH>65535||HEIGHT>65535)$fatal(1,"invalid binary RLE geometry");
 always @(posedge clk)begin
 if(rst)begin
 state<=TOKEN;expected_x<=0;expected_y<=0;x<=0;y<=0;remaining<=0;value<=0;token_eol<=0;token_last<=0;previous_value<=0;previous_valid<=0;error<=0;
 end else if(ce)case(state)
 TOKEN:if(s_valid&&s_ready)begin
 if(token_error!=0)begin error<=token_error;state<=DONE;end
 else begin value<=s_value;x<=s_start_x;y<=s_y;remaining<=s_length;token_eol<=expected_eol;token_last<=expected_last;state<=EXPAND;end
 end
 EXPAND:if(m_ready)begin
 if(remaining==1)begin
 if(token_eol)begin expected_x<=0;expected_y<=expected_y+1'b1;previous_valid<=0;end
 else begin expected_x<=x+1'b1;previous_value<=value;previous_valid<=1;end
 if(token_last)state<=DONE;else state<=TOKEN;
 end else begin remaining<=remaining-1'b1;x<=x+1'b1;end
 end
 DONE:if(done_ready)begin state<=TOKEN;expected_x<=0;expected_y<=0;previous_valid<=0;error<=0;end
 default:state<=TOKEN;
 endcase
 end
endmodule
