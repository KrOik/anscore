`default_nettype none
// SDR command/address + optional dummy clocks + 1/4-lane data transaction.
// 128-byte staging buffer. No flash-vendor opcodes are silently synthesized.
module common_qspi_controller #(
    parameter integer CLOCK_DIV=2, parameter CPOL=1'b0
) (
    input wire clk,rst_n,clk_en,
    input wire cmd_valid,output wire cmd_ready,
    input wire cmd_write,input wire [7:0] cmd_addr,input wire [31:0] cmd_wdata,
    output reg rsp_valid,input wire rsp_ready,
    output reg [31:0] rsp_rdata,output reg [1:0] rsp_error,
    output reg qspi_cs_n,qspi_sclk,
    input wire [3:0] qspi_dq_in,output reg [3:0] qspi_dq_out,qspi_dq_oe
);
    localparam IDLE=0,LOAD=1,CLOCK=2,DUMMY_CLOCK=3,FINISH=4;
    localparam COMMAND=0,ADDRESS=1,DUMMY=2,DATA=3;
    reg [2:0] state;
    reg [1:0] stage;
    reg [7:0] opcode,dummy_cycles;
    reg [31:0] address,divider,timer,shift;
    reg [2:0] addr_bytes;
    reg quad_data,read_data;
    reg [7:0] length,byte_index,dummy_left;
    reg [5:0] bits_left;
    reg [7:0] rx_shift;
    reg [7:0] buffer[0:127];
    reg [127:0] buffer_valid;
    integer j;
    reg all_written;
    wire [4:0] word_index=cmd_addr[6:2]-5'd16;
    wire buffer_address=(cmd_addr>=8'h40 && cmd_addr<=8'hbc && cmd_addr[1:0]==0);
    wire four_lane=(stage==DATA && quad_data);
    assign cmd_ready=!rsp_valid && state==IDLE;
    always @* begin
        all_written=1;
        for(j=0;j<128;j=j+1) if(j<length && !buffer_valid[j]) all_written=0;
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE;stage<=COMMAND;opcode<=0;dummy_cycles<=0;address<=0;
            divider<=(CLOCK_DIV<1)?1:CLOCK_DIV;timer<=0;shift<=0;
            addr_bytes<=0;quad_data<=0;read_data<=0;length<=0;byte_index<=0;
            dummy_left<=0;bits_left<=0;rx_shift<=0;buffer_valid<=0;
            qspi_cs_n<=1;qspi_sclk<=CPOL;qspi_dq_out<=0;qspi_dq_oe<=0;
            rsp_valid<=0;rsp_rdata<=0;rsp_error<=0;
        end else begin
            if(clk_en && rsp_valid && rsp_ready) rsp_valid<=0;
            if(clk_en && cmd_valid && cmd_ready) begin
                rsp_valid<=1;rsp_rdata<=0;rsp_error<=0;
                if(buffer_address) begin
                    if(cmd_write) begin
                        buffer[{word_index,2'b00}]<=cmd_wdata[7:0];
                        buffer[{word_index,2'b00}+1]<=cmd_wdata[15:8];
                        buffer[{word_index,2'b00}+2]<=cmd_wdata[23:16];
                        buffer[{word_index,2'b00}+3]<=cmd_wdata[31:24];
                        buffer_valid[{word_index,2'b00}+:4]<=4'hf;
                    end else if(buffer_valid[{word_index,2'b00}+:4]==0) rsp_error<=3;
                    else rsp_rdata<={
                        buffer_valid[{word_index,2'b00}+3]?buffer[{word_index,2'b00}+3]:8'b0,
                        buffer_valid[{word_index,2'b00}+2]?buffer[{word_index,2'b00}+2]:8'b0,
                        buffer_valid[{word_index,2'b00}+1]?buffer[{word_index,2'b00}+1]:8'b0,
                        buffer_valid[{word_index,2'b00}]?buffer[{word_index,2'b00}]:8'b0};
                end else case(cmd_addr)
                    8'h00: if(!cmd_write) rsp_rdata<={24'b0,opcode};
                        else if(cmd_wdata[31:8]!=0) rsp_error<=3;else opcode<=cmd_wdata[7:0];
                    8'h04: if(!cmd_write) rsp_rdata<=address;else address<=cmd_wdata;
                    8'h08: if(!cmd_write) rsp_rdata<={16'b0,length,3'b0,read_data,quad_data,addr_bytes};
                        else if((cmd_wdata & 32'hffff00e0)!=0 || cmd_wdata[2:0]>4 || cmd_wdata[15:8]>128) rsp_error<=3;
                        else begin addr_bytes<=cmd_wdata[2:0];quad_data<=cmd_wdata[3];read_data<=cmd_wdata[4];length<=cmd_wdata[15:8];end
                    8'h0c: if(!cmd_write) rsp_rdata<=divider;
                        else if(cmd_wdata==0) rsp_error<=3;else divider<=cmd_wdata;
                    8'h10: if(!cmd_write) rsp_error<=2;
                        else if(cmd_wdata!=1 || (!read_data && !all_written)) rsp_error<=3;
                        else begin
                            qspi_cs_n<=0;stage<=COMMAND;state<=LOAD;byte_index<=0;
                            if(read_data) buffer_valid<=0;
                            rsp_valid<=0;
                        end
                    8'h14: if(!cmd_write) rsp_rdata<={24'b0,dummy_cycles};
                        else if(cmd_wdata[31:8]!=0) rsp_error<=3;else dummy_cycles<=cmd_wdata[7:0];
                    8'h18: if(cmd_write) rsp_error<=2;else rsp_rdata<={23'b0,byte_index,(state!=IDLE)};
                    default:rsp_error<=1;
                endcase
            end
            case(state)
                IDLE:begin end
                LOAD:begin
                    qspi_sclk<=CPOL;timer<=divider-1;rx_shift<=0;
                    if(stage==DUMMY) begin
                        qspi_dq_oe<=0;dummy_left<=dummy_cycles;state<=DUMMY_CLOCK;
                    end else begin
                        bits_left<=(stage==ADDRESS)?{addr_bytes,3'b000}:6'd8;
                        if(stage==COMMAND) begin shift<={opcode,24'b0};qspi_dq_out<={3'b0,opcode[7]};qspi_dq_oe<=1;end
                        else if(stage==ADDRESS) begin
                            shift<=address<<((4-addr_bytes)*8);
                            qspi_dq_out<={3'b0,address[addr_bytes*8-1]};qspi_dq_oe<=1;
                        end else begin
                            shift<=read_data?32'b0:{buffer[byte_index],24'b0};
                            qspi_dq_out<=read_data?4'b0:(quad_data?buffer[byte_index][7:4]:{3'b0,buffer[byte_index][7]});
                            qspi_dq_oe<=read_data?4'b0000:(quad_data?4'b1111:4'b0001);
                        end
                        state<=CLOCK;
                    end
                end
                CLOCK:if(timer!=0) timer<=timer-1;
                    else begin
                        timer<=divider-1;
                        if(qspi_sclk==CPOL) begin
                            qspi_sclk<=~CPOL;
                            if(stage==DATA && read_data)
                                rx_shift<=four_lane?{rx_shift[3:0],qspi_dq_in}:{rx_shift[6:0],qspi_dq_in[1]};
                        end else begin
                            qspi_sclk<=CPOL;
                            if(bits_left<=(four_lane?4:1)) begin
                                if(stage==COMMAND && addr_bytes!=0) begin stage<=ADDRESS;state<=LOAD;end
                                else if(stage!=DATA) begin
                                    if(dummy_cycles!=0) begin stage<=DUMMY;state<=LOAD;end
                                    else if(length!=0) begin stage<=DATA;state<=LOAD;end
                                    else state<=FINISH;
                                end else begin
                                    if(read_data) begin buffer[byte_index]<=rx_shift;buffer_valid[byte_index]<=1;end
                                    byte_index<=byte_index+1;
                                    if(byte_index+1>=length) state<=FINISH;else state<=LOAD;
                                end
                            end else begin
                                bits_left<=bits_left-(four_lane?4:1);
                                shift<=shift<<(four_lane?4:1);
                                qspi_dq_out<=four_lane?shift[27:24]:{3'b0,shift[30]};
                            end
                        end
                    end
                DUMMY_CLOCK:if(timer!=0) timer<=timer-1;
                    else begin
                        timer<=divider-1;
                        if(qspi_sclk==CPOL) qspi_sclk<=~CPOL;
                        else begin
                            qspi_sclk<=CPOL;
                            if(dummy_left==1) begin
                                if(length!=0) begin stage<=DATA;state<=LOAD;end else state<=FINISH;
                            end else dummy_left<=dummy_left-1;
                        end
                    end
                FINISH:begin
                    qspi_cs_n<=1;qspi_sclk<=CPOL;qspi_dq_oe<=0;
                    rsp_valid<=1;rsp_rdata<={24'b0,length};rsp_error<=0;state<=IDLE;
                end
                default:begin state<=IDLE;qspi_cs_n<=1;qspi_dq_oe<=0;end
            endcase
        end
    end
endmodule
`default_nettype wire

