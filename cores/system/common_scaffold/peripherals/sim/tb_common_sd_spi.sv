`timescale 1ns/1ps
`default_nettype none
module tb_common_sd_spi;
    reg clk=0; always #5 clk=~clk;
    reg rst_n=0, clk_en=1, cmd_valid=0, cmd_write=0, rsp_ready=1;
    reg [7:0] cmd_addr=0;
    reg [31:0] cmd_wdata=0;
    wire cmd_ready, rsp_valid;
    wire [31:0] rsp_rdata;
    wire [1:0] rsp_error;
    reg card_present=1, sd_miso=1;
    wire sd_cs_n, sd_sclk, sd_mosi;
    common_sd_spi #(.CLOCK_DIV(1),.RESPONSE_TIMEOUT_TICKS(12)) dut(.*);

    reg [7:0] card_mem[0:511];
    reg [7:0] queue[0:2047], packet[0:5];
    reg [7:0] incoming=0, outgoing=8'hff, byte_in;
    integer qread=0,qwrite=0,bit_count=0,packet_count=0;
    integer write_state=0,write_index=0,i,acmd_count=0;
    reg [15:0] write_crc=0, wire_crc=0, read_crc;
    reg card_idle=1, app_armed=0, model_hc=1, corrupt_read=0, ignore_commands=0;
    integer seen_commands=0, seen_writes=0;
    reg [31:0] packet_arg;
    function [15:0] crc16;
        input [15:0] prior; input [7:0] data;
        reg [15:0] c; integer b;
        begin c=prior; for(b=7;b>=0;b=b-1) begin
            if(c[15]^data[b]) c=(c<<1)^16'h1021; else c=c<<1;
        end crc16=c; end
    endfunction
    function [7:0] crc7;
        input [39:0] data;
        reg [6:0] c; integer b; reg f;
        begin c=0; for(b=39;b>=0;b=b-1) begin
            f=c[6]^data[b]; c=c<<1; if(f)c=c^7'h09;
        end crc7={c,1'b1}; end
    endfunction
    task push; input[7:0] value; begin queue[qwrite]=value; qwrite=qwrite+1; end endtask
    task receive_byte;
        input [7:0] value;
        integer k;
        begin
            if(write_state==1) begin
                if(value==8'hfe) begin write_state=2; write_index=0; write_crc=0; end
            end else if(write_state==2) begin
                card_mem[write_index]=value; write_crc=crc16(write_crc,value);
                if(write_index==511) write_state=3; else write_index=write_index+1;
            end else if(write_state==3) begin wire_crc[15:8]=value; write_state=4; end
            else if(write_state==4) begin
                wire_crc[7:0]=value;
                if(wire_crc!==write_crc) $fatal(1,"write wire CRC mismatch");
                seen_writes=seen_writes+1; write_state=0;
                push(8'h05); push(0); push(0); push(8'hff);
            end else if(packet_count!=0 || value[7:6]==2'b01) begin
                packet[packet_count]=value;
                if(packet_count==5) begin
                    packet_count=0; seen_commands=seen_commands+1;
                    if(packet[5]!==crc7({packet[0],packet[1],packet[2],packet[3],packet[4]}))
                        $fatal(1,"command CRC mismatch cmd %0d",packet[0]&63);
                    packet_arg={packet[1],packet[2],packet[3],packet[4]};
                    if(!ignore_commands) begin
                        push(8'hff);
                        case(packet[0]&63)
                            0: begin card_idle=1; acmd_count=0; push(1); end
                            8: begin push(1); push(0);push(0);push(1);push(8'haa); end
                            55: begin app_armed=1; push(card_idle?1:0); end
                            41: begin
                                if(!app_armed || packet_arg!=32'h40000000) $fatal(1,"bad ACMD41");
                                app_armed=0; acmd_count=acmd_count+1;
                                if(acmd_count>=2) card_idle=0;
                                push(card_idle?1:0);
                            end
                            58: begin push(0);push(model_hc?8'hc0:8'h80);push(8'hff);push(8'h80);push(0); end
                            16: begin if(packet_arg!=512 || model_hc) $fatal(1,"bad block length"); push(0); end
                            17: begin
                                if(packet_arg!==(model_hc?32'd7:32'd3584)) $fatal(1,"read addressing");
                                push(0);push(8'hff);push(8'hfe); read_crc=0;
                                for(k=0;k<512;k=k+1) begin push(card_mem[k]);read_crc=crc16(read_crc,card_mem[k]);end
                                push(read_crc[15:8]);push(read_crc[7:0]^{7'b0,corrupt_read});
                            end
                            24: begin
                                if(packet_arg!==(model_hc?32'd7:32'd3584)) $fatal(1,"write addressing");
                                push(0); write_state=1;
                            end
                            12: begin push(0);push(0);push(0);push(8'hff); end
                            13: begin push(0);push(8'ha5); end
                            default: push(8'h04);
                        endcase
                    end
                end else packet_count=packet_count+1;
            end
        end
    endtask
    always @(posedge sd_cs_n) begin
        qread=0;qwrite=0;bit_count=0;packet_count=0;incoming=0;outgoing=8'hff;
        write_state=0; sd_miso=1;
    end
    always @(negedge sd_cs_n) begin bit_count=0; incoming=0;outgoing=8'hff;sd_miso=1;end
    always @(posedge sd_sclk) if(!sd_cs_n) begin
        incoming={incoming[6:0],sd_mosi};
        if(bit_count==7) begin bit_count=0;byte_in=incoming;receive_byte(byte_in);end
        else bit_count=bit_count+1;
    end
    always @(negedge sd_sclk) if(!sd_cs_n) begin
        if(bit_count==0) begin
            if(qread<qwrite) begin outgoing=queue[qread];qread=qread+1;end else outgoing=8'hff;
        end
        sd_miso=outgoing[7-bit_count];
    end

    task csr;
        input wr; input[7:0] addr; input[31:0] data;
        output[31:0] result; output[1:0] err;
        begin
            @(negedge clk); clk_en=1;cmd_valid=1;cmd_write=wr;cmd_addr=addr;cmd_wdata=data;
            while(!cmd_ready) @(negedge clk);
            @(posedge clk); #1;
            @(negedge clk);cmd_valid=0;
            while(!rsp_valid) @(negedge clk);
            result=rsp_rdata;err=rsp_error;
            @(posedge clk);#1;
        end
    endtask
    reg [31:0] result;
    reg [1:0] err;
    task wr;
        input[7:0] addr;input[31:0] data;
        begin csr(1,addr,data,result,err);if(err) $fatal(1,"CSR write %h err %d",addr,err);end
    endtask
    task wait_done;
        input[7:0] expected_error;
        integer n;
        begin
            // Engine must make progress with CE low throughout the wire transaction.
            @(negedge clk);clk_en=0; n=0;
            while(dut.engine_busy && n<100000) begin @(negedge clk);n=n+1;end
            if(n==100000)$fatal(1,"engine failed to terminate");
            clk_en=1;csr(0,0,0,result,err);
            if(err || result[0] || !result[4] || result[15:8]!==expected_error)
                $fatal(1,"bad final status %h expected %d",result,expected_error);
        end
    endtask
    task init_card;
        begin wr(4,1);wait_done(0);if(!result[1] || result[2]!==model_hc)$fatal(1,"init flags");end
    endtask
    initial begin
        for(i=0;i<512;i=i+1) card_mem[i]=(i*37+11)&255;
        #31;rst_n=1;
        csr(0,8'h18,0,result,err);
        if(err!=2 || result!==0)$fatal(1,"uninitialized buffer was exposed");
        init_card();
        csr(1,4,3,result,err);
        if(err!=2 || dut.engine_busy)$fatal(1,"incomplete block write was accepted");
        wr(8'h14,0);wr(8'h18,1);
        csr(1,4,3,result,err);
        if(err!=2 || dut.engine_busy)$fatal(1,"partial block write was accepted");
        wr(8,7);wr(4,2);wait_done(0);
        wr(8'h14,0);
        for(i=0;i<512;i=i+1) begin
            csr(0,8'h18,0,result,err);
            if(err || result[7:0]!==card_mem[i])$fatal(1,"read buffer %0d",i);
        end
        wr(8'h14,0);
        for(i=0;i<512;i=i+1) wr(8'h18,(i*13+9)&255);
        wr(4,3);wait_done(0);
        for(i=0;i<512;i=i+1) if(card_mem[i]!==((i*13+9)&255))$fatal(1,"write data %d",i);
        corrupt_read=1;wr(4,2);wait_done(6);corrupt_read=0;
        wr(8'h14,0);csr(0,8'h18,0,result,err);
        if(err!=2)$fatal(1,"CRC-failed buffer was published");
        // Raw R2 response and R1b busy release.
        wr(8'h0c,32'h20d);wr(4,4);wait_done(0);csr(0,8'h10,0,result,err);
        if(result!=8'ha5)$fatal(1,"R2 capture");
        wr(8'h0c,32'h10c);wr(4,4);wait_done(0);
        // SDSC-v2 initialization selects CMD16 and byte addresses.
        model_hc=0;init_card();wr(8,7);wr(4,2);wait_done(0);
        // A card that never responds must finish with timeout.
        ignore_commands=1;wr(8'h0c,13);wr(4,4);wait_done(2);ignore_commands=0;
        wr(4,2);@(negedge clk);card_present=0;wait_done(1);
        if(!sd_cs_n || result[1])$fatal(1,"removal did not invalidate card");
        $display("PASS SD SPI: SDHC/SDSC init, command CRC7, 512B read/write CRC16, raw R2/R1b, CRC error, timeout, removal, CE-independent engine (%0d commands, %0d writes)",seen_commands,seen_writes);
        $finish;
    end
    initial begin #10000000; $fatal(1,"global watchdog");end
endmodule
`default_nettype wire
