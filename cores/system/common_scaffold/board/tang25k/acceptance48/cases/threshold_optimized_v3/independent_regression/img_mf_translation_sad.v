// Bounded integer translation; identical luma SAD and ordered-tie semantics.
// Real registered boundaries isolate input capture, luma constant products,
// luma sum, absolute difference, bounded accumulation, compare and update.
// No clock/timing exceptions are used. Public costs remain 48 bits.
module img_mf_translation_sad #(
    parameter WIDTH=32, HEIGHT=24, MAX_SHIFT=2, DATA_WIDTH=24,
    parameter MIN_CONFIDENCE=1
) (
    input wire clk, rst_n, clk_en,
    input wire start_valid, output wire start_ready,
    output reg result_valid, input wire result_ready,
    output reg signed [15:0] best_dx, best_dy,
    output reg [47:0] best_cost, second_cost, confidence,
    output reg [31:0] sample_count, output reg [7:0] result_error,
    output wire rd_valid, input wire rd_ready,
    output wire [31:0] rd_addr0, rd_addr1,
    input wire rd_rsp_valid, output wire rd_rsp_ready,
    input wire [DATA_WIDTH-1:0] rd_data0, rd_data1, input wire [7:0] rd_error
);
    localparam IDLE=0, REQUEST=1, WAIT_DATA=2, LUMA_PRODUCTS=3,
        LUMA_SUM=4, ABS_DIFF=5, ACCUMULATE=6, COMPARE=7, UPDATE=8,
        GAP=9, FINISH=10, COORDINATES=11, ROWS=12, ADDRESSES=13;
    localparam SAMPLES=(WIDTH-2*MAX_SHIFT)*(HEIGHT-2*MAX_SHIFT);
    // Legal frames contain <=65536 samples and each luma difference <=255.
    // +2 reserves an all-ones sentinel STRICTLY above the largest legal SAD;
    // e.g. one sample needs9 bits,65536 samples need24 bits. Invalid parameter
    // combinations never request data and use a safe elaboration width.
    localparam COST_W=(SAMPLES>0 && SAMPLES<=65536)?$clog2(SAMPLES*255+2):24;
    localparam [COST_W-1:0] SENTINEL={COST_W{1'b1}};
    reg [3:0] state;
    // A legal scan lies inside [S,dimension-S-1]; adding a trial in [-S,S]
    // therefore lies in [0,dimension-1]. Address/row products are <W*H<=65536.
    // Use one extra signed coordinate bit only for the shift addition, then
    // store its proven nonnegative in-range result. No address is issued for
    // invalid configurations, whose elaboration widths are kept positive.
    localparam XW=(WIDTH>1&&WIDTH<=65536)?$clog2(WIDTH):1;
    localparam YW=(HEIGHT>1&&HEIGHT<=65536)?$clog2(HEIGHT):1;
    localparam TW=(MAX_SHIFT>0&&MAX_SHIFT<=15)?$clog2(MAX_SHIFT+1)+1:1;
    localparam AW=(WIDTH*HEIGHT>1&&WIDTH*HEIGHT<=65536)?$clog2(WIDTH*HEIGHT):1;
    localparam [AW-1:0] STRIDE=WIDTH;
    reg [XW-1:0] scan_x,aux_x_q;
    reg [YW-1:0] scan_y,aux_y_q;
    reg signed [TW-1:0] trial_dx,trial_dy;
    reg [AW-1:0] row0_q,row1_q,address0_q,address1_q;
    wire signed [XW:0] shifted_x=$signed({1'b0,scan_x})+trial_dx;
    wire signed [YW:0] shifted_y=$signed({1'b0,scan_y})+trial_dy;
    reg [COST_W-1:0] accumulator, best_work, second_work, gap_q;
    reg signed [15:0] dx_work, dy_work;
    reg [DATA_WIDTH-1:0] pixel0_q,pixel1_q;
    reg [15:0] red0_q,green0_q,blue0_q,red1_q,green1_q,blue1_q;
    reg [7:0] gray0_q,gray1_q,difference_q;
    reg less_best_q,less_second_q;
    wire [23:0] rgb0=pixel0_q,rgb1=pixel1_q;
    wire [17:0] luma0={2'd0,red0_q}+{2'd0,green0_q}+{2'd0,blue0_q}+18'd128;
    wire [17:0] luma1={2'd0,red1_q}+{2'd0,green1_q}+{2'd0,blue1_q}+18'd128;
    wire [47:0] public_best=(best_work==SENTINEL)?48'hffffffffffff:{{(48-COST_W){1'b0}},best_work};
    wire [47:0] public_second=(second_work==SENTINEL)?48'hffffffffffff:{{(48-COST_W){1'b0}},second_work};
    wire [47:0] public_gap={{(48-COST_W){1'b0}},gap_q};
    wire params_ok=WIDTH>0 && HEIGHT>0 && WIDTH*HEIGHT<=65536 && MAX_SHIFT>=0 && MAX_SHIFT<=15 &&
        WIDTH>2*MAX_SHIFT && HEIGHT>2*MAX_SHIFT && (DATA_WIDTH==8 || DATA_WIDTH==24);
    assign start_ready=rst_n && clk_en && state==IDLE && !result_valid;
    assign rd_valid=rst_n && state==REQUEST;
    assign rd_rsp_ready=rst_n && state==WAIT_DATA;
    assign rd_addr0={{(32-AW){1'b0}},address0_q};
    assign rd_addr1={{(32-AW){1'b0}},address1_q};
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n)begin
            state<=IDLE;result_valid<=0;result_error<=0;
            best_dx<=0;best_dy<=0;best_cost<=0;second_cost<=0;confidence<=0;sample_count<=0;
            scan_x<=0;scan_y<=0;trial_dx<=0;trial_dy<=0;
            aux_x_q<=0;aux_y_q<=0;row0_q<=0;row1_q<=0;address0_q<=0;address1_q<=0;
            accumulator<=0;best_work<=SENTINEL;second_work<=SENTINEL;gap_q<=0;dx_work<=0;dy_work<=0;
            pixel0_q<=0;pixel1_q<=0;red0_q<=0;green0_q<=0;blue0_q<=0;
            red1_q<=0;green1_q<=0;blue1_q<=0;gray0_q<=0;gray1_q<=0;difference_q<=0;
            less_best_q<=0;less_second_q<=0;
        end else if(clk_en)begin
            if(result_valid&&result_ready)result_valid<=0;
            case(state)
                IDLE:if(start_valid&&start_ready)begin
                    result_error<=0;accumulator<=0;best_work<=SENTINEL;second_work<=SENTINEL;
                    dx_work<=0;dy_work<=0;trial_dx<=-MAX_SHIFT;trial_dy<=-MAX_SHIFT;
                    scan_x<=MAX_SHIFT;scan_y<=MAX_SHIFT;sample_count<=SAMPLES;
                    if(!params_ok)begin result_valid<=1;result_error<=8'h40;sample_count<=0;end
                    else state<=COORDINATES;
                end
                COORDINATES:begin aux_x_q<=shifted_x[XW-1:0];aux_y_q<=shifted_y[YW-1:0];state<=ROWS;end
                ROWS:begin row0_q<=scan_y*STRIDE;row1_q<=aux_y_q*STRIDE;state<=ADDRESSES;end
                ADDRESSES:begin address0_q<=row0_q+scan_x;address1_q<=row1_q+aux_x_q;state<=REQUEST;end
                REQUEST:if(rd_valid&&rd_ready)state<=WAIT_DATA;
                WAIT_DATA:if(rd_rsp_valid&&rd_rsp_ready)begin
                    if(rd_error!=0)begin result_valid<=1;result_error<=rd_error;state<=IDLE;end
                    else begin pixel0_q<=rd_data0;pixel1_q<=rd_data1;state<=LUMA_PRODUCTS;end
                end
                LUMA_PRODUCTS:begin
                    red0_q<=rgb0[23:16]*16'd77;green0_q<=rgb0[15:8]*16'd150;blue0_q<=rgb0[7:0]*16'd29;
                    red1_q<=rgb1[23:16]*16'd77;green1_q<=rgb1[15:8]*16'd150;blue1_q<=rgb1[7:0]*16'd29;
                    state<=LUMA_SUM;
                end
                LUMA_SUM:begin
                    gray0_q<=(DATA_WIDTH==8)?pixel0_q[7:0]:luma0[15:8];
                    gray1_q<=(DATA_WIDTH==8)?pixel1_q[7:0]:luma1[15:8];state<=ABS_DIFF;
                end
                ABS_DIFF:begin
                    difference_q<=(gray0_q>=gray1_q)?gray0_q-gray1_q:gray1_q-gray0_q;
                    state<=ACCUMULATE;
                end
                ACCUMULATE:begin
                    accumulator<=accumulator+{{(COST_W-8){1'b0}},difference_q};
                    if(scan_x==WIDTH-MAX_SHIFT-1&&scan_y==HEIGHT-MAX_SHIFT-1)state<=COMPARE;
                    else begin
                        if(scan_x==WIDTH-MAX_SHIFT-1)begin scan_x<=MAX_SHIFT;scan_y<=scan_y+1;end
                        else scan_x<=scan_x+1;
                        state<=COORDINATES;
                    end
                end
                COMPARE:begin
                    less_best_q<=accumulator<best_work;less_second_q<=accumulator<second_work;
                    state<=UPDATE;
                end
                UPDATE:begin
                    // Strict comparisons retain the first scanned best on ties;
                    // an equal best can still become second, giving confidence0.
                    if(less_best_q)begin
                        second_work<=best_work;best_work<=accumulator;dx_work<=trial_dx;dy_work<=trial_dy;
                    end else if(less_second_q)second_work<=accumulator;
                    accumulator<=0;scan_x<=MAX_SHIFT;scan_y<=MAX_SHIFT;
                    if(trial_dx==MAX_SHIFT&&trial_dy==MAX_SHIFT)state<=GAP;
                    else begin
                        if(trial_dx==MAX_SHIFT)begin trial_dx<=-MAX_SHIFT;trial_dy<=trial_dy+1;end
                        else trial_dx<=trial_dx+1;
                        state<=COORDINATES;
                    end
                end
                GAP:begin gap_q<=(MAX_SHIFT==0)?{COST_W{1'b0}}:second_work-best_work;state<=FINISH;end
                FINISH:begin
                    best_dx<=dx_work;best_dy<=dy_work;best_cost<=public_best;second_cost<=public_second;
                    confidence<=public_gap;
                    result_error<=(MAX_SHIFT!=0&&public_gap<MIN_CONFIDENCE)?8'h20:8'd0;
                    result_valid<=1;state<=IDLE;
                end
                default:begin state<=IDLE;result_valid<=1;result_error<=8'h40;end
            endcase
        end
    end
endmodule
