// SPDX-License-Identifier: Apache-2.0
// Packed, network-order fixed 20-byte IPv4 header -> real checksum atom -> core.
module ipv4_header_reassembly #(
    parameter integer MAX_BYTES=512, TAG_W=8,
    parameter integer CW=$clog2(MAX_BYTES+1)
)(
    input wire clk,rst,
    input wire h_valid,output wire h_ready,input wire [1:0] h_op,
    input wire [159:0] h_header,input wire [TAG_W-1:0] h_tag,
    input wire s_valid,output wire s_ready,input wire [7:0] s_data,input wire s_last,
    output wire d_valid,input wire d_ready,output wire [3:0] d_status,
    output wire d_complete,d_active,output wire [CW-1:0] d_filled,d_total,
    output wire [TAG_W-1:0] d_tag,
    output wire m_valid,input wire m_ready,output wire [7:0] m_data,output wire m_last,
    output wire [CW-1:0] m_length,output wire [31:0] m_src,m_dst,
    output wire [15:0] m_id,output wire [7:0] m_protocol,output wire [TAG_W-1:0] m_tag
);
    localparam [2:0] IDLE=0,SEND=1,WAIT_SUM=2,ISSUE=3,CORE=4,LOCAL=5,DRAIN=6;
    reg [2:0] state;
    reg [159:0] header;
    reg [1:0] op;
    reg [2:0] step;
    reg [TAG_W-1:0] tag;
    reg [3:0] local_status;
    reg snapshot_active;
    reg [CW-1:0] snapshot_filled,snapshot_total;
    wire sum_ready,sum_valid,sum_fault;
    wire [31:0] sum_result,sum_aux;
    wire [31:0] a=step==0?header[159:128]:step==1?header[127:96]:
                      step==2?header[95:64]:step==3?header[63:32]:header[31:0];
    wire [31:0] b=0;
    // Fold after each pair: previous fold + two U16 words <=196605.
    // This avoids the atom's separately reported 18-bit carry diagnostic.
    wire [31:0] c=step==0?32'hc0000000:step==4?32'h60000000:32'h40000000;
    acc_ipv4_hdr_csum checksum (
        .clk(clk),.rst_n(!rst),.clk_en(1'b1),.in_valid(state==SEND && !rst),.in_ready(sum_ready),
        .a(a),.b(b),.c(c),.out_valid(sum_valid),.out_ready(state==WAIT_SUM),
        .result(sum_result),.aux(sum_aux),.fault(sum_fault)
    );
    wire cr,cv,cc,ca; wire [3:0] cs; wire [CW-1:0] cf,ct; wire [TAG_W-1:0] ctag;
    wire core_s_ready;
    ipv4_fragment_reassembly #(.MAX_BYTES(MAX_BYTES),.TAG_W(TAG_W)) core (
        .clk(clk),.rst(rst),.c_valid(state==ISSUE),.c_ready(cr),.c_op(op),
        .c_src(header[63:32]),.c_dst(header[31:0]),.c_id(header[127:112]),
        .c_protocol(header[87:80]),.c_offset8(header[108:96]),.c_more(header[109]),
        .c_length(header[143:128]-16'd20),.c_tag(tag),
        .s_valid(s_valid && state==CORE),.s_ready(core_s_ready),.s_data(s_data),.s_last(s_last),
        .d_valid(cv),.d_ready(d_ready && state==CORE),.d_status(cs),.d_complete(cc),.d_active(ca),
        .d_filled(cf),.d_total(ct),.d_tag(ctag),
        .m_valid(m_valid),.m_ready(m_ready),.m_data(m_data),.m_last(m_last),
        .m_length(m_length),.m_src(m_src),.m_dst(m_dst),.m_id(m_id),.m_protocol(m_protocol),.m_tag(m_tag)
    );
    wire header_bad=header[159:152]!=8'h45 || header[143:128]<21 || header[95:88]==0 ||
        header[111] || (header[110] && (header[109] || header[108:96]!=0));
    assign h_ready=!rst && state==IDLE;
    assign s_ready=!rst && state==CORE && core_s_ready;
    assign d_valid=!rst && ((state==CORE && cv) || state==LOCAL);
    assign d_status=state==LOCAL?local_status:cs;
    assign d_complete=state==CORE && cc;
    assign d_active=state==LOCAL?snapshot_active:ca;
    assign d_filled=state==LOCAL?snapshot_filled:cf;
    assign d_total=state==LOCAL?snapshot_total:ct;
    assign d_tag=state==LOCAL?tag:ctag;
    always @(posedge clk) begin
        if(rst) begin state<=IDLE;header<=0;op<=0;step<=0;tag<=0;local_status<=0;
            snapshot_active<=0;snapshot_filled<=0;snapshot_total<=0; end
        else case(state)
            IDLE:if(h_valid) begin
                header<=h_header;op<=h_op;tag<=h_tag;step<=0;
                state<=h_op==0?SEND:ISSUE;
            end
            SEND:if(sum_ready) state<=WAIT_SUM;
            WAIT_SUM:if(sum_valid) begin
                if(step==4) begin
                    if(header_bad || sum_fault || !sum_aux[21]) begin local_status<=8;state<=LOCAL;end
                    else state<=ISSUE;
                end else begin step<=step+1'b1;state<=SEND;end
            end
            ISSUE:if(cr) state<=CORE;
            CORE:if(cv && d_ready) begin
                snapshot_active<=ca;snapshot_filled<=cf;snapshot_total<=ct;
                state<=cc?DRAIN:IDLE;
            end
            LOCAL:if(d_ready) state<=IDLE;
            DRAIN:if(m_valid && m_ready && m_last) begin
                snapshot_active<=0;snapshot_filled<=0;snapshot_total<=0;state<=IDLE;
            end
            default:state<=IDLE;
        endcase
    end
    generate if(CW!=$clog2(MAX_BYTES+1)) begin:invalid
        ipv4_header_reassembly_invalid_parameters__see_README reject();
    end endgenerate
endmodule
