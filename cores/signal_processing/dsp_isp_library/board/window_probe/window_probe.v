// External packet -> bounded synchronous RAM -> stream_window_padded -> RAM -> UART.
// Isolated sliding-window memory qualification harness. Every K*K window record
// (all lanes plus SOF/EOL) is exported per output position; nothing is reduced
// to a digest, so a divergent lane identifies both position and window element.
//
// Request : "WPR1" tag u32 config u32 count u16 stall u8, then count pixel bytes.
//           count must be a nonzero multiple of WIDTH*HEIGHT (1..CAP frames),
//           stall 0..7, config must be 0. Whole frames only.
// Response: "WPO1" tag u32 config u32 count u16 flags u8 in_count u16
//           out_count u16 cycles u32, then out_count records of REC_BYTES each:
//           record = {pad0, sof, eol, window[K*K*DATA_WIDTH-1:0]} little-endian.
// flags: bit0 invalid count/stall, bit1 UART framing, bit2 busy RX (sticky),
//        bit3 invalid config, bit4 watchdog, bit5 window marker_error (sticky).
module window_probe #(
    parameter DATA_WIDTH=8, WIDTH=8, HEIGHT=8, K=3, PAD_MODE=1,
    parameter INPUT_DEPTH=2048, OUTPUT_DEPTH=2048, WATCHDOG=65535
)(
    input wire clk, uart_rx_pin,
    output wire uart_tx, dbg_uart);
    localparam PIX=WIDTH*HEIGHT;
    localparam CAP=(INPUT_DEPTH<OUTPUT_DEPTH)?INPUT_DEPTH:OUTPUT_DEPTH;
    localparam REC_BITS=K*K*DATA_WIDTH+2;
    localparam REC_BYTES=(REC_BITS+7)/8;
    localparam RECW=REC_BYTES*8;
    localparam XW=(WIDTH<2)?1:$clog2(WIDTH);
    localparam YW=(HEIGHT<2)?1:$clog2(HEIGHT);
    localparam IBW=$clog2(INPUT_DEPTH);
    localparam OBW=$clog2(OUTPUT_DEPTH);
    reg [12:0] por=0;
    always @(posedge clk) if(!por[12]) por<=por+1'b1;
    wire rst_n=por[12];
    localparam LOAD=0,RESET=1,PREFETCH=4,RUN=5,HEADER=6,READ=7,DATA=8;
    reg [3:0] state=LOAD;
    reg [7:0] index,stall,flags;
    reg [15:0] byte_index,count,input_count,output_count,read_index;
    reg [31:0] tag,config_word,cycles;
    reg [2:0] phase;
    reg [XW-1:0] in_x;
    reg [YW-1:0] in_y;
    wire [7:0] input_q;
    wire [RECW-1:0] output_q;
    wire [7:0] rx_data;
    wire rx_valid,rx_error;
    uart_rx rx(.clk(clk),.rst_n(rst_n),.clk_en(1'b1),.rx_pin(uart_rx_pin),
        .rx_data(rx_data),.rx_valid(rx_valid),.rx_ack(rx_valid),.framing_err(rx_error));
    wire in_ready,win_valid,win_user,win_last,marker_err;
    wire [K*K*DATA_WIDTH-1:0] win_data;
    wire in_valid=state==RUN && input_count<count;
    wire out_ready=state==RUN && phase>=stall[2:0];
    wire input_fire=in_valid && in_ready;
    wire output_fire=win_valid && out_ready;
    wire core_reset=rst_n && state!=RESET;
    stream_window_padded #(
        .DATA_WIDTH(DATA_WIDTH),.WIDTH(WIDTH),.HEIGHT(HEIGHT),.K(K),.PAD_MODE(PAD_MODE)
    ) dut(
        .clk(clk),.rst_n(core_reset),
        .s_tdata(input_q[DATA_WIDTH-1:0]),.s_tvalid(in_valid),
        .s_tuser(in_x==0 && in_y==0),.s_tlast(in_x==WIDTH-1),.s_tready(in_ready),
        .m_tdata(win_data),.m_tvalid(win_valid),.m_tuser(win_user),.m_tlast(win_last),
        .m_tready(out_ready),.marker_error(marker_err));
    // Dedicated synchronous RAM processes: never reset storage.
    // Present input_count while idle; +1 lookahead only during the take cycle.
    wire input_read=state==PREFETCH || in_valid;
    wire [IBW-1:0] input_address=state==PREFETCH ? {IBW{1'b0}} :
        (input_fire ? input_count[IBW-1:0]+1'b1 : input_count[IBW-1:0]);
    wire input_write=rst_n && state==LOAD && rx_valid && !rx_error && index>=15;
    probe_ram #(.WIDTH(8),.DEPTH(INPUT_DEPTH)) input_store(
        .clk(clk),.we(input_write),.waddr(byte_index[IBW-1:0]),.wdata(rx_data),
        .re(input_read),.raddr(input_address),.q(input_q));
    probe_ram #(.WIDTH(RECW),.DEPTH(OUTPUT_DEPTH)) output_store(
        .clk(clk),.we(output_fire),.waddr(output_count[OBW-1:0]),
        .wdata({{(RECW-REC_BITS){1'b0}},win_user,win_last,win_data}),
        .re(state==READ),.raddr(read_index[OBW-1:0]),.q(output_q));
    reg [7:0] tx_data;
    wire tx_ready;
    wire tx_valid=state==HEADER || state==DATA;
    uart_tx tx(.clk(clk),.rst_n(rst_n),.tx_data(tx_data),.tx_data_valid(tx_valid),
        .tx_data_ready(tx_ready),.tx_pin(uart_tx),.tx_busy());
    assign dbg_uart=uart_tx;
    always @* begin
        tx_data=0;
        if(state==DATA) tx_data=output_q>>(8*byte_index[5:0]);
        else case(index)
            0:tx_data="W";1:tx_data="P";2:tx_data="O";3:tx_data="1";
            4,5,6,7:tx_data=tag>>(8*(index-4));
            8,9,10,11:tx_data=config_word>>(8*(index-8));
            12,13:tx_data=count>>(8*(index-12));
            14:tx_data=flags;
            15,16:tx_data=input_count>>(8*(index-15));
            17,18:tx_data=output_count>>(8*(index-17));
            19,20,21,22:tx_data=cycles>>(8*(index-19));
        endcase
    end
    always @(posedge clk) begin
        if(!rst_n) begin
            state<=LOAD;index<=0;byte_index<=0;count<=0;stall<=0;flags<=0;
            tag<=0;config_word<=0;cycles<=0;input_count<=0;output_count<=0;
            read_index<=0;phase<=0;in_x<=0;in_y<=0;
        end else begin
            if(rx_error) flags[1]<=1;
            if(marker_err) flags[5]<=1;
            if(rx_valid && state!=LOAD) flags[2]<=1;
            case(state)
            LOAD: if(rx_valid && !rx_error) begin
                case(index)
                0: if(rx_data=="W") begin index<=1;flags<={5'd0,flags[2],2'd0};
                       input_count<=0;output_count<=0;cycles<=0;end
                1: if(rx_data=="P") index<=2;else index<=0;
                2: if(rx_data=="R") index<=3;else index<=0;
                3: if(rx_data=="1") index<=4;else index<=0;
                4,5,6,7: begin tag<={rx_data,tag[31:8]};index<=index+1'b1;end
                8,9,10,11: begin config_word<={rx_data,config_word[31:8]};index<=index+1'b1;end
                12:begin count[7:0]<=rx_data;index<=13;end
                13:begin count[15:8]<=rx_data;index<=14;end
                14:begin
                    if(rx_data>7 || count==0 || count%PIX!=0 || count>CAP) begin
                        flags[0]<=1;count<=0;index<=0;state<=HEADER;
                    end else if(config_word!=0) begin
                        flags[3]<=1;count<=0;index<=0;state<=HEADER;
                    end else begin
                        stall<=rx_data;index<=15;byte_index<=0;
                    end
                end
                default:begin
                    byte_index<=byte_index+1'b1;
                    if(byte_index==count-1'b1) state<=RESET;
                end
                endcase
            end
            RESET:begin
                input_count<=0;output_count<=0;cycles<=0;phase<=0;
                in_x<=0;in_y<=0;state<=PREFETCH;
            end
            PREFETCH:state<=RUN;
            RUN:begin
                cycles<=cycles+1'b1;phase<=phase+1'b1;
                if(input_fire) begin
                    input_count<=input_count+1'b1;
                    if(in_x==WIDTH-1) begin
                        in_x<=0;
                        if(in_y==HEIGHT-1) in_y<=0;else in_y<=in_y+1'b1;
                    end else in_x<=in_x+1'b1;
                end
                if(output_fire) begin
                    output_count<=output_count+1'b1;
                    if(output_count+1==count) begin index<=0;state<=HEADER;end
                end
                if(cycles==WATCHDOG) begin
                    flags[4]<=1;count<=output_count+(output_fire?16'd1:16'd0);
                    index<=0;state<=HEADER;
                end
            end
            HEADER:if(tx_ready) begin
                if(index==22) begin
                    read_index<=0;byte_index<=0;
                    if(count==0) begin state<=LOAD;index<=0;end
                    else state<=READ;
                end else index<=index+1'b1;
            end
            READ:state<=DATA;
            DATA:if(tx_ready) begin
                if(byte_index==REC_BYTES-1) begin
                    byte_index<=0;read_index<=read_index+1'b1;
                    if(read_index+1==count) begin state<=LOAD;index<=0;end
                    else state<=READ;
                end else byte_index<=byte_index+1'b1;
            end
            default:state<=LOAD;
            endcase
        end
    end
    initial begin
        if((K!=3 && K!=5) || WIDTH<1 || HEIGHT<1 || DATA_WIDTH<1 || DATA_WIDTH>8 ||
           (PAD_MODE!=0 && PAD_MODE!=1) || WATCHDOG<256)
            $fatal(1,"unsupported window_probe parameters");
    end
endmodule
