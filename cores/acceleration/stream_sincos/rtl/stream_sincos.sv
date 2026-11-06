// Iterative full-circle fixed-point sine/cosine, binary-turn phase input.
module stream_sincos #(
 parameter PHASE_W=24,OUT_W=18,ITER=20,TAG_W=16
)(
 input wire clk,rst,s_valid,output wire s_ready,
 input wire [PHASE_W-1:0] s_phase,input wire [TAG_W-1:0] s_tag,
 output wire m_valid,input wire m_ready,
 output reg signed [OUT_W-1:0] m_cos,m_sin,output reg [TAG_W-1:0] m_tag
);
 localparam GUARD=8,IW=OUT_W+GUARD;
 localparam AW=((PHASE_W>OUT_W)?PHASE_W:OUT_W)+GUARD;
 localparam INDEX_W=(ITER<=2)?1:$clog2(ITER);
 localparam IDLE=2'd0,ROTATE=2'd1,FINISH=2'd2;
 // BEGIN_GENERATED_CONSTANTS
 function [63:0] atan_q62;
  input integer index;
  begin case(index)
    0: atan_q62=64'd576460752303423488;
    1: atan_q62=64'd340304653033718298;
    2: atan_q62=64'd179807632645220259;
    3: atan_q62=64'd91273161881380487;
    4: atan_q62=64'd45813697873323707;
    5: atan_q62=64'd22929182573009054;
    6: atan_q62=64'd11467389120678282;
    7: atan_q62=64'd5734044481687724;
    8: atan_q62=64'd2867065987018958;
    9: atan_q62=64'd1433538461969102;
    10: atan_q62=64'd716769914547871;
    11: atan_q62=64'd358385042719534;
    12: atan_q62=64'd179192532040472;
    13: atan_q62=64'd89596267355325;
    14: atan_q62=64'd44798133844548;
    15: atan_q62=64'd22399066943135;
    16: atan_q62=64'd11199533474175;
    17: atan_q62=64'd5599766737413;
    18: atan_q62=64'd2799883368747;
    19: atan_q62=64'd1399941684379;
    20: atan_q62=64'd699970842190;
    21: atan_q62=64'd349985421095;
    22: atan_q62=64'd174992710548;
    23: atan_q62=64'd87496355274;
    24: atan_q62=64'd43748177637;
    25: atan_q62=64'd21874088818;
    26: atan_q62=64'd10937044409;
    27: atan_q62=64'd5468522205;
    28: atan_q62=64'd2734261102;
    29: atan_q62=64'd1367130551;
    default: atan_q62=64'd0;
   endcase end
 endfunction
 function [63:0] inverse_gain_q62;
  input integer count;
  begin case(count)
    4: inverse_gain_q62=64'd2807750841902562267;
    5: inverse_gain_q62=64'd2802282967498353433;
    6: inverse_gain_q62=64'd2800915666627739259;
    7: inverse_gain_q62=64'd2800573820569637254;
    8: inverse_gain_q62=64'd2800488357751430639;
    9: inverse_gain_q62=64'd2800466991965380887;
    10: inverse_gain_q62=64'd2800461650513774536;
    11: inverse_gain_q62=64'd2800460315150554575;
    12: inverse_gain_q62=64'd2800459981309729686;
    13: inverse_gain_q62=64'd2800459897849522220;
    14: inverse_gain_q62=64'd2800459876984470276;
    15: inverse_gain_q62=64'd2800459871768207285;
    16: inverse_gain_q62=64'd2800459870464141537;
    17: inverse_gain_q62=64'd2800459870138125100;
    18: inverse_gain_q62=64'd2800459870056620990;
    19: inverse_gain_q62=64'd2800459870036244963;
    20: inverse_gain_q62=64'd2800459870031150956;
    21: inverse_gain_q62=64'd2800459870029877455;
    22: inverse_gain_q62=64'd2800459870029559079;
    23: inverse_gain_q62=64'd2800459870029479485;
    24: inverse_gain_q62=64'd2800459870029459587;
    25: inverse_gain_q62=64'd2800459870029454612;
    26: inverse_gain_q62=64'd2800459870029453369;
    27: inverse_gain_q62=64'd2800459870029453058;
    28: inverse_gain_q62=64'd2800459870029452980;
    29: inverse_gain_q62=64'd2800459870029452960;
    30: inverse_gain_q62=64'd2800459870029452956;
    default: inverse_gain_q62=64'd0;
   endcase end
 endfunction
 // END_GENERATED_CONSTANTS
 localparam [63:0] GAIN_ROUND=64'd1<<(61-(OUT_W+6));
 localparam signed [IW-1:0] X_INITIAL=(inverse_gain_q62(ITER)+GAIN_ROUND)>>(62-(OUT_W+6));
 function signed [AW-1:0] angle;
  input [INDEX_W-1:0] index;reg [63:0] rounded;
  begin rounded=atan_q62(index)+(64'd1<<(61-AW));angle=rounded>>(62-AW);end
 endfunction
 function signed [OUT_W-1:0] nearest_even;
  input signed [IW-1:0] value;reg signed [IW-1:0] floor_value;
  begin
   floor_value=value>>>GUARD;
   if(value[GUARD-1]&&((|value[GUARD-2:0])||value[GUARD]))floor_value=floor_value+1'b1;
   nearest_even=floor_value[OUT_W-1:0];
  end
 endfunction
 reg [1:0] state,quadrant;
 reg [INDEX_W-1:0] index;
 reg signed [IW-1:0] x,y;
 reg signed [AW-1:0] z;
 reg [TAG_W-1:0] tag;
 reg out_valid;
 wire signed [IW-1:0] x_shift=x>>>index,y_shift=y>>>index;
 wire signed [IW-1:0] next_x=z[AW-1] ? x+y_shift : x-y_shift;
 wire signed [IW-1:0] next_y=z[AW-1] ? y-x_shift : y+x_shift;
 wire signed [AW-1:0] next_z=z[AW-1] ? z+angle(index) : z-angle(index);
 wire signed [OUT_W-1:0] rounded_x=nearest_even(x),rounded_y=nearest_even(y);
 assign s_ready=!rst&&(state==IDLE)&&(!out_valid||m_ready);
 assign m_valid=!rst&&out_valid;
 always @(posedge clk)begin
  if(rst)begin state<=IDLE;out_valid<=1'b0;end
  else begin
   if(out_valid&&m_ready)out_valid<=1'b0;
   case(state)
    IDLE:if(s_valid&&s_ready)begin
     x<=X_INITIAL;y<=0;
     z<=$signed({2'b00,s_phase[PHASE_W-3:0],{(AW-PHASE_W){1'b0}}});
     quadrant<=s_phase[PHASE_W-1:PHASE_W-2];tag<=s_tag;index<=0;state<=ROTATE;
    end
    ROTATE:begin
     x<=next_x;y<=next_y;z<=next_z;
     if(index==ITER-1)state<=FINISH;else index<=index+1'b1;
    end
    FINISH:begin
     case(quadrant)
      2'd0:begin m_cos<=rounded_x;m_sin<=rounded_y;end
      2'd1:begin m_cos<=-rounded_y;m_sin<=rounded_x;end
      2'd2:begin m_cos<=-rounded_x;m_sin<=-rounded_y;end
      2'd3:begin m_cos<=rounded_y;m_sin<=-rounded_x;end
     endcase
     m_tag<=tag;out_valid<=1'b1;state<=IDLE;
    end
   endcase
  end
 end
endmodule
