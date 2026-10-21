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
        (* ram_style="registers" *) reg [DATA_WIDTH-1:0] mem [0:WIDTH-1];
        reg [DATA_WIDTH-1:0] q;
        // No RAM reset. The current bank's collision result is never consumed.
        always @(posedge clk) if(take) begin
            q <= mem[x];
            if(bank==b) mem[x] <= s_tdata;
        end
        assign ram_q[b*DATA_WIDTH +: DATA_WIDTH]=q;
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
                        // px==0 has no pending output (px<K-1 suppresses), so no
                        // boundary zero is needed here; GW2A synthesis mis-ordered
                        // that conditional write against history[..+K-2]<=column.
                        if(col<K-2)
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
        if((K!=3 && K!=5) || WIDTH<1 || HEIGHT<1 || DATA_WIDTH<1 || DATA_WIDTH>16)
            $fatal(1,"unsupported stream_window parameters");
    end
endmodule
