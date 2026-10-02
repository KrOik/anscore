// EXPLICIT-PRIMITIVE diagnostic variant of infra/window/stream_window.v.
// Identical stream contract and logic; each of the K line banks is an explicit
// Gowin SPX9 single-port BSRAM with the same parameters the baseline inference
// produces (BIT_WIDTH=9, WRITE_MODE=2 read-before-write, READ_MODE=0,
// RESET_MODE=ASYNC, resets tied off). DATA_WIDTH must be <= 9.
// If the board failure disappears vs the inferred variant, yosys memory
// inference/wiring is implicated; if it persists, the BSRAM hardware behaviour
// itself is implicated.
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
        wire [35:0] dob;
        // Physical 9-bit address: word index in AD[13:3], low 3 bits zero.
        SPX9 #(
            .BIT_WIDTH(9),.WRITE_MODE(2'b10),.READ_MODE(1'b0),
            .BLK_SEL(3'b000),.RESET_MODE("ASYNC")
        ) mem (
            .DO(dob),.DI({{(36-DATA_WIDTH){1'b0}},s_tdata}),.BLKSEL(3'b000),
            .AD({{(11-XW){1'b0}},x,3'b000}),.WRE(take && (bank==b)),.CLK(clk),
            .CE(take),.OCE(1'b0),.RESET(1'b0));
        assign ram_q[b*DATA_WIDTH +: DATA_WIDTH]=dob[DATA_WIDTH-1:0];
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
        if((K!=3 && K!=5) || WIDTH<1 || HEIGHT<1 || DATA_WIDTH<1 || DATA_WIDTH>9)
            $fatal(1,"unsupported stream_window parameters");
    end
endmodule
