// Extracted from the Tang Primer 20K official UDP example, with local 128-byte TX buffer sizing.
module SMI_ct(
    input clk, rst, rw, trg,
    input [4:0] phy_adr, reg_adr,
    input [15:0] data,
    output logic ready, ack,
    output logic [15:0] smi_data,
    inout logic mdio
);

    byte ct;
    reg rmdio;

    reg [31:0] tx_data;
    reg [15:0] rx_data;

    assign mdio = rmdio?1'bZ:1'b0;

    always_comb begin
        smi_data <= rx_data;
    end

    always_ff@(posedge clk or negedge rst)begin
        if(rst == 1'b0)begin
            ct <= 0;
            ready <= 1'b0;
            ack <= 1'b0;

            rmdio <= 1'b1;
        end else begin
            ct <= ct + 8'd1;
            if(ct == 0 && trg == 1'b0)ct<=0;
            if(ct == 0 && trg == 1'b1)begin
                ready <= 1'b0;
                ack <= 1'b0;
            end

            if(ct == 64)begin
                ready <= 1'b1;
            end

            if(trg == 1'b1 && ready == 1'b1)begin
                ready <= 1'b0;
            end

            rmdio <= 1'b1;

            if(ct == 4 && trg == 1'b1)begin
                tx_data <= {2'b01, rw?2'b10:2'b01, phy_adr, reg_adr, rw?2'b11:2'b10, rw?16'hFFFF:data};
            end

            if(ct>31)begin
                rmdio <= tx_data[31];
                tx_data <= {tx_data[30:0], 1'b1};
            end

            if(ct == 48 && mdio == 1'b0)begin
                ack <= 1'b1;
            end
            
            if(ct>48)begin
                rx_data <= {rx_data[14:0], mdio};
            end
        end
    end
endmodule

module tx_ct(
    input clk, rst,
    input [7:0] data,
    input tx_en,
    output logic tx_av,
    output logic tx_bz,

    output logic [1:0] p_txd,
    output logic p_txen
);

logic[7:0] buffer[127:0];
shortint begin_ptr;
shortint end_ptr;
logic[7:0] buffer_out;

byte send_status;

byte tick;
shortint send_cnt;

logic int_en;


logic[31:0] crc;
logic[31:0] crc_next;

logic crc_ct;
logic [7:0] crc_in;

logic [7:0] data_i;

assign data_i = {crc_in[0],crc_in[1],crc_in[2],crc_in[3],crc_in[4],crc_in[5],crc_in[6],crc_in[7]};

assign crc_next[0] = crc[24] ^ crc[30] ^ data_i[0] ^ data_i[6];
assign crc_next[1] = crc[24] ^ crc[25] ^ crc[30] ^ crc[31] ^ data_i[0] ^ data_i[1] ^ data_i[6] ^ data_i[7];
assign crc_next[2] = crc[24] ^ crc[25] ^ crc[26] ^ crc[30] ^ crc[31] ^ data_i[0] ^ data_i[1] ^ data_i[2] ^ data_i[6] ^ data_i[7];
assign crc_next[3] = crc[25] ^ crc[26] ^ crc[27] ^ crc[31] ^ data_i[1] ^ data_i[2] ^ data_i[3] ^ data_i[7];
assign crc_next[4] = crc[24] ^ crc[26] ^ crc[27] ^ crc[28] ^ crc[30] ^ data_i[0] ^ data_i[2] ^ data_i[3] ^ data_i[4] ^ data_i[6];
assign crc_next[5] = crc[24] ^ crc[25] ^ crc[27] ^ crc[28] ^ crc[29] ^ crc[30] ^ crc[31] ^ data_i[0] ^ data_i[1] ^ data_i[3] ^ data_i[4] ^ data_i[5] ^ data_i[6] ^ data_i[7];
assign crc_next[6] = crc[25] ^ crc[26] ^ crc[28] ^ crc[29] ^ crc[30] ^ crc[31] ^ data_i[1] ^ data_i[2] ^ data_i[4] ^ data_i[5] ^ data_i[6] ^ data_i[7];
assign crc_next[7] = crc[24] ^ crc[26] ^ crc[27] ^ crc[29] ^ crc[31] ^ data_i[0] ^ data_i[2] ^ data_i[3] ^ data_i[5] ^ data_i[7];
assign crc_next[8] = crc[0] ^ crc[24] ^ crc[25] ^ crc[27] ^ crc[28] ^ data_i[0] ^ data_i[1] ^ data_i[3] ^ data_i[4];
assign crc_next[9] = crc[1] ^ crc[25] ^ crc[26] ^ crc[28] ^ crc[29] ^ data_i[1] ^ data_i[2] ^ data_i[4] ^ data_i[5];
assign crc_next[10] = crc[2] ^ crc[24] ^ crc[26] ^ crc[27] ^ crc[29] ^ data_i[0] ^ data_i[2] ^ data_i[3] ^ data_i[5];
assign crc_next[11] = crc[3] ^ crc[24] ^ crc[25] ^ crc[27] ^ crc[28] ^ data_i[0] ^ data_i[1] ^ data_i[3] ^ data_i[4];
assign crc_next[12] = crc[4] ^ crc[24] ^ crc[25] ^ crc[26] ^ crc[28] ^ crc[29] ^ crc[30] ^ data_i[0] ^ data_i[1] ^ data_i[2] ^ data_i[4] ^ data_i[5] ^ data_i[6];
assign crc_next[13] = crc[5] ^ crc[25] ^ crc[26] ^ crc[27] ^ crc[29] ^ crc[30] ^ crc[31] ^ data_i[1] ^ data_i[2] ^ data_i[3] ^ data_i[5] ^ data_i[6] ^ data_i[7];
assign crc_next[14] = crc[6] ^ crc[26] ^ crc[27] ^ crc[28] ^ crc[30] ^ crc[31] ^ data_i[2] ^ data_i[3] ^ data_i[4] ^ data_i[6] ^ data_i[7];
assign crc_next[15] =  crc[7] ^ crc[27] ^ crc[28] ^ crc[29] ^ crc[31] ^ data_i[3] ^ data_i[4] ^ data_i[5] ^ data_i[7];
assign crc_next[16] = crc[8] ^ crc[24] ^ crc[28] ^ crc[29] ^ data_i[0] ^ data_i[4] ^ data_i[5];
assign crc_next[17] = crc[9] ^ crc[25] ^ crc[29] ^ crc[30] ^ data_i[1] ^ data_i[5] ^ data_i[6];
assign crc_next[18] = crc[10] ^ crc[26] ^ crc[30] ^ crc[31] ^ data_i[2] ^ data_i[6] ^ data_i[7];
assign crc_next[19] = crc[11] ^ crc[27] ^ crc[31] ^ data_i[3] ^ data_i[7];
assign crc_next[20] = crc[12] ^ crc[28] ^ data_i[4];
assign crc_next[21] = crc[13] ^ crc[29] ^ data_i[5];
assign crc_next[22] = crc[14] ^ crc[24] ^ data_i[0];
assign crc_next[23] = crc[15] ^ crc[24] ^ crc[25] ^ crc[30] ^ data_i[0] ^ data_i[1] ^ data_i[6];
assign crc_next[24] = crc[16] ^ crc[25] ^ crc[26] ^ crc[31] ^ data_i[1] ^ data_i[2] ^ data_i[7];
assign crc_next[25] = crc[17] ^ crc[26] ^ crc[27] ^ data_i[2] ^ data_i[3];
assign crc_next[26] = crc[18] ^ crc[24] ^ crc[27] ^ crc[28] ^ crc[30] ^ data_i[0] ^ data_i[3] ^ data_i[4] ^ data_i[6];
assign crc_next[27] = crc[19] ^ crc[25] ^ crc[28] ^ crc[29] ^ crc[31] ^ data_i[1] ^ data_i[4] ^ data_i[5] ^ data_i[7];
assign crc_next[28] = crc[20] ^ crc[26] ^ crc[29] ^ crc[30] ^ data_i[2] ^ data_i[5] ^ data_i[6];
assign crc_next[29] = crc[21] ^ crc[27] ^ crc[30] ^ crc[31] ^ data_i[3] ^ data_i[6] ^ data_i[7];
assign crc_next[30] = crc[22] ^ crc[28] ^ crc[31] ^ data_i[4] ^ data_i[7];
assign crc_next[31] = crc[23] ^ crc[29] ^ data_i[5];



logic [7:0] crc_buffer;





always_comb begin
    //64 byte free
    tx_av <= (end_ptr + 127 - begin_ptr)%128 > 63;
    int_en <= tx_av && tx_en;
    if(crc_ct)
        crc_in<=buffer_out;
    else
        crc_in <= 8'b00000000;
    
    tx_bz <= send_status != 0;
end

always_ff@(posedge clk or negedge rst)begin
    if(rst == 1'b0)begin
        begin_ptr <= 0;
        end_ptr <= 0;
        send_status <= 0;
    end else begin
        p_txen <= 1'b0;
        tick<=tick + 8'd1;
        if(tick == 3)begin
            tick <= 0;
        end
        if(int_en)begin
            buffer[begin_ptr] <= data;
            begin_ptr <= begin_ptr + 16'd1;
            if(begin_ptr == 127)begin_ptr<=0;
        end
        case(send_status)
            0:begin //idle wait for tx_en
                if(begin_ptr != end_ptr)begin
                    send_status <= 1;
                    send_cnt <= 0;
                    crc<=32'hFFFFFFFF;
                end
            end
            1:begin //send preamble and SFD
                send_cnt <= send_cnt + 8'd1;
                p_txd <= 2'b01;
                p_txen <= 1'b1;
                if(send_cnt == 31)begin
                    p_txd <= 2'b11;
                    send_status <=2;
                    send_cnt <= 0;
                    tick <= 0;
                    crc_ct <= 1'b1;
                end
            end
            2:begin //send payload
                if(tick == 0)crc<=crc_next;

                buffer_out <= {2'bXX,buffer_out[7:2]};
                p_txd <= buffer_out[1:0];
                p_txen <= 1'b1;
                if(tick == 2)begin
                    end_ptr <= end_ptr + 16'd1;
                    if(end_ptr == 127)end_ptr<=0;
                end

                if(tick == 3 && send_cnt < 96)send_cnt <= send_cnt + 8'd1;
                
                if(tick == 3 && (end_ptr - begin_ptr)%128 == 0)begin
                    crc_ct <= 1'b0;
                    if(send_cnt < 63)
                        send_status <= 3;
                    else begin
                        send_status <= 4;
                        send_cnt <= 0;

                        crc_buffer <= ~{crc[24],crc[25],crc[26],crc[27],crc[28],crc[29],crc[30],crc[31]};
                        crc<={crc[23:0],8'hXX};
                    end
                end
            end
            3:begin //send padding
                if(tick == 0)crc <= crc_next;
                p_txd <= 0;
                p_txen <= 1'b1;
                if(tick == 3)begin
                    send_cnt <= send_cnt + 8'd1;
                    if(send_cnt == 63)begin
                        send_status <= 4;
                        send_cnt <= 0;

                        crc_buffer <= ~{crc[24],crc[25],crc[26],crc[27],crc[28],crc[29],crc[30],crc[31]};
                        crc<={crc[23:0],8'hXX};
                    end
                end
            end
            4:begin //send CRC  
                p_txd <= crc_buffer[1:0];
                crc_buffer <= {2'bXX,crc_buffer[7:2]};
                p_txen <= 1'b1;

                if(tick == 3)begin
                    crc_buffer <= ~{crc[24],crc[25],crc[26],crc[27],crc[28],crc[29],crc[30],crc[31]};
                    crc<={crc[23:0],8'hXX};

                    send_cnt <= send_cnt + 8'd1;
                    if(send_cnt == 3)begin
                        send_status <= 5;
                        send_cnt <= 0;
                    end
                end
            end
            5:begin //wait for 4 cycles
                p_txd <= 2'bXX;
                p_txen <= 1'b0;
                if(tick == 3)begin
                    send_status <= 0;
                end
            end
        endcase
        if(tick == 3)begin
            buffer_out <= buffer[end_ptr];
        end
    end

end


endmodule

