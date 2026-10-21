module prod_top #(parameter GROUP=0, parameter REPORT_DELAY=25000000)(
    input wire clk, output wire uart_tx, output wire [1:0] led
);
reg [15:0] por=0;
always @(posedge clk) if(!(&por)) por<=por+1'b1;
wire rst_n=&por;
wire done;
wire [7:0] pass_mask;
wire [31:0] errors,count,digest,max_latency,stalled_beats;
generate
if(GROUP==0) begin:g0
prod_board_group_0 st(.clk(clk),.rst_n(rst_n),.done(done),.pass_mask(pass_mask),.errors(errors),.count(count),.digest(digest),.max_latency(max_latency),.stalled_beats(stalled_beats));
end
if(GROUP==1) begin:g1
prod_board_group_1 st(.clk(clk),.rst_n(rst_n),.done(done),.pass_mask(pass_mask),.errors(errors),.count(count),.digest(digest),.max_latency(max_latency),.stalled_beats(stalled_beats));
end
if(GROUP==2) begin:g2
prod_board_group_2 st(.clk(clk),.rst_n(rst_n),.done(done),.pass_mask(pass_mask),.errors(errors),.count(count),.digest(digest),.max_latency(max_latency),.stalled_beats(stalled_beats));
end
if(GROUP==3) begin:g3
prod_board_group_3 st(.clk(clk),.rst_n(rst_n),.done(done),.pass_mask(pass_mask),.errors(errors),.count(count),.digest(digest),.max_latency(max_latency),.stalled_beats(stalled_beats));
end
if(GROUP==4) begin:g4
prod_board_group_4 st(.clk(clk),.rst_n(rst_n),.done(done),.pass_mask(pass_mask),.errors(errors),.count(count),.digest(digest),.max_latency(max_latency),.stalled_beats(stalled_beats));
end
if(GROUP==5) begin:g5
prod_board_group_5 st(.clk(clk),.rst_n(rst_n),.done(done),.pass_mask(pass_mask),.errors(errors),.count(count),.digest(digest),.max_latency(max_latency),.stalled_beats(stalled_beats));
end
if(GROUP==6) begin:g6
prod_board_group_6 st(.clk(clk),.rst_n(rst_n),.done(done),.pass_mask(pass_mask),.errors(errors),.count(count),.digest(digest),.max_latency(max_latency),.stalled_beats(stalled_beats));
end
endgenerate
assign led={(done && errors!=0), (done && pass_mask==255 && errors==0)};
reg [25:0] pace;
reg [6:0] char_index;
reg reporting;
wire tx_ready;
reg [7:0] tx_byte;
prod_uart_tx uart(.clk(clk),.rst_n(rst_n),.data(tx_byte),
    .valid(reporting),.ready(tx_ready),.tx(uart_tx));
function [7:0] hex;
input [3:0] nibble;
begin hex=(nibble<10)?8'd48+{4'd0,nibble}:8'd55+{4'd0,nibble}; end
endfunction
always @* begin
    tx_byte=10;
    case(char_index)
        0: tx_byte=8'd80;
        1: tx_byte=8'd50;
        2: tx_byte=8'd53;
        3: tx_byte=8'd32;
        4: tx_byte=8'd71;
        5: tx_byte=8'd61;
        6: tx_byte=8'd48+GROUP;
        7: tx_byte=8'd32;
        8: tx_byte=8'd77;
        9: tx_byte=8'd61;
        10: tx_byte=hex(pass_mask[4+:4]);
        11: tx_byte=hex(pass_mask[0+:4]);
        12: tx_byte=8'd32;
        13: tx_byte=8'd69;
        14: tx_byte=8'd61;
        15: tx_byte=hex(errors[28+:4]);
        16: tx_byte=hex(errors[24+:4]);
        17: tx_byte=hex(errors[20+:4]);
        18: tx_byte=hex(errors[16+:4]);
        19: tx_byte=hex(errors[12+:4]);
        20: tx_byte=hex(errors[8+:4]);
        21: tx_byte=hex(errors[4+:4]);
        22: tx_byte=hex(errors[0+:4]);
        23: tx_byte=8'd32;
        24: tx_byte=8'd78;
        25: tx_byte=8'd61;
        26: tx_byte=hex(count[28+:4]);
        27: tx_byte=hex(count[24+:4]);
        28: tx_byte=hex(count[20+:4]);
        29: tx_byte=hex(count[16+:4]);
        30: tx_byte=hex(count[12+:4]);
        31: tx_byte=hex(count[8+:4]);
        32: tx_byte=hex(count[4+:4]);
        33: tx_byte=hex(count[0+:4]);
        34: tx_byte=8'd32;
        35: tx_byte=8'd68;
        36: tx_byte=8'd61;
        37: tx_byte=hex(digest[28+:4]);
        38: tx_byte=hex(digest[24+:4]);
        39: tx_byte=hex(digest[20+:4]);
        40: tx_byte=hex(digest[16+:4]);
        41: tx_byte=hex(digest[12+:4]);
        42: tx_byte=hex(digest[8+:4]);
        43: tx_byte=hex(digest[4+:4]);
        44: tx_byte=hex(digest[0+:4]);
        45: tx_byte=8'd32;
        46: tx_byte=8'd76;
        47: tx_byte=8'd61;
        48: tx_byte=hex(max_latency[28+:4]);
        49: tx_byte=hex(max_latency[24+:4]);
        50: tx_byte=hex(max_latency[20+:4]);
        51: tx_byte=hex(max_latency[16+:4]);
        52: tx_byte=hex(max_latency[12+:4]);
        53: tx_byte=hex(max_latency[8+:4]);
        54: tx_byte=hex(max_latency[4+:4]);
        55: tx_byte=hex(max_latency[0+:4]);
        56: tx_byte=8'd32;
        57: tx_byte=8'd83;
        58: tx_byte=8'd61;
        59: tx_byte=hex(stalled_beats[28+:4]);
        60: tx_byte=hex(stalled_beats[24+:4]);
        61: tx_byte=hex(stalled_beats[20+:4]);
        62: tx_byte=hex(stalled_beats[16+:4]);
        63: tx_byte=hex(stalled_beats[12+:4]);
        64: tx_byte=hex(stalled_beats[8+:4]);
        65: tx_byte=hex(stalled_beats[4+:4]);
        66: tx_byte=hex(stalled_beats[0+:4]);
        67: tx_byte=8'd13;
        68: tx_byte=8'd10;
        default: tx_byte=10;
    endcase
end
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin pace<=0; char_index<=0; reporting<=0; end
    else if(done) begin
        if(!reporting) begin
            if(pace==REPORT_DELAY) begin pace<=0; char_index<=0; reporting<=1; end
            else pace<=pace+1'b1;
        end else if(tx_ready) begin
            if(char_index==68) begin reporting<=0; pace<=0; end
            else char_index<=char_index+1'b1;
        end
    end
end
endmodule
