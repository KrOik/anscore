// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_canonical_huffman_table;
    parameter integer SYMBOLS=19, MAX_BITS=8;
    reg clk=0; always #5 clk=~clk;
    reg rst=1,c_valid=0,r_ready=0;
    wire c_ready,r_valid;
    reg [1:0] c_op=0;
    reg [31:0] c_symbol=0,c_length=0;
    reg [7:0] c_tag=0;
    wire [1:0] r_op;
    wire [2:0] r_status;
    wire [MAX_BITS-1:0] r_code;
    wire [31:0] r_length;
    wire [7:0] r_tag;
    canonical_huffman_table #(.SYMBOLS(SYMBOLS),.MAX_BITS(MAX_BITS)) dut(.*);
    integer fd,rc,op,symbol,len,tag,status,code,olen,commands=0,stalls=0,j;
    reg [1023:0] vector_path;

    task transact(input integer iop,input [31:0] isymbol,ilen,
                  input integer itag,istatus,icode,olength);
        integer wait_cycles, hold_cycles;
        begin
            @(negedge clk);
            c_valid=1; c_op=iop; c_symbol=isymbol; c_length=ilen; c_tag=itag;
            wait_cycles=0;
            while(!c_ready) begin
                @(negedge clk); wait_cycles=wait_cycles+1;
                if(wait_cycles>20000) $fatal(1,"command wait timeout");
            end
            @(posedge clk); @(negedge clk); c_valid=0;
            wait_cycles=0;
            while(!r_valid) begin
                @(negedge clk); wait_cycles=wait_cycles+1;
                if(wait_cycles>20000) $fatal(1,"response wait timeout");
            end
            hold_cycles=2+(commands%5);
            // A pending next command is held under output backpressure.
            c_valid=1; c_op=2; c_symbol=0; c_length=0; c_tag=8'hee;
            for(j=0;j<hold_cycles;j=j+1) begin
                if(!r_valid || c_ready || r_op!==iop[1:0] ||
                   r_tag!==itag[7:0] || r_status!==istatus[2:0] ||
                   r_code!==icode[MAX_BITS-1:0] || r_length!==olength) begin
                    $display("command %0d op%0d sym%0d len%0d: got status%0d code%0d length%0d expected %0d %0d %0d",
                             commands,iop,isymbol,ilen,r_status,r_code,r_length,istatus,icode,olength);
                    $fatal(1,"response mismatch or stalled payload changed");
                end
                @(negedge clk); stalls=stalls+1;
            end
            c_valid=0; r_ready=1;
            @(posedge clk); @(negedge clk); r_ready=0;
            if(r_valid) $fatal(1,"response did not retire");
            commands=commands+1;
        end
    endtask
    task reset_service;
        begin
            @(negedge clk); rst=1; c_valid=0; r_ready=0;
            @(posedge clk); @(negedge clk); rst=0;
            repeat(SYMBOLS+2) @(negedge clk);
            if(!c_ready || r_valid) $fatal(1,"reset did not restore service");
        end
    endtask
    initial begin
        if(!$value$plusargs("vectors=%s",vector_path)) $fatal(1,"missing vectors");
        repeat(2) @(negedge clk); rst=0;
        fd=$fopen(vector_path,"r"); if(!fd) $fatal(1,"cannot open vectors");
        while(!$feof(fd)) begin
            rc=$fscanf(fd,"%d %d %d %d %d %d %d\n",op,symbol,len,tag,status,code,olen);
            if(rc!=7) $fatal(1,"bad vector record");
            transact(op,symbol,len,tag,status,code,olen);
        end
        $fclose(fd);
        // Cancel an output that the sink has not accepted.
        @(negedge clk); c_valid=1; c_op=2; c_symbol=0;
        @(posedge clk); @(negedge clk); c_valid=0;
        if(!r_valid) $fatal(1,"missing response before reset");
        reset_service();
        transact(2,0,0,91,4,0,0);
        transact(1,0,0,92,3,0,0); // reset emptied staging
        transact(0,0,1,93,0,0,0);
        // Cancel an in-progress BUILD, before bank activation.
        @(negedge clk); c_valid=1; c_op=1;
        @(posedge clk); @(negedge clk); c_valid=0;
        if(c_ready) $fatal(1,"busy build accepted new ownership");
        reset_service();
        transact(2,0,0,94,4,0,0);
        transact(0,0,MAX_BITS,95,0,0,0);
        transact(1,0,0,96,0,0,0);
        transact(2,0,0,97,0,0,MAX_BITS);
        $display("PASS canonical_huffman_table SYMBOLS=%0d MAX_BITS=%0d commands=%0d stalled_cycles=%0d reset_cancellations=2",
                 SYMBOLS,MAX_BITS,commands,stalls);
        $finish;
    end
    initial begin #200000000; $fatal(1,"global watchdog"); end
endmodule
