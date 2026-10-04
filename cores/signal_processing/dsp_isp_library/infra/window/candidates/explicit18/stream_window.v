// VALID-region window foundation; no implicit padding or border replication.
// K line banks include current-row scratch, avoiding useful read/write collision.
module stream_window #(
    parameter DATA_WIDTH=8, WIDTH=32, HEIGHT=24, K=3
)(
    input wire clk, rst_n,
    input wire [DATA_WIDTH-1:0] s_tdata,
    input wire s_tvalid, s_tuser, s_tlast,
    output wire s_tready,
    output reg [K*K*DATA_WIDTH-1:0] m_tdata,
    output reg m_tvalid, m_tuser, m_tlast,
    input wire m_tready,
    output reg marker_error
);
    localparam XW=(WIDTH<2)?1:$clog2(WIDTH);
    localparam YW=(HEIGHT<2)?1:$clog2(HEIGHT);
    localparam BW=$clog2(K);
    reg [XW-1:0] x, px;
    reg [YW-1:0] y, py;
    reg [BW-1:0] bank, pbank;
    reg pending;
    reg [DATA_WIDTH-1:0] pixel;
    wire advance = !m_tvalid || m_tready;
    assign s_tready = rst_n && advance;
    wire take = s_tvalid && s_tready;
    wire [K*DATA_WIDTH-1:0] ram_q;
    genvar b;
    generate for(b=0;b<K;b=b+1) begin: banks
        // Diagnostic candidate: read only non-writing banks. Current-row value
        // is forwarded from pixel, never from a read/write collision response.
        wire [17:0] q;
        wire [9:0] addr=x;
        DPX9B #(.BIT_WIDTH_0(18),.BIT_WIDTH_1(18),.BLK_SEL_0(3'b000),.BLK_SEL_1(3'b000),.RESET_MODE("ASYNC")) line_ram(
        .BLKSELA(3'b000),.BLKSELB(3'b000),
        .CLKA(clk),.CEA(1'b1),.WREA(take && bank==b),.RESETA(1'b0),
        .ADA({addr,2'b00,2'b11}),.DIA({{(18-DATA_WIDTH){1'b0}},s_tdata}),.DOA(),
        .CLKB(clk),.CEB(take && bank!=b),.WREB(1'b0),.RESETB(1'b0),
        .ADB({addr,4'b0000}),.DIB(18'b0),.DOB(q),.OCEA(1'b0),.OCEB(1'b0));
        assign ram_q[b*DATA_WIDTH +: DATA_WIDTH]=q[DATA_WIDTH-1:0];
    end endgenerate
    reg [DATA_WIDTH-1:0] history [0:K*(K-1)-1];
    reg [DATA_WIDTH-1:0] column;
    integer row, col, rb;
    always @(posedge clk) begin
        if(!rst_n) begin
            x<=0; y<=0; bank<=0; pending<=0;
            m_tvalid<=0; m_tuser<=0; m_tlast<=0;
            marker_error<=0;
        end else if(advance) begin
            pending<=take;
            m_tvalid<=0;
            if(take) begin
                px<=x; py<=y; pbank<=bank; pixel<=s_tdata;
                if(s_tuser != ((x==0)&&(y==0)) || s_tlast != (x==WIDTH-1))
                    marker_error<=1;
                if(x==WIDTH-1) begin
                    x<=0;
                    if(y==HEIGHT-1) begin y<=0; bank<=0; end
                    else begin
                        y<=y+1'b1;
                        bank <= (bank==K-1)?0:bank+1'b1;
                    end
                end else x<=x+1'b1;
            end
            if(pending) begin
                for(row=0;row<K;row=row+1) begin
                    rb=pbank+row+1;
                    if(rb>=K) rb=rb-K;
                    column=(row==K-1)?pixel:ram_q[rb*DATA_WIDTH +: DATA_WIDTH];
                    for(col=0;col<K-1;col=col+1) begin
                        if(px==0) history[row*(K-1)+col]<=0;
                        else if(col<K-2)
                            history[row*(K-1)+col]<=history[row*(K-1)+col+1];
                        m_tdata[(row*K+col)*DATA_WIDTH +: DATA_WIDTH]
                            <=history[row*(K-1)+col];
                    end
                    history[row*(K-1)+K-2]<=column;
                    m_tdata[(row*K+K-1)*DATA_WIDTH +: DATA_WIDTH]<=column;
                end
                if(px>=K-1 && py>=K-1) begin
                    m_tvalid<=1;
                    m_tuser<=(px==K-1)&&(py==K-1);
                    m_tlast<=(px==WIDTH-1);
                end
            end
        end
    end
    initial begin
        if((K!=3 && K!=5) || WIDTH<1 || WIDTH>1024 || HEIGHT<1 || DATA_WIDTH<1 || DATA_WIDTH>16)
            $fatal(1,"unsupported stream_window parameters");
    end
endmodule
