// Full-circle signed integer vector angle, binary-turn output modulo one turn.
module stream_atan2 #(
 parameter integer IN_W=16,PHASE_W=24,ITER=24,TAG_W=16
)(
 input wire clk,rst,s_valid,output wire s_ready,
 input wire signed [IN_W-1:0] s_x,s_y,input wire s_last,input wire [TAG_W-1:0] s_tag,
 output wire m_valid,input wire m_ready,
 output reg [PHASE_W-1:0] m_phase,output reg m_zero,m_last,output reg [TAG_W-1:0] m_tag
);
 localparam integer GUARD=PHASE_W+8,IW=IN_W+GUARD+2,AW=PHASE_W+8;
 localparam integer INDEX_W=$clog2(ITER);
 localparam [1:0] IDLE=0,VECTOR=1,FINISH=2;
 localparam [PHASE_W-1:0] HALF={1'b1,{(PHASE_W-1){1'b0}}};
 localparam [PHASE_W-1:0] QUARTER={2'b01,{(PHASE_W-2){1'b0}}};
 // BEGIN_GENERATED_CONSTANTS
 function [63:0] atan_q62;
  input integer position;
  begin case(position)
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
 // END_GENERATED_CONSTANTS
 function signed [AW-1:0] angle;
  input [INDEX_W-1:0] position;reg [63:0] rounded;
  begin rounded=atan_q62(position)+(64'd1<<(61-AW));angle=rounded>>(62-AW);end
 endfunction
 function [PHASE_W-1:0] nearest_even;
  input signed [AW-1:0] value;reg signed [AW-1:0] floor_value;
  begin
   floor_value=value>>>8;
   if(value[7]&&((|value[6:0])||value[8]))floor_value=floor_value+1'b1;
   nearest_even=floor_value[PHASE_W-1:0];
  end
 endfunction
 wire signed [IW-1:0] input_x=$signed({{2{s_x[IN_W-1]}},s_x,{GUARD{1'b0}}});
 wire signed [IW-1:0] input_y=$signed({{2{s_y[IN_W-1]}},s_y,{GUARD{1'b0}}});
 reg [1:0] state;
 reg [INDEX_W-1:0] index;
 reg signed [IW-1:0] x,y;
 reg signed [AW-1:0] z;
 reg special,zero,last,out_valid;
 reg [PHASE_W-1:0] special_phase;
 reg [TAG_W-1:0] tag;
 wire signed [IW-1:0] x_shift=x>>>index,y_shift=y>>>index;
 // One runtime add/sub carry chain per state component.
 wire [IW-1:0] addend_x=y_shift^{IW{y[IW-1]}};
 wire [IW-1:0] addend_y=x_shift^{IW{!y[IW-1]}};
 wire [AW-1:0] addend_z=angle(index)^{AW{y[IW-1]}};
 wire signed [IW-1:0] next_x=x+addend_x+y[IW-1];
 wire signed [IW-1:0] next_y=y+addend_y+!y[IW-1];
 wire signed [AW-1:0] next_z=z+addend_z+y[IW-1];
 assign s_ready=!rst&&(state==IDLE)&&(!out_valid||m_ready);
 assign m_valid=!rst&&out_valid;
 always @(posedge clk)begin
  if(rst)begin state<=IDLE;out_valid<=0;end
  else begin
   if(out_valid&&m_ready)out_valid<=0;
   case(state)
    IDLE:if(s_valid&&s_ready)begin
     // Negate after extension: the signed minimum input is representable.
     x<=s_x[IN_W-1] ? -input_x : input_x;
     y<=s_x[IN_W-1] ? -input_y : input_y;
     z<=s_x[IN_W-1] ? {1'b1,{(AW-1){1'b0}}} : {AW{1'b0}};
     special<=(s_x==0)||(s_y==0);zero<=(s_x==0)&&(s_y==0);
     special_phase<=(s_y==0) ? (s_x[IN_W-1] ? HALF : 0) : (s_y[IN_W-1] ? -QUARTER : QUARTER);
     last<=s_last;tag<=s_tag;index<=0;state<=VECTOR;
    end
    VECTOR:begin
     // Freeze exact y=0 rather than injecting an unnecessary signed rotation.
     if(y!=0)begin x<=next_x;y<=next_y;z<=next_z;end
     if(index==ITER-1)state<=FINISH;else index<=index+1'b1;
    end
    FINISH:begin
     m_phase<=special ? special_phase : nearest_even(z);
     m_zero<=zero;m_last<=last;m_tag<=tag;out_valid<=1;state<=IDLE;
    end
   endcase
  end
 end
 initial begin
  if(IN_W<2||IN_W>32||PHASE_W<8||PHASE_W>32||ITER<4||ITER>30||TAG_W<1)$fatal(1,"illegal parameters");
 end
endmodule
