// Four signed three-row frames per depth, clk_en=1. Raw values are checked
// by the independent host oracle. SSF1 / timing error bits / 24 / 48 bytes.
module spatial_sum_probe #(parameter DEPTH=1, FILE="spatial_d1.mem")(
 input wire clk, rst_n, output reg done, output reg error,
 output reg [DEPTH*128-1:0] results);
localparam STEPS=12*(DEPTH+1);
reg [33:0] stimulus[0:STEPS-1];
initial $readmemh(FILE,stimulus);
reg [7:0] tick,received;
wire [33:0] command=tick<STEPS ? stimulus[tick] : 34'b0;
wire ov,nlo;
wire [31:0] value;
reg [3:0] expect_valid;
reg [2:0] expect_marker;
reg [1:0] row;
reg first;
wire last_input=command[33] && row==2;
lprnet_spatial_sum #(.PE_COL_NUM(2),.CYCLE_PERIOD_OUT(1),.IMG_COL(DEPTH),
 .IMG_ROW(3),.DATA_WIDTH(8),.ACC_WIDTH(16)) core(
 .clk(clk),.rst_n(rst_n),.clk_en(1'b1),.new_line_input_1(command[32]),
 .data_input_valid(command[33]),.data_input(command[15:0]),
 .y_out(value),.new_line_out_1(nlo),.output_valid(ov));
always @(posedge clk or negedge rst_n) begin
 if(!rst_n) begin
  tick<=0;received<=0;done<=0;error<=0;results<=0;
  expect_valid<=0;expect_marker<=0;row<=2;first<=0;
 end else if(!done) begin
  tick<=tick+1'b1;
  if(command[32]) begin row<=row==2 ? 0 : row+1'b1; first<=1;end
  if(command[33]) first<=0;
  expect_valid<={expect_valid[2:0],last_input};
  expect_marker<={expect_marker[1:0],last_input && first};
  if(ov!=expect_valid[3] || nlo!=expect_marker[2]) error<=1;
  if(ov) begin
   if(received<4*DEPTH) results[received*32+:32]<=value;else error<=1;
   received<=received+1'b1;
  end
  if(tick==STEPS+6) begin done<=1;if(received!=4*DEPTH) error<=1;end
 end
end
endmodule

module spatial_sum_rate_board #(parameter UART_BAUD=115200)(
 input wire clk, output wire uart_tx, output wire dbg_uart);
reg [12:0] reset_count=0;
wire rst_n=reset_count[12];
always @(posedge clk) if(!rst_n) reset_count<=reset_count+1'b1;
wire done1,done2,error1,error2;
wire [127:0] result1;
wire [255:0] result2;
spatial_sum_probe #(.DEPTH(1),.FILE("spatial_d1.mem")) p1(clk,rst_n,done1,error1,result1);
spatial_sum_probe #(.DEPTH(2),.FILE("spatial_d2.mem")) p2(clk,rst_n,done2,error2,result2);
wire [383:0] results={result2,result1};
reg [2:0] state;
reg [5:0] index;
reg [7:0] tx_data;
reg tx_valid;
wire tx_ready,tx_busy;
uart_tx #(.BAUD_RATE(UART_BAUD)) uart(.clk(clk),.rst_n(rst_n),.tx_data(tx_data),
 .tx_data_valid(tx_valid),.tx_data_ready(tx_ready),.tx_busy(tx_busy),.tx_pin(dbg_uart));
assign uart_tx=dbg_uart;
always @(posedge clk or negedge rst_n) begin
 if(!rst_n) begin state<=0;index<=0;tx_data<=0;tx_valid<=0;end
 else case(state)
  0: if(done1 && done2) state<=1;
  1: begin
   case(index)
    0:tx_data<=8'h53;1:tx_data<=8'h53;2:tx_data<=8'h46;3:tx_data<=8'h31;
    4:tx_data<={6'b0,error2,error1};5:tx_data<=24;
    default:tx_data<=results[(index-6)*8+:8];
   endcase
   state<=2;
  end
  2: if(tx_ready) begin tx_valid<=1;state<=3;end
  3: if(tx_busy) begin tx_valid<=0;index<=index==53 ? 0 : index+1'b1;state<=1;end
 endcase
end
endmodule
