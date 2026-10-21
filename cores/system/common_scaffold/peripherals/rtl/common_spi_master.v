`default_nettype none
// Four-mode MSB-first byte master; transfer response means byte completed.
module common_spi_master #(
    parameter integer NUM_CS=1, CLOCK_DIV=2,
    parameter CPOL=1'b0, CPHA=1'b0
) (
    input wire clk, rst_n, clk_en,
    input wire cmd_valid, output wire cmd_ready,
    input wire cmd_write, input wire [7:0] cmd_addr, input wire [31:0] cmd_wdata,
    output reg rsp_valid, input wire rsp_ready,
    output reg [31:0] rsp_rdata, output reg [1:0] rsp_error,
    output wire spi_sclk, spi_mosi, input wire spi_miso,
    output wire [NUM_CS-1:0] spi_cs_n
);
    reg mode_pol,mode_phase,keep_cs,cs_active;
    reg [31:0] divider,cs_index;
    reg go,pending;
    reg [7:0] tx,last_rx;
    wire busy,done; wire [7:0] rx;
    assign cmd_ready=!rsp_valid && !pending;
    genvar i;
    generate for(i=0;i<NUM_CS;i=i+1) begin: chipselect
        assign spi_cs_n[i]=!(cs_active && cs_index==i);
    end endgenerate
    common_serial_spi_byte shifter(.clk(clk),.rst_n(rst_n),.clk_en(clk_en),
        .start(go),.tx_data(tx),.half_period(divider),.cpol(mode_pol),.cpha(mode_phase),
        .busy(busy),.done(done),.rx_data(rx),.sclk(spi_sclk),.mosi(spi_mosi),.miso(spi_miso));
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            mode_pol<=CPOL; mode_phase<=CPHA; keep_cs<=0; cs_active<=0;
            divider<=(CLOCK_DIV<1)?1:CLOCK_DIV; cs_index<=0; go<=0; pending<=0;
            tx<=0; last_rx<=0; rsp_valid<=0; rsp_rdata<=0; rsp_error<=0;
        end else begin
            go<=0;
            if(clk_en && rsp_valid && rsp_ready) rsp_valid<=0;
            if(pending && done) begin
                pending<=0; last_rx<=rx; rsp_valid<=1;
                rsp_rdata<={24'b0,rx}; rsp_error<=0;
                if(!keep_cs) cs_active<=0;
            end
            if(clk_en && cmd_valid && cmd_ready) begin
                rsp_valid<=1; rsp_rdata<=0; rsp_error<=0;
                case(cmd_addr)
                    8'h00: if(!cmd_write) rsp_rdata<={29'b0,keep_cs,mode_phase,mode_pol};
                        else if(cmd_wdata[31:3]!=0 || cs_active) rsp_error<=3;
                        else begin mode_pol<=cmd_wdata[0]; mode_phase<=cmd_wdata[1]; keep_cs<=cmd_wdata[2]; end
                    8'h04: if(!cmd_write) rsp_rdata<=divider;
                        else if(cmd_wdata==0) rsp_error<=3; else divider<=cmd_wdata;
                    8'h08: if(!cmd_write) rsp_rdata<=cs_index;
                        else if(cmd_wdata>=NUM_CS || cs_active) rsp_error<=3; else cs_index<=cmd_wdata;
                    8'h0c: if(!cmd_write) rsp_rdata<={24'b0,last_rx};
                        else if(cmd_wdata[31:8]!=0 || NUM_CS<1) rsp_error<=3;
                        else begin tx<=cmd_wdata[7:0]; go<=1; pending<=1; cs_active<=1; rsp_valid<=0; end
                    8'h10: if(cmd_write) rsp_error<=2; else rsp_rdata<={30'b0,cs_active,busy};
                    8'h14: if(!cmd_write) rsp_rdata<={31'b0,cs_active};
                        else if(cmd_wdata>1) rsp_error<=3; else cs_active<=cmd_wdata[0];
                    default: rsp_error<=1;
                endcase
            end
        end
    end
endmodule
`default_nettype wire

