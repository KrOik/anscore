`default_nettype none
// SD v2 SPI host, one synchronous 512-byte buffer. See SD_SPI_REGISTERS.md.
module common_sd_spi #(
    parameter integer CLOCK_DIV = 64,
    parameter integer RESPONSE_TIMEOUT_TICKS = 65535
) (
    input wire clk, input wire rst_n, input wire clk_en,
    input wire cmd_valid, output wire cmd_ready,
    input wire cmd_write, input wire [7:0] cmd_addr, input wire [31:0] cmd_wdata,
    output reg rsp_valid, input wire rsp_ready,
    output reg [31:0] rsp_rdata, output reg [1:0] rsp_error,
    input wire card_present, input wire sd_miso,
    output reg sd_cs_n, output wire sd_sclk, output wire sd_mosi
);
    localparam IDLE=0, CLOCKS=1, CMD_BEGIN=2, CMD_SEND=3, CMD_POLL=4,
        CMD_R1=5, CMD_EXTRA=6, CMD_EXTRA_GOT=7, CMD_RETURN=8,
        INIT0=9, DO8=10, INIT8=11, DO55=12, INIT55=13, DO41=14,
        INIT41=15, DO58=16, INIT58=17, DO16=18, INIT16=19,
        RELEASE=20, FINISH=21, SPI_WAIT=22,
        READ_R1=23, READ_TOKEN=24, READ_TOKEN_GOT=25, READ_BYTE=26,
        READ_GOT=27, READ_CRC_HI=28, READ_CRC_LO=29,
        WRITE_R1=30, WRITE_TOKEN=31, WRITE_LOAD=32, WRITE_BYTE=33,
        WRITE_GOT=34, WRITE_CRC_HI=35, WRITE_CRC_LO=36, WRITE_POLL=37,
        WRITE_RESP=38, BUSY_POLL=39, BUSY_GOT=40, RAW_DONE=41;
    localparam [7:0] E_REMOVED=1, E_TIMEOUT=2, E_R1=3, E_VOLTAGE=4,
        E_TOKEN=5, E_CRC=6, E_WRITE=7, E_CONFIG=8;
    reg [5:0] state, spi_return, command_return, release_return;
    reg engine_busy, initialized, high_capacity, completed, write_completion, read_in_progress;
    reg [7:0] error_code, last_r1;
    reg [31:0] argument, response, ocr, transfer_count, divider;
    reg [5:0] raw_index, command_index;
    reg [1:0] raw_type;
    reg [31:0] command_arg;
    reg [2:0] command_extra, extra_left, packet_index;
    reg [7:0] command_crc, spi_tx, buffer_q;
    reg spi_start, spi_reset;
    wire spi_busy, spi_done;
    wire [7:0] spi_rx;
    reg [7:0] buffer [0:511];
    // Valid bits reset without resetting the data RAM, preserving BRAM inference.
    reg [511:0] buffer_valid;
    reg [8:0] buffer_index, block_index;
    reg read_pending;
    reg [15:0] data_crc, received_crc;
    reg [31:0] timeout_count, init_attempts;
    reg [3:0] clock_count;
    wire [31:0] timeout_limit = (RESPONSE_TIMEOUT_TICKS < 1) ? 1 : RESPONSE_TIMEOUT_TICKS;
    wire command_take = cmd_valid && cmd_ready;
    wire abort_take = command_take && cmd_write && cmd_addr==8'h04 && cmd_wdata==8;
    assign cmd_ready = clk_en && !rsp_valid && !read_pending;
    common_serial_spi_byte serial_byte (
        .clk(clk), .rst_n(rst_n && !spi_reset), .clk_en(1'b1),
        .start(spi_start), .tx_data(spi_tx), .half_period(divider),
        .cpol(1'b0), .cpha(1'b0), .busy(spi_busy), .done(spi_done),
        .rx_data(spi_rx), .sclk(sd_sclk), .mosi(sd_mosi), .miso(sd_miso)
    );
    function [7:0] make_crc7;
        input [39:0] packet;
        reg [6:0] c;
        reg feedback;
        integer i;
        begin
            c=0;
            for (i=39;i>=0;i=i-1) begin
                feedback=c[6]^packet[i]; c={c[5:0],1'b0};
                if(feedback) c=c^7'h09;
            end
            make_crc7={c,1'b1};
        end
    endfunction
    function [15:0] crc16_byte;
        input [15:0] prior;
        input [7:0] data;
        reg [15:0] c;
        integer i;
        begin
            c=prior;
            for(i=7;i>=0;i=i-1) begin
                if(c[15]^data[i]) c={c[14:0],1'b0}^16'h1021;
                else c={c[14:0],1'b0};
            end
            crc16_byte=c;
        end
    endfunction
    task transfer_byte;
        input [7:0] data;
        input [5:0] return_to;
        begin spi_tx<=data; spi_start<=1; spi_return<=return_to; state<=SPI_WAIT; end
    endtask
    task issue_command;
        input [5:0] index;
        input [31:0] arg;
        input [2:0] extra;
        input [5:0] return_to;
        begin
            command_index<=index; command_arg<=arg; command_extra<=extra;
            command_return<=return_to; state<=CMD_BEGIN;
        end
    endtask
    task fail;
        input [7:0] code;
        begin
            error_code<=code; state<=RELEASE; release_return<=FINISH;
            if(read_in_progress) buffer_valid<=0;
        end
    endtask
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE; spi_return<=IDLE; command_return<=IDLE; release_return<=IDLE;
            spi_start<=0; spi_reset<=0; spi_tx<=8'hff; sd_cs_n<=1;
            engine_busy<=0; initialized<=0; high_capacity<=0; completed<=0; write_completion<=0; read_in_progress<=0;
            error_code<=0; last_r1<=8'hff; argument<=0; response<=0; ocr<=0;
            transfer_count<=0; divider<=(CLOCK_DIV<1)?1:CLOCK_DIV;
            raw_index<=0; raw_type<=0; command_index<=0; command_arg<=0;
            command_extra<=0; extra_left<=0; packet_index<=0; command_crc<=0;
            buffer_index<=0; block_index<=0; buffer_q<=0; read_pending<=0; buffer_valid<=0;
            data_crc<=0; received_crc<=0; timeout_count<=0; init_attempts<=0; clock_count<=0;
            rsp_valid<=0; rsp_rdata<=0; rsp_error<=0;
        end else begin
            spi_start<=0; spi_reset<=0;
            if(rsp_valid && clk_en && rsp_ready) rsp_valid<=0;
            if(read_pending) begin
                rsp_valid<=1; rsp_error<=0; rsp_rdata<={24'b0,buffer_q}; read_pending<=0;
            end
            if(command_take) begin
                rsp_valid<=1; rsp_error<=0; rsp_rdata<=0;
                if(cmd_write) begin
                    case(cmd_addr)
                        8'h04: begin
                            if(cmd_wdata==8) begin
                                spi_reset<=1; sd_cs_n<=1; state<=IDLE;
                                engine_busy<=0; initialized<=0; completed<=1; error_code<=E_CONFIG;
                            end else if(engine_busy) rsp_error<=2;
                            else if(cmd_wdata==0 || cmd_wdata>4) rsp_error<=1;
                            else if(!card_present) begin completed<=1; error_code<=E_REMOVED; end
                            else if((cmd_wdata==2 || cmd_wdata==3) &&
                                    (!initialized || (!high_capacity && argument[31:23]!=0))) rsp_error<=2;
                            else if(cmd_wdata==3 && !(&buffer_valid)) begin
                                rsp_error<=2; completed<=1; error_code<=E_CONFIG;
                            end
                            else begin
                                engine_busy<=1; completed<=0; error_code<=0; timeout_count<=0;
                                write_completion<=0; read_in_progress<=0;
                                if(cmd_wdata==1) begin
                                    initialized<=0; high_capacity<=0; sd_cs_n<=1;
                                    clock_count<=0; init_attempts<=0; state<=CLOCKS;
                                end else if(cmd_wdata==2) begin
                                    // Invalidate at request acceptance, including a command-phase failure.
                                    buffer_valid<=0; read_in_progress<=1;
                                    issue_command(17,high_capacity?argument:(argument<<9),0,READ_R1);
                                end
                                else if(cmd_wdata==3)
                                    issue_command(24,high_capacity?argument:(argument<<9),0,WRITE_R1);
                                else issue_command(raw_index,argument,(raw_type==2)?1:(raw_type==3)?4:0,RAW_DONE);
                            end
                        end
                        8'h08: if(engine_busy) rsp_error<=2; else argument<=cmd_wdata;
                        8'h0c: if(engine_busy) rsp_error<=2; else if(cmd_wdata[31:10]!=0 || cmd_wdata[7:6]!=0) rsp_error<=1;
                               else begin raw_index<=cmd_wdata[5:0]; raw_type<=cmd_wdata[9:8]; end
                        8'h14: if(engine_busy) rsp_error<=2; else if(cmd_wdata>511) rsp_error<=1; else buffer_index<=cmd_wdata[8:0];
                        8'h18: if(engine_busy) rsp_error<=2; else begin
                            buffer[buffer_index]<=cmd_wdata[7:0]; buffer_valid[buffer_index]<=1;
                            buffer_index<=buffer_index+1'b1;
                        end
                        8'h2c: if(engine_busy) rsp_error<=2; else if(cmd_wdata==0) rsp_error<=1; else divider<=cmd_wdata;
                        default: rsp_error<=1;
                    endcase
                end else begin
                    case(cmd_addr)
                        8'h00: rsp_rdata<={8'b0,last_r1,error_code,3'b0,completed,card_present,high_capacity,initialized,engine_busy};
                        8'h08: rsp_rdata<=argument;
                        8'h0c: rsp_rdata<={22'b0,raw_type,2'b0,raw_index};
                        8'h10: rsp_rdata<=response;
                        8'h14: rsp_rdata<={23'b0,buffer_index};
                        8'h18: if(engine_busy || !buffer_valid[buffer_index]) rsp_error<=2; else begin
                            buffer_q<=buffer[buffer_index]; buffer_index<=buffer_index+1'b1;
                            read_pending<=1; rsp_valid<=0;
                        end
                        8'h1c: rsp_rdata<={received_crc,data_crc};
                        8'h24: rsp_rdata<=transfer_count;
                        8'h28: rsp_rdata<=ocr;
                        8'h2c: rsp_rdata<=divider;
                        default: rsp_error<=1;
                    endcase
                end
            end
            // Removing a card also invalidates initialization while the engine is idle.
            if(!card_present) begin initialized<=0; high_capacity<=0; end
            if(engine_busy && !card_present) begin
                state<=IDLE; spi_reset<=1; sd_cs_n<=1; engine_busy<=0;
                initialized<=0; high_capacity<=0; completed<=1; error_code<=E_REMOVED;
                if(read_in_progress) buffer_valid<=0;
                read_in_progress<=0;
            end else if(abort_take) begin
                state<=IDLE; spi_reset<=1; sd_cs_n<=1; engine_busy<=0; initialized<=0;
                if(read_in_progress) buffer_valid<=0;
                read_in_progress<=0;
            end else case(state)
                IDLE: begin end
                SPI_WAIT: if(spi_done) state<=spi_return;
                CLOCKS: begin
                    if(clock_count==10) issue_command(0,0,0,INIT0);
                    else begin clock_count<=clock_count+1'b1; transfer_byte(8'hff,CLOCKS); end
                end
                CMD_BEGIN: begin
                    sd_cs_n<=0; packet_index<=0; response<=0;
                    command_crc<=make_crc7({2'b01,command_index,command_arg}); state<=CMD_SEND;
                end
                CMD_SEND: begin
                    packet_index<=packet_index+1'b1;
                    case(packet_index)
                        0: transfer_byte({2'b01,command_index},CMD_SEND);
                        1: transfer_byte(command_arg[31:24],CMD_SEND);
                        2: transfer_byte(command_arg[23:16],CMD_SEND);
                        3: transfer_byte(command_arg[15:8],CMD_SEND);
                        4: transfer_byte(command_arg[7:0],CMD_SEND);
                        default: begin timeout_count<=0; transfer_byte(command_crc,CMD_POLL); end
                    endcase
                end
                CMD_POLL: transfer_byte(8'hff,CMD_R1);
                CMD_R1: begin
                    if(!spi_rx[7]) begin
                        last_r1<=spi_rx; extra_left<=command_extra;
                        if(command_extra==0) state<=CMD_RETURN; else state<=CMD_EXTRA;
                    end else if(timeout_count>=timeout_limit-1) fail(E_TIMEOUT);
                    else begin timeout_count<=timeout_count+1'b1; state<=CMD_POLL; end
                end
                CMD_EXTRA: transfer_byte(8'hff,CMD_EXTRA_GOT);
                CMD_EXTRA_GOT: begin
                    response<={response[23:0],spi_rx}; extra_left<=extra_left-1'b1;
                    if(extra_left==1) state<=CMD_RETURN; else state<=CMD_EXTRA;
                end
                CMD_RETURN: state<=command_return;
                INIT0: if(last_r1!=1) fail(E_R1); else begin release_return<=DO8; state<=RELEASE; end
                DO8: issue_command(8,32'h000001aa,4,INIT8);
                INIT8: if(last_r1!=1 || response!=32'h000001aa) fail(E_VOLTAGE);
                       else begin release_return<=DO55; state<=RELEASE; end
                DO55: issue_command(55,0,0,INIT55);
                INIT55: if(last_r1!=1 && last_r1!=0) fail(E_R1);
                        else begin release_return<=DO41; state<=RELEASE; end
                DO41: issue_command(41,32'h40000000,0,INIT41);
                INIT41: begin
                    if(last_r1==1) begin
                        if(init_attempts>=timeout_limit-1) fail(E_TIMEOUT);
                        else begin init_attempts<=init_attempts+1'b1; release_return<=DO55; state<=RELEASE; end
                    end else if(last_r1==0) begin release_return<=DO58; state<=RELEASE; end
                    else fail(E_R1);
                end
                DO58: issue_command(58,0,4,INIT58);
                INIT58: begin
                    ocr<=response;
                    if(last_r1!=0 || !response[31] || !(|response[23:15])) fail(E_VOLTAGE);
                    else if(response[30]) begin
                        initialized<=1; high_capacity<=1; release_return<=FINISH; state<=RELEASE;
                    end else begin high_capacity<=0; release_return<=DO16; state<=RELEASE; end
                end
                DO16: issue_command(16,512,0,INIT16);
                INIT16: if(last_r1!=0) fail(E_R1);
                        else begin initialized<=1; state<=RELEASE; release_return<=FINISH; end
                READ_R1: begin
                    if(last_r1!=0) fail(E_R1);
                    else begin
                        block_index<=0; data_crc<=0; timeout_count<=0; state<=READ_TOKEN;
                        buffer_valid<=0; read_in_progress<=1;
                    end
                end
                READ_TOKEN: transfer_byte(8'hff,READ_TOKEN_GOT);
                READ_TOKEN_GOT: begin
                    if(spi_rx==8'hfe) state<=READ_BYTE;
                    else if(spi_rx!=8'hff) fail(E_TOKEN);
                    else if(timeout_count>=timeout_limit-1) fail(E_TIMEOUT);
                    else begin timeout_count<=timeout_count+1'b1; state<=READ_TOKEN; end
                end
                READ_BYTE: transfer_byte(8'hff,READ_GOT);
                READ_GOT: begin
                    buffer[block_index]<=spi_rx; buffer_valid[block_index]<=1;
                    data_crc<=crc16_byte(data_crc,spi_rx);
                    if(block_index==511) transfer_byte(8'hff,READ_CRC_HI);
                    else begin block_index<=block_index+1'b1; state<=READ_BYTE; end
                end
                READ_CRC_HI: begin received_crc[15:8]<=spi_rx; transfer_byte(8'hff,READ_CRC_LO); end
                READ_CRC_LO: begin
                    received_crc[7:0]<=spi_rx;
                    if({received_crc[15:8],spi_rx}!=data_crc) fail(E_CRC);
                    else begin transfer_count<=transfer_count+1'b1; release_return<=FINISH; state<=RELEASE; end
                end
                WRITE_R1: begin
                    if(last_r1!=0) fail(E_R1);
                    else begin block_index<=0; data_crc<=0; write_completion<=1; transfer_byte(8'hff,WRITE_TOKEN); end
                end
                WRITE_TOKEN: transfer_byte(8'hfe,WRITE_LOAD);
                WRITE_LOAD: begin buffer_q<=buffer[block_index]; state<=WRITE_BYTE; end
                WRITE_BYTE: transfer_byte(buffer_q,WRITE_GOT);
                WRITE_GOT: begin
                    data_crc<=crc16_byte(data_crc,buffer_q);
                    if(block_index==511) state<=WRITE_CRC_HI;
                    else begin block_index<=block_index+1'b1; state<=WRITE_LOAD; end
                end
                WRITE_CRC_HI: transfer_byte(data_crc[15:8],WRITE_CRC_LO);
                WRITE_CRC_LO: begin timeout_count<=0; transfer_byte(data_crc[7:0],WRITE_POLL); end
                WRITE_POLL: transfer_byte(8'hff,WRITE_RESP);
                WRITE_RESP: begin
                    if(spi_rx==8'hff && timeout_count<timeout_limit-1) begin timeout_count<=timeout_count+1'b1; state<=WRITE_POLL; end
                    else if(spi_rx==8'hff) fail(E_TIMEOUT);
                    else if((spi_rx&8'h1f)!=5) fail(E_WRITE);
                    else begin timeout_count<=0; state<=BUSY_POLL; end
                end
                BUSY_POLL: transfer_byte(8'hff,BUSY_GOT);
                BUSY_GOT: begin
                    if(spi_rx==8'hff) begin
                        if(write_completion) transfer_count<=transfer_count+1'b1;
                        state<=RELEASE; release_return<=FINISH;
                    end else if(timeout_count>=timeout_limit-1) fail(E_TIMEOUT);
                    else begin timeout_count<=timeout_count+1'b1; state<=BUSY_POLL; end
                end
                RAW_DONE: begin
                    if(raw_type==1 && !last_r1[6:1]) begin timeout_count<=0; state<=BUSY_POLL; end
                    else begin state<=RELEASE; release_return<=FINISH; end
                end
                RELEASE: begin sd_cs_n<=1; transfer_byte(8'hff,release_return); end
                FINISH: begin engine_busy<=0; completed<=1; read_in_progress<=0; state<=IDLE; end
                default: fail(E_CONFIG);
            endcase
        end
    end
endmodule
`default_nettype wire
