// Exact Otsu threshold from 256 counts, one count per bin in ascending order.
// Maximize (total_sum*w0 - prefix_sum*total_count)^2 / (w0*w1).
// Cross-products compare rational scores; ties choose the lowest threshold.
// Histogram state uses synchronous RAM; wide products share a serial multiplier.
module img_hist_otsu_threshold #(parameter COUNT_W=16)(
    input wire clk,rst_n,clk_en,
    input wire cmd_valid,
    output wire cmd_ready,
    input wire [COUNT_W-1:0] s_count,
    input wire s_valid,
    output wire s_ready,
    output reg rsp_valid,
    input wire rsp_ready,
    output reg [7:0] rsp_threshold,
    output reg [1:0] rsp_error
);
localparam TW=COUNT_W+8,SW=COUNT_W+16,DW=TW+SW+1;
localparam NUM_W=2*DW,DEN_W=2*TW,CROSS_W=NUM_W+DEN_W;
localparam B_W=(DW>DEN_W)?DW:DEN_W;
localparam IDLE=0,LOAD=1,READ=2,CAPTURE=3,EVALUATE=4,ISSUE=5,WAIT_PRODUCT=6,ADVANCE=7,RESPONSE=8,LOAD_WEIGHT_ACCUM=9,SCAN_WEIGHT_ACCUM=10;
reg [3:0] state;
reg [2:0] operation;
reg [7:0] load_bin,scan_bin,best_threshold;
reg [COUNT_W-1:0] histogram[0:255];
reg [COUNT_W-1:0] count_q;
reg [TW-1:0] total_count,weight0;
reg [SW-1:0] total_sum,prefix_sum,incoming_weight_q,scanned_weight_q;
reg [DW-1:0] first_product,delta;
reg [NUM_W-1:0] numerator,best_numerator;
reg [DEN_W-1:0] denominator,best_denominator;
reg [CROSS_W-1:0] left_cross;
reg [NUM_W-1:0] operand_a;
reg [B_W-1:0] operand_b;
wire mul_ready,mul_valid;
wire [NUM_W+B_W-1:0] product;
wire [SW-1:0] incoming_weight=s_count*load_bin;
wire [SW-1:0] scanned_weight=count_q*scan_bin;
assign cmd_ready=rst_n && state==IDLE;
assign s_ready=rst_n && state==LOAD;
always @(posedge clk) if(clk_en) begin
    if(state==LOAD && s_valid && rst_n) histogram[load_bin]<=s_count;
    if(state==READ) count_q<=histogram[scan_bin];
end
always @* begin
    operand_a=0;operand_b=0;
    case(operation)
        0:begin operand_a=total_sum;operand_b=weight0;end
        1:begin operand_a=prefix_sum;operand_b=total_count;end
        2:begin operand_a=delta;operand_b=delta;end
        3:begin operand_a=weight0;operand_b=total_count-weight0;end
        4:begin operand_a=numerator;operand_b=best_denominator;end
        5:begin operand_a=best_numerator;operand_b=denominator;end
        default:begin operand_a=0;operand_b=0;end
    endcase
end
img_hist_serial_multiply #(.A_W(NUM_W),.B_W(B_W)) multiply(
    .clk(clk),.rst_n(rst_n),.clk_en(clk_en),.s_valid(state==ISSUE),.s_ready(mul_ready),
    .s_a(operand_a),.s_b(operand_b),.m_valid(mul_valid),
    .m_ready(state==WAIT_PRODUCT),.m_product(product));
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        state<=IDLE;operation<=0;load_bin<=0;scan_bin<=0;best_threshold<=0;
        total_count<=0;weight0<=0;total_sum<=0;prefix_sum<=0;incoming_weight_q<=0;scanned_weight_q<=0;
        first_product<=0;delta<=0;numerator<=0;denominator<=0;
        best_numerator<=0;best_denominator<=0;left_cross<=0;
        rsp_valid<=0;rsp_threshold<=0;rsp_error<=0;
    end else if(clk_en) begin
        case(state)
        IDLE:if(cmd_valid && cmd_ready) begin
            load_bin<=0;scan_bin<=0;total_count<=0;total_sum<=0;
            weight0<=0;prefix_sum<=0;best_numerator<=0;best_denominator<=0;best_threshold<=0;
            state<=LOAD;
        end
        LOAD:if(s_valid && s_ready) begin
            total_count<=total_count+s_count;incoming_weight_q<=incoming_weight;state<=LOAD_WEIGHT_ACCUM;
        end
        LOAD_WEIGHT_ACCUM:begin
            total_sum<=total_sum+incoming_weight_q;
            if(load_bin==255) state<=READ;else begin load_bin<=load_bin+1'b1;state<=LOAD;end
        end
        READ:begin
            if(total_count==0) begin rsp_valid<=1;rsp_threshold<=0;rsp_error<=2;state<=RESPONSE;end
            else state<=CAPTURE;
        end
        CAPTURE:begin weight0<=weight0+count_q;scanned_weight_q<=scanned_weight;state<=SCAN_WEIGHT_ACCUM;end
        SCAN_WEIGHT_ACCUM:begin prefix_sum<=prefix_sum+scanned_weight_q;state<=EVALUATE;end
        EVALUATE:begin
            if(weight0!=0 && weight0!=total_count) begin operation<=0;state<=ISSUE;end
            else state<=ADVANCE;
        end
        ISSUE:if(mul_ready) state<=WAIT_PRODUCT;
        WAIT_PRODUCT:if(mul_valid) begin
            case(operation)
            0:begin first_product<=product[DW-1:0];operation<=1;state<=ISSUE;end
            1:begin delta<=first_product-product[DW-1:0];operation<=2;state<=ISSUE;end
            2:begin numerator<=product[NUM_W-1:0];operation<=3;state<=ISSUE;end
            3:begin
                denominator<=product[DEN_W-1:0];
                if(best_denominator==0) begin
                    best_denominator<=product[DEN_W-1:0];best_numerator<=numerator;best_threshold<=scan_bin;
                    state<=ADVANCE;
                end else begin operation<=4;state<=ISSUE;end
            end
            4:begin left_cross<=product[CROSS_W-1:0];operation<=5;state<=ISSUE;end
            5:begin
                if(left_cross>product[CROSS_W-1:0]) begin
                    best_denominator<=denominator;best_numerator<=numerator;best_threshold<=scan_bin;
                end
                state<=ADVANCE;
            end
            default:state<=ADVANCE;
            endcase
        end
        ADVANCE:begin
            if(scan_bin==255) begin rsp_valid<=1;rsp_threshold<=best_threshold;rsp_error<=0;state<=RESPONSE;end
            else begin scan_bin<=scan_bin+1'b1;state<=READ;end
        end
        RESPONSE:if(rsp_ready) begin rsp_valid<=0;state<=IDLE;end
        default:state<=IDLE;
        endcase
    end
end
`ifndef SYNTHESIS
initial if(COUNT_W<1 || COUNT_W>24) $fatal(1,"Otsu supports COUNT_W=1..24");
`endif
endmodule
