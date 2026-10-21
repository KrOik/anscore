// functional_minimal: packet-aware round-robin, output elastic register.
// A selected input owns the arbiter until an accepted LAST, including gaps.
module sb_stream_rr_arbiter #(
    parameter PORTS=4,parameter DATA_WIDTH=32,parameter USER_WIDTH=1
)(
    input wire clk,rst_n,clk_en,
    input wire [PORTS*DATA_WIDTH-1:0] s_data,
    input wire [PORTS*(DATA_WIDTH/8)-1:0] s_keep,
    input wire [PORTS*USER_WIDTH-1:0] s_user,
    input wire [PORTS-1:0] s_last,s_valid,output reg [PORTS-1:0] s_ready,
    output wire [DATA_WIDTH-1:0] m_data,output wire [DATA_WIDTH/8-1:0] m_keep,
    output wire [USER_WIDTH-1:0] m_user,output wire m_last,m_valid,input wire m_ready
);
    localparam IW=(PORTS<2)?1:$clog2(PORTS);
    reg [IW-1:0] cursor,owner;
    reg locked,found;
    integer chosen,k,probe;
    wire selected_ready;
    always @* begin
        chosen=owner; found=locked; probe=0;
        if(!locked) begin
            chosen=0;
            for(k=0;k<PORTS;k=k+1) begin
                probe=cursor+k;
                if(probe>=PORTS) probe=probe-PORTS;
                if(!found&&s_valid[probe]) begin chosen=probe;found=1;end
            end
        end
        s_ready=0;
        if(found) s_ready[chosen]=selected_ready;
    end
    sb_stream_elastic #(.DATA_WIDTH(DATA_WIDTH),.USER_WIDTH(USER_WIDTH)) out_i(
        .clk(clk),.rst_n(rst_n),.clk_en(clk_en),
        .s_data(s_data[chosen*DATA_WIDTH+:DATA_WIDTH]),
        .s_keep(s_keep[chosen*(DATA_WIDTH/8)+:(DATA_WIDTH/8)]),
        .s_user(s_user[chosen*USER_WIDTH+:USER_WIDTH]),.s_last(s_last[chosen]),
        .s_valid(found&&s_valid[chosen]),.s_ready(selected_ready),
        .m_data(m_data),.m_keep(m_keep),.m_user(m_user),
        .m_last(m_last),.m_valid(m_valid),.m_ready(m_ready));
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin cursor<=0;owner<=0;locked<=0;end
        else if(clk_en&&found&&s_valid[chosen]&&selected_ready) begin
            if(s_last[chosen]) begin
                locked<=0;cursor<=(chosen==PORTS-1)?0:chosen+1;
            end else begin locked<=1;owner<=chosen;end
        end
    end
    initial if(PORTS<1) $fatal(1,"sb_stream_rr_arbiter: PORTS>=1 required");
endmodule
