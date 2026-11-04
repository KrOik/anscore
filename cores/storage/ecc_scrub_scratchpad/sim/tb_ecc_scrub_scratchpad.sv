// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_ecc_scrub_scratchpad;
    parameter integer DEPTH=256,TAG_W=8,CASES=1,RESPONSES=1;
    localparam integer CW=(DEPTH<2)?1:$clog2(DEPTH+1);
    reg clk=0;
    always #5 clk=~clk;
    reg rst=1,c_valid=0,r_ready=0;
    wire c_ready,r_valid;
    reg [1:0] c_op=0;
    reg [31:0] c_address=0,c_data=0;
    reg [3:0] c_strobe=0;
    reg [TAG_W-1:0] c_tag=0;
    wire [31:0] r_data,r_first_uncorrectable;
    wire [1:0] r_status;
    wire [CW-1:0] r_corrected,r_uncorrectable;
    wire [TAG_W-1:0] r_tag;
    ecc_scrub_scratchpad #(.DEPTH(DEPTH),.TAG_W(TAG_W)) dut(.*);
    reg [38:0] expected [0:CASES*DEPTH-1];
    integer cycle=0,outputs=0,stalls=0;
    localparam integer RW=32+2+2*CW+32+TAG_W;
    reg held=0;
    reg [RW-1:0] held_response;
    wire [RW-1:0] response={r_data,r_status,r_corrected,r_uncorrectable,r_first_uncorrectable,r_tag};
    always @(posedge clk) begin
        cycle<=cycle+1;
        if (cycle>5000000) $fatal(1,"bounded cycle timeout");
        if (rst) held<=0;
        else begin
            if (held && (!r_valid || response!==held_response)) $fatal(1,"response changed while stalled");
            held<=r_valid&&!r_ready;
            held_response<=response;
            if (r_valid&&!r_ready) stalls<=stalls+1;
            if (r_valid && c_ready) $fatal(1,"overlapped command ownership");
        end
    end

    task automatic reset_now;
        integer waited;
        begin
            // Called at the observed phase boundary, before another active edge.
            rst=1;c_valid=0;r_ready=0;
            @(negedge clk);rst=0;waited=0;
            while (!c_ready) begin
                @(negedge clk);waited=waited+1;
                if (r_valid) $fatal(1,"ghost response after reset");
                if (waited>DEPTH+5) $fatal(1,"initialization did not finish");
            end
            for (integer k=0;k<DEPTH;k=k+1)
                if (dut.code_ram[k]!==39'd0) $fatal(1,"reset initialization mismatch");
        end
    endtask
    task automatic reset_core;
        begin @(negedge clk);reset_now();end
    endtask
    task automatic launch(input [1:0] op,input [31:0] address,value,input [3:0] strobe,input [TAG_W-1:0] tag);
        begin
            @(negedge clk);c_op=op;c_address=address;c_data=value;c_strobe=strobe;c_tag=tag;c_valid=1;r_ready=0;
            @(posedge clk);while (!c_ready) @(posedge clk);
            @(negedge clk);c_valid=0;
        end
    endtask
    integer case_number;
    task automatic finish_response(input [31:0] data_value,input [1:0] status_value,
        input [CW-1:0] corrected_value,uncorrectable_value,input [31:0] first_value,input [TAG_W-1:0] tag_value);
        begin
            while (!r_valid) @(negedge clk);
            if (response!=={data_value,status_value,corrected_value,uncorrectable_value,first_value,tag_value})
                $fatal(1,"response mismatch case=%0d got data=%h status=%d corr=%d uncorr=%d first=%h tag=%h",
                    case_number,r_data,r_status,r_corrected,r_uncorrectable,r_first_uncorrectable,r_tag);
            repeat (3) @(negedge clk);
            r_ready=1;@(negedge clk);r_ready=0;outputs=outputs+1;
        end
    endtask

    string commands_path,expected_path;
    integer fd,fields,op,status_value,corrected_value,uncorrectable_value,i,probe,waited;
    reg [31:0] address,value,tag_value,data_value,first_value;
    reg [3:0] strobe;
    reg [38:0] mask;
    initial begin
        if (!$value$plusargs("COMMANDS=%s",commands_path) || !$value$plusargs("EXPECTED=%s",expected_path))
            $fatal(1,"missing vectors");
        fd=$fopen(commands_path,"r");if (!fd) $fatal(1,"cannot open vectors");
        $readmemh(expected_path,expected);
        reset_core();
        for (case_number=0;case_number<CASES;case_number=case_number+1) begin
            fields=$fscanf(fd,"%d %h %h %h %h %h %h %d %d %d %h\n",op,address,value,strobe,tag_value,mask,
                data_value,status_value,corrected_value,uncorrectable_value,first_value);
            if (fields!=11) $fatal(1,"bad vector case=%0d",case_number);
            if (op==4) begin
                @(negedge clk);
                dut.code_ram[address>>2]=dut.code_ram[address>>2]^mask;
            end else if (op==5) reset_core();
            else if (op==6) begin
                @(negedge clk);
                for (i=0;i<DEPTH;i=i+1) dut.code_ram[i]=dut.code_ram[i]^mask;
            end else begin
                launch(op[1:0],address,value,strobe,tag_value[TAG_W-1:0]);
                finish_response(data_value,status_value[1:0],CW'(corrected_value),CW'(uncorrectable_value),first_value,tag_value[TAG_W-1:0]);
            end
            for (i=0;i<DEPTH;i=i+1)
                if (dut.code_ram[i]!==expected[case_number*DEPTH+i])
                    $fatal(1,"stored code mismatch case=%0d index=%0d",case_number,i);
        end
        if (outputs!=RESPONSES) $fatal(1,"response count mismatch");
        $fclose(fd);

        // All eight controller states are interrupted at the observed negedge.
        // Reused codec pipelines reset together with their owner.
        for (probe=0;probe<8;probe=probe+1) begin
            reset_core();
            if (probe==0) begin
                @(negedge clk);rst=1;@(negedge clk);rst=0;
                if (dut.state!=0) $fatal(1,"initialization reset phase missing");
            end else if (probe==1) begin
                if (dut.state!=1) $fatal(1,"idle reset phase missing");
            end else if (probe==5 || probe==6) launch(1,0,32'habcd1234,15,1);
            else launch(2,0,0,0,1);
            waited=0;
            while (dut.state!=probe) begin
                @(negedge clk);waited=waited+1;
                if (waited>DEPTH*10+50) $fatal(1,"reset target not reached probe=%0d",probe);
            end
            reset_now();
            launch(0,0,0,0,0);
            finish_response(0,0,0,0,0,0);
        end
        if (stalls<1) $fatal(1,"no response stall coverage");
        $display("PASS cases=%0d responses=%0d memory_codewords=%0d reset_probes=8 stalls=%0d",CASES,RESPONSES,CASES*DEPTH,stalls);
        $finish;
    end
endmodule
