// SPDX-License-Identifier: Apache-2.0
// Atomic bounded symbol frames -> MSB-first canonical Huffman bytes.
module canonical_huffman_encoder #(
    parameter integer SYMBOLS=256, MAX_BITS=16, MAX_FRAME=256, TAG_W=8
)(
    input wire clk, rst,
    input wire cfg_valid, output wire cfg_ready,
    input wire [1:0] cfg_op,
    input wire [31:0] cfg_symbol, cfg_length,
    input wire [TAG_W-1:0] cfg_tag,
    output wire cfg_r_valid, input wire cfg_r_ready,
    output wire [1:0] cfg_r_op, output wire [2:0] cfg_r_status,
    output wire [MAX_BITS-1:0] cfg_r_code,
    output wire [31:0] cfg_r_length,
    output wire [TAG_W-1:0] cfg_r_tag,
    input wire c_valid, output wire c_ready,
    input wire [31:0] c_count, input wire [TAG_W-1:0] c_tag,
    input wire s_valid, output wire s_ready, input wire [31:0] s_symbol,
    output wire m_valid, input wire m_ready,
    output reg [7:0] m_data, output reg m_last,
    output reg [3:0] m_valid_bits, output wire [TAG_W-1:0] m_tag,
    output wire d_valid, input wire d_ready,
    output reg [2:0] d_status, output reg [31:0] d_error_index,
    output wire [31:0] d_bits, output wire [TAG_W-1:0] d_tag
);
    localparam integer IW=(MAX_FRAME<=1)?1:$clog2(MAX_FRAME);
    localparam integer NW=$clog2(MAX_FRAME+1);
    localparam integer LW=$clog2(MAX_BITS+1);
    localparam integer BW=$clog2(MAX_FRAME*MAX_BITS+1);
    localparam [3:0] IDLE=0, CFG_REPLY=1, LOAD=2, QUERY_SEND=3,
                     QUERY_REPLY=4, DRAIN=5, FETCH=6, BIT=7, OUTPUT=8, DONE=9;
    reg [3:0] state, resume_state;
    reg [NW-1:0] frame_count;
    reg [IW-1:0] index;
    reg [31:0] pending_symbol;
    reg [TAG_W-1:0] tag;
    reg [MAX_BITS-1:0] codes [0:MAX_FRAME-1];
    reg [LW-1:0] lengths [0:MAX_FRAME-1];
    reg [MAX_BITS-1:0] code_q;
    reg [LW-1:0] remaining;
    reg [7:0] pack;
    reg [3:0] pack_count;
    reg [BW-1:0] total_bits;
    wire table_ready, table_valid;
    wire [2:0] table_status;
    wire [MAX_BITS-1:0] table_code;
    wire [31:0] table_length;
    wire [1:0] table_op;
    wire [TAG_W-1:0] table_tag;
    wire last_symbol=(index==frame_count-1'b1);
    wire last_bit=(remaining==1);
    wire next_bit=code_q[remaining-1'b1];
    wire [7:0] next_pack={pack[6:0],next_bit};

    generate if (SYMBOLS<1 || SYMBOLS>256 || MAX_BITS<1 || MAX_BITS>16 ||
                 MAX_FRAME<1 || MAX_FRAME>1024 || TAG_W<1 || TAG_W>32) begin: invalid
        canonical_huffman_encoder_invalid_parameters invalid_parameters();
    end endgenerate

    canonical_huffman_table #(.SYMBOLS(SYMBOLS),.MAX_BITS(MAX_BITS),.TAG_W(TAG_W)) codebook (
        .clk(clk),.rst(rst),
        .c_valid((state==IDLE && cfg_valid) || state==QUERY_SEND),
        .c_ready(table_ready),.c_op(state==QUERY_SEND ? 2'd2 : cfg_op),
        .c_symbol(state==QUERY_SEND ? pending_symbol : cfg_symbol),
        .c_length(state==QUERY_SEND ? 32'd0 : cfg_length),
        .c_tag(state==QUERY_SEND ? {TAG_W{1'b0}} : cfg_tag),
        .r_valid(table_valid),
        .r_ready((state==CFG_REPLY && cfg_r_ready) || state==QUERY_REPLY),
        .r_op(table_op),.r_status(table_status),.r_code(table_code),
        .r_length(table_length),.r_tag(table_tag)
    );
    assign cfg_ready=!rst && state==IDLE && table_ready;
    assign cfg_r_valid=!rst && state==CFG_REPLY && table_valid;
    assign cfg_r_op=table_op;
    assign cfg_r_status=table_status;
    assign cfg_r_code=table_code;
    assign cfg_r_length=table_length;
    assign cfg_r_tag=table_tag;
    assign c_ready=!rst && state==IDLE && table_ready && !cfg_valid;
    assign s_ready=!rst && (state==LOAD || state==DRAIN);
    assign m_valid=!rst && state==OUTPUT;
    assign m_tag=tag;
    assign d_valid=!rst && state==DONE;
    assign d_bits={{(32-BW){1'b0}},total_bits};
    assign d_tag=tag;

    always @(posedge clk) begin
        if (rst) begin
            state<=IDLE; resume_state<=IDLE;
            frame_count<=0; index<=0; pending_symbol<=0; tag<=0;
            code_q<=0; remaining<=0; pack<=0; pack_count<=0; total_bits<=0;
            m_data<=0; m_last<=0; m_valid_bits<=0;
            d_status<=0; d_error_index<=0;
        end else case (state)
            IDLE: begin
                if (cfg_valid && cfg_ready) state<=CFG_REPLY;
                else if (c_valid && c_ready) begin
                    tag<=c_tag; index<=0; total_bits<=0; pack<=0; pack_count<=0;
                    d_status<=0; d_error_index<=0;
                    if (c_count>MAX_FRAME) begin d_status<=6; state<=DONE; end
                    else if (c_count==0) state<=DONE;
                    else begin frame_count<=c_count[NW-1:0]; state<=LOAD; end
                end
            end
            CFG_REPLY: if (table_valid && cfg_r_ready) state<=IDLE;
            LOAD: if (s_valid) begin
                pending_symbol<=s_symbol; state<=QUERY_SEND;
            end
            QUERY_SEND: if (table_ready) state<=QUERY_REPLY;
            QUERY_REPLY: if (table_valid) begin
                if (table_status!=0) begin
                    d_status<=table_status;
                    d_error_index<={{(32-IW){1'b0}},index};
                    total_bits<=0;
                    if (last_symbol) state<=DONE;
                    else begin index<=index+1'b1; state<=DRAIN; end
                end else begin
                    codes[index]<=table_code;
                    lengths[index]<=table_length[LW-1:0];
                    total_bits<=total_bits+table_length[LW-1:0];
                    if (last_symbol) begin index<=0; state<=FETCH; end
                    else begin index<=index+1'b1; state<=LOAD; end
                end
            end
            DRAIN: if (s_valid) begin
                if (last_symbol) state<=DONE;
                else index<=index+1'b1;
            end
            FETCH: begin
                code_q<=codes[index]; remaining<=lengths[index]; state<=BIT;
            end
            BIT: begin
                remaining<=remaining-1'b1;
                if (last_bit && !last_symbol) index<=index+1'b1;
                if (pack_count==7 || (last_bit && last_symbol)) begin
                    m_data <= (pack_count==7) ? next_pack : (next_pack << (4'd7-pack_count));
                    m_valid_bits<=pack_count+1'b1;
                    m_last<=last_bit && last_symbol;
                    pack<=0; pack_count<=0;
                    resume_state<=last_bit ? (last_symbol ? DONE : FETCH) : BIT;
                    state<=OUTPUT;
                end else begin
                    pack<=next_pack; pack_count<=pack_count+1'b1;
                    if (last_bit) state<=FETCH;
                end
            end
            OUTPUT: if (m_ready) state<=resume_state;
            DONE: if (d_ready) state<=IDLE;
            default: state<=IDLE;
        endcase
    end
endmodule
