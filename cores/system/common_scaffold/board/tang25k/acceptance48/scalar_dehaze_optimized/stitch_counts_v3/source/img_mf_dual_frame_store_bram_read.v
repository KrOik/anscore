// Fixed-size dual frame store. Development draft; memory is synchronously read.
module img_mf_dual_frame_store_bram_read #(
    parameter WIDTH=32, HEIGHT=24, DATA_WIDTH=24, TAG_WIDTH=16,
    parameter FRAME_WIDTH=16, CAPTURE_TIMEOUT=65536, CHECK_TAG=1
) (
    input wire clk, rst_n, clk_en,
    input wire cmd_valid, output wire cmd_ready,
    input wire [3:0] cmd_opcode, input wire [FRAME_WIDTH-1:0] cmd_frameid,
    output reg rsp_valid, input wire rsp_ready, output reg rsp_done,
    output reg [3:0] rsp_opcode, output reg [FRAME_WIDTH-1:0] rsp_frameid,
    output reg [7:0] rsp_error, output reg [7:0] error_code,
    input wire s_valid, output wire s_ready, input wire [DATA_WIDTH-1:0] s_data,
    input wire s_sof, s_eol, input wire [TAG_WIDTH-1:0] s_tag,
    input wire [FRAME_WIDTH-1:0] s_frameid,
    input wire aux_valid, output wire aux_ready, input wire [DATA_WIDTH-1:0] aux_data,
    input wire aux_sof, aux_eol, input wire [TAG_WIDTH-1:0] aux_tag,
    input wire [FRAME_WIDTH-1:0] aux_frameid,
    output reg m_valid, input wire m_ready, output reg [DATA_WIDTH-1:0] m_data,
    output reg [DATA_WIDTH-1:0] m_aux_data, output reg m_pair,
    output reg m_sof, m_eol, output reg [TAG_WIDTH-1:0] m_tag,
    output reg [FRAME_WIDTH-1:0] m_frameid, output reg [7:0] m_error,
    output reg [1:0] frames_valid,
    input wire rd_valid, output wire rd_ready, input wire [31:0] rd_addr0, rd_addr1,
    output reg rd_rsp_valid, input wire rd_rsp_ready,
    output reg [DATA_WIDTH-1:0] rd_data0, rd_data1, output reg [7:0] rd_error,
    input wire wr_valid, output wire wr_ready, input wire wr_bank,
    input wire [31:0] wr_addr, input wire [DATA_WIDTH-1:0] wr_data
);
    localparam PIXELS=WIDTH*HEIGHT;
    localparam IDLE=0, CAPTURE=1, LOAD=2, SEND=3, COPY_LOAD=4, COPY_WRITE=5, LOAD_WAIT=6, COPY_WAIT=7;
    reg [2:0] state;
    reg [3:0] operation;
    reg [FRAME_WIDTH-1:0] target_frame, frame0, frame1;
    // Counters cannot advance beyond the last valid pixel/column/timeout.
    localparam IW=(PIXELS>1&&PIXELS<=65536)?$clog2(PIXELS):1;
    localparam XW=(WIDTH>1&&WIDTH<=65536)?$clog2(WIDTH):1;
    localparam TIME_W=(CAPTURE_TIMEOUT>1)?$clog2(CAPTURE_TIMEOUT):1;
    reg [IW-1:0] index;
    reg [XW-1:0] x;
    reg [TIME_W-1:0] idle_cycles;
    (* ram_style="block",syn_ramstyle="block_ram" *) reg [DATA_WIDTH-1:0] mem0 [0:PIXELS-1];
    (* ram_style="block",syn_ramstyle="block_ram" *) reg [DATA_WIDTH-1:0] mem1 [0:PIXELS-1];
    reg [DATA_WIDTH-1:0] bank0_q,bank1_q;
    reg rd_pending;
    localparam AW=(PIXELS>1&&PIXELS<=65536)?$clog2(PIXELS):1;
    reg [AW-1:0] rd_addr0_q,rd_addr1_q;
    reg rd_read_pending,rd_publish_pending;
    reg [7:0] rd_error_q;
    reg [DATA_WIDTH-1:0] copy_data;
    wire [DATA_WIDTH-1:0] initial_background={copy_data[7:0],8'd0};
    wire params_ok = WIDTH>0 && HEIGHT>0 && PIXELS>0 && PIXELS<=65536 && TAG_WIDTH>=16 && CAPTURE_TIMEOUT>0;
    wire cap0 = operation==0 || operation==2;
    wire cap1 = operation==1 || operation==2;
    assign cmd_ready = rst_n && clk_en && state==IDLE && !rsp_valid && !m_valid && !rd_rsp_valid && !rd_pending;
    assign s_ready = rst_n && clk_en && state==CAPTURE && cap0 && (!cap1 || aux_valid);
    assign aux_ready = rst_n && clk_en && state==CAPTURE && cap1 && (!cap0 || s_valid);
    wire capture_fire = state==CAPTURE && ((!cap0 || (s_valid && s_ready)) && (!cap1 || (aux_valid && aux_ready)));
    wire [TAG_WIDTH-1:0] index_tag = index;
    wire bad0 = cap0 && ((s_sof != (index==0)) || (s_eol != (x==WIDTH-1)) ||
        s_frameid!=target_frame || (CHECK_TAG && s_tag!=index_tag));
    wire bad1 = cap1 && ((aux_sof != (index==0)) || (aux_eol != (x==WIDTH-1)) ||
        aux_frameid!=target_frame || (CHECK_TAG && aux_tag!=index_tag));
    wire capture_bad = bad0 || bad1;
    assign rd_ready = rst_n && clk_en && state==IDLE && !rsp_valid && !cmd_valid && !rd_pending && (!rd_rsp_valid || rd_rsp_ready);
    assign wr_ready = rst_n && clk_en && state!=CAPTURE && state!=COPY_LOAD && state!=COPY_WRITE && state!=COPY_WAIT && (!cmd_valid || state!=IDLE);
    wire rd_fire = rd_valid && rd_ready;
    wire wr_fire = wr_valid && wr_ready;
    wire [7:0] random_error = (frames_valid!=2'b11) ? 8'h04 :
        ((rd_addr0>=PIXELS || rd_addr1>=PIXELS) ? 8'h10 : 8'd0);
    // No memory reset loops. Banks expose synchronous read and write operations.
    always @(posedge clk) if (clk_en && rst_n) begin
        // Read data registers deliberately have no asynchronous reset. Control
        // waits one enabled edge before consuming them; RAM contents become
        // inaccessible after reset until frames_valid is set by a full capture.
        // Request address/range/error is captured before this enabled edge.
        // Thus the external address comparator never drives a RAM CE in the
        // accepting cycle. Registered error retains missing-frame precedence.
        // As in the existing store contract, callers avoid same-address random
        // read/write hazards while a read is outstanding.
        if(state==LOAD || state==COPY_LOAD || (rd_read_pending && rd_error_q==0))
            bank0_q<=mem0[rd_read_pending?rd_addr0_q:index];
        if(state==LOAD || (rd_read_pending && rd_error_q==0))
            bank1_q<=mem1[rd_read_pending?rd_addr1_q:index];
        if (capture_fire && !capture_bad) begin
            if (cap0) mem0[index] <= s_data;
            if (cap1) mem1[index] <= aux_data;
        end
        if (wr_fire && wr_addr<PIXELS) begin
            if (wr_bank) mem1[wr_addr] <= wr_data;
            else mem0[wr_addr] <= wr_data;
        end
        if (state==COPY_WRITE) mem1[index]<=initial_background;
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=IDLE; operation<=0; target_frame<=0; frame0<=0; frame1<=0;
            index<=0; x<=0; idle_cycles<=0; frames_valid<=0; copy_data<=0;
            rsp_valid<=0; rsp_done<=0; rsp_opcode<=0; rsp_frameid<=0; rsp_error<=0; error_code<=0;
            m_valid<=0; m_data<=0; m_aux_data<=0; m_pair<=0; m_sof<=0; m_eol<=0; m_tag<=0; m_frameid<=0; m_error<=0;
            rd_pending<=0;rd_error_q<=0;
            rd_addr0_q<=0;rd_addr1_q<=0;rd_read_pending<=0;rd_publish_pending<=0;
            rd_rsp_valid<=0; rd_data0<=0; rd_data1<=0; rd_error<=0;
        end else if (clk_en) begin
            if (rsp_valid && rsp_ready) begin rsp_valid<=0; rsp_done<=0; end
            if (rd_rsp_valid && rd_rsp_ready) rd_rsp_valid<=0;
            if (wr_fire && wr_addr>=PIXELS) error_code<=error_code|8'h10;
            if(rd_publish_pending)begin
                rd_pending<=0;rd_rsp_valid<=1;rd_error<=rd_error_q;
                rd_publish_pending<=0;
                rd_data0<=(rd_error_q==0)?bank0_q:0;
                rd_data1<=(rd_error_q==0)?bank1_q:0;
            end
            if(rd_read_pending)begin rd_read_pending<=0;rd_publish_pending<=1;end
            if(rd_fire)begin
                rd_pending<=1;rd_read_pending<=1;rd_error_q<=random_error;
                rd_addr0_q<=rd_addr0[AW-1:0];rd_addr1_q<=rd_addr1[AW-1:0];
                if(random_error!=0)error_code<=error_code|random_error;
            end
            case (state)
                IDLE: if (cmd_valid && cmd_ready) begin
                    operation<=cmd_opcode; target_frame<=cmd_frameid; index<=0; x<=0; idle_cycles<=0;
                    rsp_opcode<=cmd_opcode; rsp_frameid<=cmd_frameid; rsp_error<=0;
                    if (!params_ok) begin rsp_valid<=1; rsp_done<=1; rsp_error<=8'h40; error_code<=error_code|8'h40; end
                    else case (cmd_opcode)
                        0,1,2: begin
                            state<=CAPTURE;
                            if (cmd_opcode!=1) frames_valid[0]<=0;
                            if (cmd_opcode!=0) frames_valid[1]<=0;
                        end
                        3,4,5: begin
                            if ((cmd_opcode==3 && frames_valid!=3) || (cmd_opcode==4 && !frames_valid[0]) ||
                                (cmd_opcode==5 && !frames_valid[1])) begin
                                rsp_valid<=1; rsp_done<=1; rsp_error<=8'h04; error_code<=error_code|8'h04;
                            end else state<=LOAD;
                        end
                        6: begin frames_valid<=0; rsp_valid<=1; rsp_done<=1; end
                        7: begin
                            if (!frames_valid[0]) begin rsp_valid<=1; rsp_done<=1; rsp_error<=8'h04; error_code<=error_code|8'h04; end
                            else if (DATA_WIDTH<16) begin rsp_valid<=1; rsp_done<=1; rsp_error<=8'h40; error_code<=error_code|8'h40; end
                            else begin frames_valid[1]<=0; state<=COPY_LOAD; end
                        end
                        default: begin rsp_valid<=1; rsp_done<=1; rsp_error<=8'h80; error_code<=error_code|8'h80; end
                    endcase
                end
                CAPTURE: begin
                    if (capture_fire) begin
                        idle_cycles<=0;
                        if (capture_bad) begin
                            state<=IDLE; rsp_valid<=1; rsp_done<=1; rsp_error<=8'h01; error_code<=error_code|8'h01;
                        end else if (index==PIXELS-1) begin
                            if (cap0) begin frames_valid[0]<=1; frame0<=target_frame; end
                            if (cap1) begin frames_valid[1]<=1; frame1<=target_frame; end
                            state<=IDLE; rsp_valid<=1; rsp_done<=1;
                        end else begin index<=index+1; x<=(x==WIDTH-1)?0:x+1; end
                    end else if (idle_cycles>=CAPTURE_TIMEOUT-1) begin
                        state<=IDLE; rsp_valid<=1; rsp_done<=1; rsp_error<=8'h02; error_code<=error_code|8'h02;
                    end else idle_cycles<=idle_cycles+1;
                end
                LOAD: state<=LOAD_WAIT;
                LOAD_WAIT: begin
                    m_valid<=1; m_pair<=operation==3;
                    if (operation==5) m_data<=bank1_q; else m_data<=bank0_q;
                    if (operation==3) m_aux_data<=bank1_q; else m_aux_data<=0;
                    m_sof<=index==0; m_eol<=x==WIDTH-1; m_tag<=index_tag;
                    m_frameid<=target_frame; m_error<=0; state<=SEND;
                end
                SEND: if (m_valid && m_ready) begin
                    m_valid<=0;
                    if (index==PIXELS-1) begin state<=IDLE; rsp_valid<=1; rsp_done<=1; end
                    else begin index<=index+1; x<=(x==WIDTH-1)?0:x+1; state<=LOAD; end
                end
                COPY_LOAD: state<=COPY_WAIT;
                COPY_WAIT: begin copy_data<=bank0_q; state<=COPY_WRITE; end
                COPY_WRITE: begin
                    if (index==PIXELS-1) begin
                        frames_valid[1]<=1; frame1<=target_frame; state<=IDLE; rsp_valid<=1; rsp_done<=1;
                    end else begin index<=index+1; state<=COPY_LOAD; end
                end
                default: begin state<=IDLE; rsp_valid<=1; rsp_done<=1; rsp_error<=8'h40; error_code<=error_code|8'h40; end
            endcase
        end
    end
endmodule
