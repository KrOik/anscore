// Original ANSCORE RTL, Apache-2.0. Exact resident S8 nearest-code search.
module signed8_codebook_search #(
    parameter MAX_CODES=16, MAX_DIMS=16, TAG_W=8
)(
    input wire clk, rst,
    input wire cfg_valid, output wire cfg_ready,
    input wire [6:0] cfg_code, input wire [8:0] cfg_dim,
    input wire cfg_first, input wire signed [7:0] cfg_value,
    output wire cfg_rsp_valid, input wire cfg_rsp_ready,
    output reg [1:0] cfg_status,
    output reg [6:0] cfg_rsp_code, output reg [8:0] cfg_rsp_dim,
    input wire c_valid, output wire c_ready,
    input wire [6:0] c_codes, input wire [8:0] c_dims,
    input wire [TAG_W-1:0] c_tag,
    input wire s_valid, output wire s_ready,
    input wire signed [7:0] s_value,
    output wire m_valid, input wire m_ready,
    output reg [1:0] m_error,
    output reg [5:0] m_code,
    output reg [23:0] m_distance, m_margin,
    output reg m_second_valid,
    output wire [TAG_W-1:0] m_tag,
    output wire r_valid, input wire r_ready,
    output wire [7:0] r_dim,
    output wire signed [7:0] r_value, r_original,
    output wire signed [8:0] r_residual,
    output wire r_last, output wire [TAG_W-1:0] r_tag
);
    generate if(MAX_CODES<1 || MAX_CODES>64 || MAX_DIMS<1 ||
                MAX_DIMS>256 || TAG_W<1 || TAG_W>32) begin: bad_parameters
        signed8_codebook_search_illegal_parameters invalid_instance();
    end endgenerate

    localparam IDLE=4'd0, CFG_ACK=4'd1, CHECK=4'd2, LOAD=4'd3,
        READ_PAIR=4'd4, DIFFERENCE=4'd5, SQUARE=4'd6, ACCUMULATE=4'd7,
        FINISH=4'd8, RESULT=4'd9, REPLAY_READ=4'd10, REPLAY_OUT=4'd11;
    reg [3:0] state;
    // Payload arrays have synchronous access and are intentionally not reset.
    reg signed [7:0] codebook [0:MAX_CODES*MAX_DIMS-1];
    reg signed [7:0] query [0:MAX_DIMS-1];
    reg [8:0] prefix [0:MAX_CODES-1];
    reg [6:0] codes_q;
    reg [8:0] dims_q;
    reg [TAG_W-1:0] tag_q;
    reg [5:0] check_code, code_index, best_code;
    reg [7:0] load_index, dim_index, replay_index;
    reg signed [7:0] query_data, centroid_data;
    reg signed [8:0] difference_q;
    reg [17:0] square_q;
    reg [23:0] sum_q, best_distance, second_distance;
    reg best_valid, second_valid;
    wire [23:0] next_sum = sum_q + {8'b0,square_q[15:0]};
    wire last_dimension = ({1'b0,dim_index}+9'd1 == dims_q);
    wire last_code = ({1'b0,code_index}+7'd1 == codes_q);
    assign cfg_ready = !rst && state==IDLE;
    // Configuration wins a simultaneous idle command; neither input is lost.
    assign c_ready = !rst && state==IDLE && !cfg_valid;
    assign cfg_rsp_valid = !rst && state==CFG_ACK;
    assign s_ready = !rst && state==LOAD;
    assign m_valid = !rst && state==RESULT;
    assign m_tag = tag_q;
    assign r_valid = !rst && state==REPLAY_OUT;
    assign r_dim = replay_index;
    assign r_value = centroid_data;
    assign r_original = query_data;
    assign r_residual = $signed({query_data[7],query_data}) -
                        $signed({centroid_data[7],centroid_data});
    assign r_last = ({1'b0,replay_index}+9'd1 == dims_q);
    assign r_tag = tag_q;

    integer i;
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;
            cfg_status<=0; cfg_rsp_code<=0; cfg_rsp_dim<=0;
            codes_q<=0; dims_q<=0; tag_q<=0;
            check_code<=0; code_index<=0; best_code<=0;
            load_index<=0; dim_index<=0; replay_index<=0;
            query_data<=0; centroid_data<=0; difference_q<=0; square_q<=0;
            sum_q<=0; best_distance<=0; second_distance<=0;
            best_valid<=0; second_valid<=0;
            m_error<=0; m_code<=0; m_distance<=0; m_margin<=0; m_second_valid<=0;
            for(i=0;i<MAX_CODES;i=i+1) prefix[i]<=0;
        end else begin
            case(state)
                IDLE: begin
                    if(cfg_valid) begin
                        cfg_rsp_code<=cfg_code; cfg_rsp_dim<=cfg_dim;
                        cfg_status<=0;
                        if(cfg_code>=MAX_CODES || cfg_dim>=MAX_DIMS) begin
                            cfg_status<=1;
                        end else if(cfg_first) begin
                            if(cfg_dim!=0) cfg_status<=2;
                            else begin
                                codebook[cfg_code*MAX_DIMS]<=cfg_value;
                                prefix[cfg_code[5:0]]<=9'd1;
                            end
                        end else if(prefix[cfg_code[5:0]]!=0 &&
                                    cfg_dim==prefix[cfg_code[5:0]]) begin
                            codebook[cfg_code*MAX_DIMS+cfg_dim]<=cfg_value;
                            prefix[cfg_code[5:0]]<=prefix[cfg_code[5:0]]+9'd1;
                        end else cfg_status<=2;
                        state<=CFG_ACK;
                    end else if(c_valid) begin
                        codes_q<=c_codes; dims_q<=c_dims; tag_q<=c_tag;
                        m_error<=0; m_code<=0; m_distance<=0; m_margin<=0;
                        m_second_valid<=0; best_valid<=0; second_valid<=0;
                        if(c_codes==0 || c_codes>MAX_CODES ||
                           c_dims==0 || c_dims>MAX_DIMS) begin
                            m_error<=1; state<=RESULT;
                        end else begin check_code<=0; state<=CHECK; end
                    end
                end
                CFG_ACK: if(cfg_rsp_ready) state<=IDLE;
                CHECK: begin
                    if(prefix[check_code]<dims_q) begin
                        m_error<=2; state<=RESULT;
                    end else if({1'b0,check_code}+7'd1==codes_q) begin
                        load_index<=0; state<=LOAD;
                    end else check_code<=check_code+6'd1;
                end
                LOAD: if(s_valid) begin
                    query[load_index]<=s_value;
                    if({1'b0,load_index}+9'd1==dims_q) begin
                        code_index<=0; dim_index<=0; sum_q<=0;
                        state<=READ_PAIR;
                    end else load_index<=load_index+8'd1;
                end
                READ_PAIR: begin
                    query_data<=query[dim_index];
                    centroid_data<=codebook[code_index*MAX_DIMS+dim_index];
                    state<=DIFFERENCE;
                end
                DIFFERENCE: begin
                    difference_q<=$signed({query_data[7],query_data})-
                                  $signed({centroid_data[7],centroid_data});
                    state<=SQUARE;
                end
                SQUARE: begin
                    square_q<=$signed(difference_q)*$signed(difference_q);
                    state<=ACCUMULATE;
                end
                ACCUMULATE: begin
                    if(!last_dimension) begin
                        sum_q<=next_sum; dim_index<=dim_index+8'd1;
                        state<=READ_PAIR;
                    end else begin
                        // Ascending traversal and strict improvements give
                        // lowest-index ties for both the winner and runner-up.
                        if(!best_valid || next_sum<best_distance) begin
                            best_valid<=1; best_distance<=next_sum;
                            best_code<=code_index;
                            if(best_valid) begin
                                second_valid<=1; second_distance<=best_distance;
                            end
                        end else if(!second_valid || next_sum<second_distance) begin
                            second_valid<=1; second_distance<=next_sum;
                        end
                        if(last_code) state<=FINISH;
                        else begin
                            code_index<=code_index+6'd1; dim_index<=0; sum_q<=0;
                            state<=READ_PAIR;
                        end
                    end
                end
                FINISH: begin
                    m_code<=best_code; m_distance<=best_distance;
                    m_second_valid<=second_valid;
                    m_margin<=second_valid ? second_distance-best_distance : 24'd0;
                    state<=RESULT;
                end
                RESULT: if(m_ready) begin
                    if(m_error!=0) state<=IDLE;
                    else begin replay_index<=0; state<=REPLAY_READ; end
                end
                REPLAY_READ: begin
                    centroid_data<=codebook[best_code*MAX_DIMS+replay_index];
                    query_data<=query[replay_index]; state<=REPLAY_OUT;
                end
                REPLAY_OUT: if(r_ready) begin
                    if(r_last) state<=IDLE;
                    else begin replay_index<=replay_index+8'd1; state<=REPLAY_READ; end
                end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
