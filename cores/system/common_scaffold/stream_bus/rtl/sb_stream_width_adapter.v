// functional_minimal: integer-ratio byte widths, low lanes first, no compaction.
// TKEEP positions are preserved. Narrowing emits zero-KEEP beats if present.
// Widening reports changed USER within an output word; output uses first USER.
module sb_stream_width_adapter #(
    parameter S_WIDTH=8, parameter M_WIDTH=32, parameter USER_WIDTH=1
)(
    input wire clk,rst_n,clk_en,
    input wire [S_WIDTH-1:0] s_data, input wire [S_WIDTH/8-1:0] s_keep,
    input wire [USER_WIDTH-1:0] s_user, input wire s_last,s_valid, output wire s_ready,
    output wire [M_WIDTH-1:0] m_data, output wire [M_WIDTH/8-1:0] m_keep,
    output wire [USER_WIDTH-1:0] m_user, output wire m_last,m_valid,
    input wire m_ready, output wire error
);
    generate if (S_WIDTH==M_WIDTH) begin: equal_width
        sb_stream_elastic #(.DATA_WIDTH(S_WIDTH),.USER_WIDTH(USER_WIDTH)) reg_i(
            .clk(clk),.rst_n(rst_n),.clk_en(clk_en),.s_data(s_data),.s_keep(s_keep),
            .s_user(s_user),.s_last(s_last),.s_valid(s_valid),.s_ready(s_ready),
            .m_data(m_data),.m_keep(m_keep),.m_user(m_user),.m_last(m_last),
            .m_valid(m_valid),.m_ready(m_ready));
        assign error=1'b0;
    end else if (S_WIDTH<M_WIDTH) begin: widen
        localparam RATIO=M_WIDTH/S_WIDTH;
        localparam CW=(RATIO<2)?1:$clog2(RATIO);
        reg [CW-1:0] count;
        reg [M_WIDTH-1:0] partial, data;
        reg [M_WIDTH/8-1:0] partial_keep, keep;
        reg [USER_WIDTH-1:0] first_user,user;
        reg valid,last,err;
        reg [M_WIDTH-1:0] next_data;
        reg [M_WIDTH/8-1:0] next_keep;
        always @* begin
            next_data=partial; next_keep=partial_keep;
            next_data[count*S_WIDTH+:S_WIDTH]=s_data;
            next_keep[count*(S_WIDTH/8)+:(S_WIDTH/8)]=s_keep;
        end
        assign s_ready=rst_n&&clk_en&&(!valid||m_ready);
        assign m_data=data; assign m_keep=keep; assign m_user=user;
        assign m_valid=valid; assign m_last=last; assign error=err;
        always @(posedge clk or negedge rst_n) begin
            if(!rst_n) begin
                count<=0; partial<=0; partial_keep<=0; data<=0; keep<=0;
                first_user<=0; user<=0; valid<=0; last<=0; err<=0;
            end else begin
                err<=0;
                if(clk_en) begin
                    if(valid&&m_ready) valid<=0;
                    if(s_valid&&s_ready) begin
                        if(count==0) first_user<=s_user;
                        else if(s_user!=first_user) err<=1;
                        if(s_last||count==RATIO-1) begin
                            data<=next_data; keep<=next_keep; last<=s_last;
                            user<=(count==0)?s_user:first_user; valid<=1;
                            count<=0; partial<=0; partial_keep<=0;
                        end else begin
                            count<=count+1'b1; partial<=next_data; partial_keep<=next_keep;
                        end
                    end
                end
            end
        end
    end else begin: narrow
        localparam RATIO=S_WIDTH/M_WIDTH;
        localparam CW=(RATIO<2)?1:$clog2(RATIO);
        reg [S_WIDTH-1:0] data;
        reg [S_WIDTH/8-1:0] keep;
        reg [USER_WIDTH-1:0] user;
        reg last,valid;
        reg [CW-1:0] count;
        assign s_ready=rst_n&&clk_en&&(!valid||(m_ready&&count==RATIO-1));
        assign m_data=data[count*M_WIDTH+:M_WIDTH];
        assign m_keep=keep[count*(M_WIDTH/8)+:(M_WIDTH/8)];
        assign m_user=user; assign m_valid=valid;
        assign m_last=last&&(count==RATIO-1); assign error=1'b0;
        always @(posedge clk or negedge rst_n) begin
            if(!rst_n) begin data<=0;keep<=0;user<=0;last<=0;valid<=0;count<=0;end
            else if(clk_en) begin
                if(valid&&m_ready) begin
                    if(count==RATIO-1) begin valid<=0;count<=0;end
                    else count<=count+1'b1;
                end
                if(s_valid&&s_ready) begin
                    data<=s_data;keep<=s_keep;user<=s_user;last<=s_last;valid<=1;count<=0;
                end
            end
        end
    end endgenerate
    initial if(S_WIDTH<8||M_WIDTH<8||S_WIDTH%8||M_WIDTH%8||USER_WIDTH<1||
        (S_WIDTH>M_WIDTH ? S_WIDTH%M_WIDTH : M_WIDTH%S_WIDTH))
        $fatal(1,"sb_stream_width_adapter: byte widths with integer ratio required");
endmodule
