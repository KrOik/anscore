// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Serial atomic read/modify/write word storage, initialized sequentially.
module atomic_scratchpad #(
    parameter integer DATA_W=32,
    parameter integer DEPTH=256,
    parameter integer TAG_W=8,
    localparam integer ADDR_W=(DEPTH<2)?1:$clog2(DEPTH)
)(
    input wire clk,rst,
    output wire initializing,
    input wire s_valid,
    output wire s_ready,
    input wire [3:0] s_op,
    input wire [ADDR_W-1:0] s_address,
    input wire [DATA_W-1:0] s_operand,s_compare,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid,
    input wire m_ready,
    output reg [DATA_W-1:0] m_old,
    output reg m_wrote,
    output reg [1:0] m_status, // 0 OK, 1 invalid word address, 2 invalid opcode
    output reg [TAG_W-1:0] m_tag
);
    generate if(DATA_W<2 || DATA_W>64 || DEPTH<1 || DEPTH>4096 || TAG_W<1 || TAG_W>32)
        begin:g_invalid
            atomic_scratchpad_invalid_parameters invalid_configuration();
        end
    endgenerate
    localparam [2:0] INIT=0,IDLE=1,READ_WORD=2,EXECUTE=3,COMMIT=4,RESPONSE=5;
    reg [2:0] state;
    reg [ADDR_W-1:0] clear_address,address;
    reg [3:0] operation;
    reg [DATA_W-1:0] operand,compare_value,read_word,new_word;
    reg write_word;
    reg [DATA_W-1:0] memory[0:DEPTH-1];
    reg [DATA_W-1:0] operation_result;
    reg operation_writes;
    wire signed_comparison=operation==6 || operation==7;
    wire [DATA_W-1:0] sign_bias=signed_comparison ? {1'b1,{(DATA_W-1){1'b0}}} : {DATA_W{1'b0}};
    // Sign-bit bias maps signed order to unsigned order; one comparator serves
    // both signed and unsigned min/max operations.
    wire operand_less=(operand^sign_bias)<(read_word^sign_bias);
    wire memory_write=!rst && (state==INIT || (state==COMMIT && write_word));
    wire [ADDR_W-1:0] write_address=(state==INIT)?clear_address:address;
    wire [DATA_W-1:0] write_data=(state==INIT)?{DATA_W{1'b0}}:new_word;
    assign initializing=rst || state==INIT;
    assign s_ready=!rst && state==IDLE;
    assign m_valid=!rst && state==RESPONSE;

    always @* begin
        operation_result=read_word;
        operation_writes=1'b1;
        case(operation)
            0:operation_writes=1'b0;                          // read
            1:operation_result=operand;                       // exchange
            2:operation_result=read_word+operand;             // modulo add
            3:operation_result=read_word^operand;
            4:operation_result=read_word&operand;
            5:operation_result=read_word|operand;
            6,8:operation_result=operand_less?operand:read_word; // min
            7,9:operation_result=operand_less?read_word:operand; // max
            10:begin
                operation_writes=read_word==compare_value;
                operation_result=operand;
            end
            default:operation_writes=1'b0;
        endcase
    end

    // All memory accesses are mutually exclusive. Reset clears the array via
    // the INIT write sweep instead of reset muxes on every payload bit.
    always @(posedge clk) begin
        if(memory_write) memory[write_address]<=write_data;
        if(!rst && state==READ_WORD) read_word<=memory[address];
    end
    always @(posedge clk) begin
        if(rst) begin
            state<=INIT;clear_address<=0;address<=0;
            operation<=0;operand<=0;compare_value<=0;new_word<=0;write_word<=0;
            m_old<=0;m_wrote<=0;m_status<=0;m_tag<=0;
        end else case(state)
            INIT:begin
                if(clear_address==DEPTH-1) begin clear_address<=0;state<=IDLE;end
                else clear_address<=clear_address+1'b1;
            end
            IDLE:if(s_valid) begin
                m_tag<=s_tag;m_status<=0;m_old<=0;m_wrote<=0;
                if(s_op>10) begin m_status<=2;state<=RESPONSE;end
                else if({1'b0,s_address}>=DEPTH) begin m_status<=1;state<=RESPONSE;end
                else begin
                    operation<=s_op;address<=s_address;
                    operand<=s_operand;compare_value<=s_compare;
                    state<=READ_WORD;
                end
            end
            READ_WORD:state<=EXECUTE;
            EXECUTE:begin
                m_old<=read_word;m_wrote<=operation_writes;
                new_word<=operation_result;write_word<=operation_writes;
                state<=COMMIT;
            end
            COMMIT:state<=RESPONSE;
            RESPONSE:if(m_ready) state<=IDLE;
            default:state<=INIT;
        endcase
    end
endmodule
