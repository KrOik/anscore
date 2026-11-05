// SPDX-License-Identifier: Apache-2.0
// Persistent unique unsigned-key dictionary. One owner; one synchronous RAM.
module ram_ordered_dictionary #(
    parameter integer CAPACITY=32, K_W=32, V_W=32,
    parameter integer COUNT_W=(CAPACITY<2)?1:$clog2(CAPACITY+1)
)(
    input wire clk, input wire rst_n,
    input wire s_valid, output wire s_ready,
    input wire [2:0] s_op,
    input wire [K_W-1:0] s_key, input wire [V_W-1:0] s_value,
    input wire [K_W-1:0] s_hi,
    output wire m_valid, input wire m_ready,
    output wire [1:0] m_kind, output wire [2:0] m_status,
    output wire m_found,
    output wire [K_W-1:0] m_key, output wire [V_W-1:0] m_value,
    output wire [COUNT_W-1:0] m_count
);
    generate if(CAPACITY<1 || CAPACITY>32 || K_W<1 || K_W>32 ||
                V_W<1 || V_W>32 ||
                COUNT_W!=((CAPACITY<2)?1:$clog2(CAPACITY+1))) begin: invalid
        ram_ordered_dictionary_invalid_parameters__see_README reject();
        assign s_ready=1'b0; assign m_valid=1'b0;
        assign m_kind=0;assign m_status=0;assign m_found=0;
        assign m_key=0;assign m_value=0;assign m_count=0;
    end else begin: impl
        localparam integer AW=(CAPACITY<2)?1:$clog2(CAPACITY);
        localparam integer CW=COUNT_W;
        localparam integer RW=8*((K_W+V_W+7)/8);
        localparam integer PAD=RW-K_W-V_W;
        localparam [2:0] GET=0,PUT=1,DELETE=2,SEEK_GE=3,RANGE=4,CLEAR=5;
        localparam [1:0] RESULT=0,ROW=1,END=2;
        localparam [2:0] OK=0,NOT_FOUND=1,FULL=2,BAD_RANGE=3,BAD_OP=4;
        localparam [4:0] IDLE=0,SEARCH=1,S_REQ=2,S_WAIT=3,S_COMPARE=4,
            B_REQ=5,B_WAIT=6,DISPATCH=7,SHIFT_R_REQ=8,SHIFT_R_WAIT=9,
            SHIFT_W_REQ=10,SHIFT_W_WAIT=11,FINAL_REQ=12,FINAL_WAIT=13,
            DEL_FINISH=14,R_REQ=15,R_WAIT=16,R_CHECK=17,OUT=18;
        reg [4:0] state;
        reg [CW-1:0] count,lo,hi,mid,index,shift_cursor;
        reg [2:0] op;
        reg [K_W-1:0] query_key,high_key;
        reg [V_W-1:0] query_value;
        reg [RW-1:0] row;
        reg [AW-1:0] read_addr;
        reg put_replaced;
        reg [1:0] response_kind;
        reg [2:0] response_status;
        reg response_found;
        reg [K_W-1:0] response_key;
        reg [V_W-1:0] response_value;
        reg [CW-1:0] response_count;
        wire [K_W-1:0] row_key=row[K_W-1:0];
        wire [V_W-1:0] row_value=row[K_W +: V_W];
        // One extended unsigned subtract supplies <, ==, > for all key tests.
        wire [K_W-1:0] compare_left=(state==IDLE)?s_key:row_key;
        wire [K_W-1:0] compare_right=(state==IDLE)?s_hi:
            ((state==R_CHECK)?high_key:query_key);
        wire [K_W:0] key_difference={1'b0,compare_left}-{1'b0,compare_right};
        wire less=key_difference[K_W];
        wire equal=(key_difference=={(K_W+1){1'b0}});
        wire greater=!less && !equal;
        wire [CW:0] midpoint_sum={1'b0,lo}+{1'b0,hi};
        wire [CW-1:0] midpoint=midpoint_sum[CW:1];
        wire at_key=(index<count) && equal;
        wire [RW-1:0] new_row={{PAD{1'b0}},query_value,query_key};
        wire ram_req_ready,ram_rsp_valid,ram_rsp_error;
        wire [RW-1:0] ram_rsp_data;
        wire read_request=(state==S_REQ || state==B_REQ ||
                           state==SHIFT_R_REQ || state==R_REQ);
        wire write_request=(state==SHIFT_W_REQ || state==FINAL_REQ);
        wire waiting=(state==S_WAIT || state==B_WAIT ||
                      state==SHIFT_R_WAIT || state==SHIFT_W_WAIT ||
                      state==FINAL_WAIT || state==R_WAIT);
        wire [AW-1:0] address=(state==SHIFT_W_REQ)?shift_cursor[AW-1:0]:
            ((state==FINAL_REQ)?index[AW-1:0]:read_addr);
        cip_sync_sp_ram #(.DATA_WIDTH(RW),.ADDR_WIDTH(AW),.DEPTH(CAPACITY)) u_rows(
            .clk(clk),.rst_n(rst_n),.clk_en(1'b1),
            .req_valid(rst_n && (read_request || write_request)),.req_ready(ram_req_ready),
            .req_write(write_request),.req_addr(address),
            .req_wdata((state==FINAL_REQ)?new_row:row),
            .req_wstrb({(RW/8){1'b1}}),
            .rsp_valid(ram_rsp_valid),.rsp_ready(waiting),
            .rsp_rdata(ram_rsp_data),.rsp_error(ram_rsp_error));
        assign s_ready=rst_n && state==IDLE;
        assign m_valid=rst_n && state==OUT;
        assign m_kind=response_kind;assign m_status=response_status;
        assign m_found=response_found;assign m_key=response_key;
        assign m_value=response_value;assign m_count=response_count;
        task respond(input [1:0] kind,input [2:0] status,input found,
                     input [K_W-1:0] key,input [V_W-1:0] value,
                     input [CW-1:0] occupancy);
            begin
                response_kind<=kind;response_status<=status;response_found<=found;
                response_key<=key;response_value<=value;response_count<=occupancy;
                state<=OUT;
            end
        endtask
        always @(posedge clk or negedge rst_n) begin
            if(!rst_n) begin
                state<=IDLE;count<=0;lo<=0;hi<=0;mid<=0;index<=0;shift_cursor<=0;
                op<=GET;query_key<=0;high_key<=0;query_value<=0;row<=0;read_addr<=0;
                put_replaced<=0;response_kind<=RESULT;response_status<=OK;
                response_found<=0;response_key<=0;response_value<=0;response_count<=0;
            end else begin
                case(state)
                    IDLE: if(s_valid) begin
                        op<=s_op;query_key<=s_key;query_value<=s_value;high_key<=s_hi;
                        if(s_op>CLEAR) respond(RESULT,BAD_OP,0,0,0,count);
                        else if(s_op==CLEAR) begin count<=0;respond(RESULT,OK,0,0,0,0);end
                        else if(s_op==RANGE && greater) respond(END,BAD_RANGE,0,0,0,count);
                        else begin lo<=0;hi<=count;state<=SEARCH;end
                    end
                    SEARCH: if(lo<hi) begin
                        mid<=midpoint;read_addr<=midpoint[AW-1:0];state<=S_REQ;
                    end else begin
                        index<=lo;
                        if(lo<count) begin read_addr<=lo[AW-1:0];state<=B_REQ;end
                        else state<=DISPATCH;
                    end
                    S_REQ: if(ram_req_ready) state<=S_WAIT;
                    S_WAIT: if(ram_rsp_valid) begin row<=ram_rsp_data;state<=S_COMPARE;end
                    S_COMPARE: begin
                        if(less) lo<=mid+CW'(1);else hi<=mid;
                        state<=SEARCH;
                    end
                    B_REQ: if(ram_req_ready) state<=B_WAIT;
                    B_WAIT: if(ram_rsp_valid) begin row<=ram_rsp_data;state<=DISPATCH;end
                    DISPATCH: case(op)
                        GET: if(at_key) respond(RESULT,OK,1,row_key,row_value,count);
                             else respond(RESULT,NOT_FOUND,0,0,0,count);
                        SEEK_GE: if(index<count) respond(RESULT,OK,1,row_key,row_value,count);
                                 else respond(RESULT,NOT_FOUND,0,0,0,count);
                        PUT: begin
                            put_replaced<=at_key;
                            if(at_key) state<=FINAL_REQ;
                            else if(count==CW'(CAPACITY)) respond(RESULT,FULL,0,0,0,count);
                            else if(index<count) begin
                                shift_cursor<=count;
                                read_addr<=(count-CW'(1));state<=SHIFT_R_REQ;
                            end else state<=FINAL_REQ;
                        end
                        DELETE: if(!at_key) respond(RESULT,NOT_FOUND,0,0,0,count);
                            else begin
                                // DELETE's input value is dead; reuse it to save removed value.
                                query_value<=row_value;
                                if(index+CW'(1)<count) begin
                                    shift_cursor<=index;read_addr<=index+CW'(1);state<=SHIFT_R_REQ;
                                end else state<=DEL_FINISH;
                            end
                        RANGE: if(index<count) state<=R_CHECK;
                               else respond(END,OK,0,0,0,count);
                        default: respond(RESULT,BAD_OP,0,0,0,count);
                    endcase
                    SHIFT_R_REQ: if(ram_req_ready) state<=SHIFT_R_WAIT;
                    SHIFT_R_WAIT: if(ram_rsp_valid) begin row<=ram_rsp_data;state<=SHIFT_W_REQ;end
                    SHIFT_W_REQ: if(ram_req_ready) state<=SHIFT_W_WAIT;
                    SHIFT_W_WAIT: if(ram_rsp_valid) begin
                        if(op==PUT) begin
                            if(shift_cursor>index+CW'(1)) begin
                                shift_cursor<=shift_cursor-CW'(1);
                                read_addr<=shift_cursor-CW'(2);state<=SHIFT_R_REQ;
                            end else state<=FINAL_REQ;
                        end else begin
                            if(shift_cursor+CW'(2)<count) begin
                                shift_cursor<=shift_cursor+CW'(1);
                                read_addr<=shift_cursor+CW'(2);state<=SHIFT_R_REQ;
                            end else state<=DEL_FINISH;
                        end
                    end
                    FINAL_REQ: if(ram_req_ready) state<=FINAL_WAIT;
                    FINAL_WAIT: if(ram_rsp_valid) begin
                        if(!put_replaced) count<=count+CW'(1);
                        respond(RESULT,OK,put_replaced,query_key,query_value,
                                put_replaced?count:count+CW'(1));
                    end
                    DEL_FINISH: begin
                        count<=count-CW'(1);
                        respond(RESULT,OK,1,query_key,query_value,count-CW'(1));
                    end
                    R_REQ: if(ram_req_ready) state<=R_WAIT;
                    R_WAIT: if(ram_rsp_valid) begin row<=ram_rsp_data;state<=R_CHECK;end
                    R_CHECK: if(greater) respond(END,OK,0,0,0,count);
                             else respond(ROW,OK,1,row_key,row_value,count);
                    OUT: if(m_ready) begin
                        if(response_kind==ROW) begin
                            if(index+CW'(1)<count) begin
                                index<=index+CW'(1);read_addr<=index+CW'(1);state<=R_REQ;
                            end else respond(END,OK,0,0,0,count);
                        end else state<=IDLE;
                    end
                    default: begin count<=0;state<=IDLE;end
                endcase
            end
        end
`ifndef SYNTHESIS
        always @(posedge clk) if(rst_n && ram_rsp_valid && waiting && ram_rsp_error)
            $fatal(1,"ram_ordered_dictionary internal out-of-range RAM request");
`endif
    end endgenerate
endmodule
