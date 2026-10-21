`default_nettype none
// Byte-level open-drain master; START/repeated START/STOP controlled per byte.
module common_i2c_master #(
    parameter integer CLOCK_DIV=67, STRETCH_TIMEOUT_TICKS=65535
) (
    input wire clk,rst_n,clk_en,
    input wire cmd_valid,output wire cmd_ready,
    input wire cmd_write,input wire [7:0] cmd_addr,input wire [31:0] cmd_wdata,
    output reg rsp_valid,input wire rsp_ready,
    output reg [31:0] rsp_rdata,output reg [1:0] rsp_error,
    input wire i2c_scl_in,i2c_sda_in,
    output reg i2c_scl_drive_low,i2c_sda_drive_low
);
    localparam IDLE=0,START_PRE=1,START_WAIT=2,START_HIGH=3,START_HOLD=4,
        BIT_LOW=5,BIT_WAIT=6,BIT_HIGH=7,ACK_LOW=8,ACK_WAIT=9,ACK_HIGH=10,
        STOP_LOW=11,STOP_WAIT=12,STOP_HIGH=13,STOP_RELEASE=14,FINISH=15,FAIL=16;
    localparam integer TIMEOUT=(STRETCH_TIMEOUT_TICKS<1)?1:STRETCH_TIMEOUT_TICKS;
    reg [4:0] state;
    reg [31:0] divider,timer,stretch;
    reg scl_a,scl_b,sda_a,sda_b;
    reg active,read_byte,send_stop,send_nack;
    reg [7:0] tx_byte,tx_latch,rx_byte,last_rx;
    reg [2:0] bit_index;
    reg [3:0] errors,last_errors;
    assign cmd_ready=!rsp_valid && state==IDLE;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE;divider<=(CLOCK_DIV<2)?2:CLOCK_DIV;timer<=0;stretch<=0;
            scl_a<=1;scl_b<=1;sda_a<=1;sda_b<=1;
            active<=0;read_byte<=0;send_stop<=0;send_nack<=0;
            tx_byte<=0;tx_latch<=0;rx_byte<=0;last_rx<=0;bit_index<=0;
            errors<=0;last_errors<=0;
            i2c_scl_drive_low<=0;i2c_sda_drive_low<=0;
            rsp_valid<=0;rsp_rdata<=0;rsp_error<=0;
        end else begin
            scl_a<=i2c_scl_in;scl_b<=scl_a;sda_a<=i2c_sda_in;sda_b<=sda_a;
            if(clk_en && rsp_valid && rsp_ready) rsp_valid<=0;
            if(clk_en && cmd_valid && cmd_ready) begin
                rsp_valid<=1;rsp_rdata<=0;rsp_error<=0;
                case(cmd_addr)
                    8'h00: if(!cmd_write) rsp_error<=2;
                        else if(cmd_wdata[31:5]!=0 ||
                            (cmd_wdata[4] && (cmd_wdata[3:0]!=0 || !active)) ||
                            (!cmd_wdata[4] && !cmd_wdata[0] && !active)) rsp_error<=3;
                        else begin
                            read_byte<=cmd_wdata[2];send_stop<=cmd_wdata[1];send_nack<=cmd_wdata[3];
                            errors<=0;rx_byte<=0;bit_index<=0;tx_latch<=tx_byte;
                            timer<=divider-1;stretch<=0;rsp_valid<=0;
                            if(cmd_wdata[4]) begin
                                i2c_scl_drive_low<=1;i2c_sda_drive_low<=1;state<=STOP_LOW;
                            end else if(cmd_wdata[0]) begin
                                // Release SDA while SCL is still low before repeated START.
                                i2c_sda_drive_low<=0;
                                if(active) begin i2c_scl_drive_low<=1;state<=START_PRE;end
                                else begin i2c_scl_drive_low<=0;state<=START_WAIT;end
                            end else begin
                                i2c_scl_drive_low<=1;
                                i2c_sda_drive_low<=cmd_wdata[2]?1'b0:~tx_byte[7];state<=BIT_LOW;
                            end
                        end
                    8'h04: if(!cmd_write) rsp_rdata<={24'b0,tx_byte};
                        else if(cmd_wdata[31:8]!=0) rsp_error<=3;else tx_byte<=cmd_wdata[7:0];
                    8'h08: if(!cmd_write) rsp_rdata<=divider;
                        else if(cmd_wdata<2 || active) rsp_error<=3;else divider<=cmd_wdata;
                    8'h0c: if(cmd_write) rsp_error<=2;
                        else rsp_rdata<={20'b0,last_errors,last_rx};
                    8'h10: if(cmd_write) rsp_error<=2;
                        else rsp_rdata<={27'b0,sda_b,scl_b,last_errors[0],active,(state!=IDLE)};
                    default:rsp_error<=1;
                endcase
            end
            case(state)
                IDLE: begin end
                START_PRE: if(timer!=0) timer<=timer-1;
                    else begin i2c_scl_drive_low<=0;stretch<=0;state<=START_WAIT;end
                START_WAIT: if(scl_b && sda_b) begin timer<=divider-1;stretch<=0;state<=START_HIGH;end
                    else if(stretch>=TIMEOUT-1) begin errors[3]<=1;state<=FAIL;end
                    else stretch<=stretch+1;
                START_HIGH: if(!scl_b || !sda_b) begin errors[1]<=1;state<=FAIL;end
                    else if(timer!=0) timer<=timer-1;
                    else begin i2c_sda_drive_low<=1;active<=1;timer<=divider-1;state<=START_HOLD;end
                START_HOLD: if(timer!=0) timer<=timer-1;
                    else begin
                        i2c_scl_drive_low<=1;i2c_sda_drive_low<=read_byte?1'b0:~tx_latch[7];
                        timer<=divider-1;state<=BIT_LOW;
                    end
                BIT_LOW: if(timer!=0) timer<=timer-1;
                    else begin i2c_scl_drive_low<=0;stretch<=0;state<=BIT_WAIT;end
                BIT_WAIT: if(scl_b) begin timer<=divider-1;state<=BIT_HIGH;end
                    else if(stretch>=TIMEOUT-1) begin errors[2]<=1;state<=FAIL;end
                    else stretch<=stretch+1;
                BIT_HIGH: if(timer!=0) timer<=timer-1;
                    else if(!read_byte && tx_latch[7-bit_index] && !sda_b) begin errors[1]<=1;state<=FAIL;end
                    else begin
                        if(read_byte) rx_byte[7-bit_index]<=sda_b;
                        i2c_scl_drive_low<=1;timer<=divider-1;
                        if(bit_index==7) begin
                            i2c_sda_drive_low<=read_byte?!send_nack:1'b0;state<=ACK_LOW;
                        end else begin
                            bit_index<=bit_index+1;i2c_sda_drive_low<=read_byte?1'b0:~tx_latch[6-bit_index];state<=BIT_LOW;
                        end
                    end
                ACK_LOW: if(timer!=0) timer<=timer-1;
                    else begin i2c_scl_drive_low<=0;stretch<=0;state<=ACK_WAIT;end
                ACK_WAIT: if(scl_b) begin timer<=divider-1;state<=ACK_HIGH;end
                    else if(stretch>=TIMEOUT-1) begin errors[2]<=1;state<=FAIL;end
                    else stretch<=stretch+1;
                ACK_HIGH: if(timer!=0) timer<=timer-1;
                    else begin
                        if(!read_byte) errors[0]<=sda_b;
                        i2c_scl_drive_low<=1;timer<=divider-1;
                        if(send_stop) begin i2c_sda_drive_low<=1;state<=STOP_LOW;end
                        else begin i2c_sda_drive_low<=0;state<=FINISH;end
                    end
                STOP_LOW: if(timer!=0) timer<=timer-1;
                    else begin i2c_scl_drive_low<=0;stretch<=0;state<=STOP_WAIT;end
                STOP_WAIT: if(scl_b) begin timer<=divider-1;state<=STOP_HIGH;end
                    else if(stretch>=TIMEOUT-1) begin errors[2]<=1;state<=FAIL;end
                    else stretch<=stretch+1;
                STOP_HIGH: if(timer!=0) timer<=timer-1;
                    else begin
                        i2c_sda_drive_low<=0;active<=0;
                        // Let the two-stage input sampler observe the released SDA.
                        timer<=(divider<4)?3:divider-1;state<=STOP_RELEASE;
                    end
                STOP_RELEASE: if(timer!=0) timer<=timer-1;
                    else if(!sda_b) begin errors[3]<=1;state<=FAIL;end
                    else state<=FINISH;
                FINISH: begin
                    last_rx<=rx_byte;last_errors<=errors;rsp_rdata<={20'b0,errors,rx_byte};
                    rsp_error<=(errors!=0)?2'd3:2'd0;rsp_valid<=1;state<=IDLE;
                end
                FAIL: begin
                    i2c_scl_drive_low<=0;i2c_sda_drive_low<=0;active<=0;state<=FINISH;
                end
                default:state<=FAIL;
            endcase
        end
    end
endmodule
`default_nettype wire

