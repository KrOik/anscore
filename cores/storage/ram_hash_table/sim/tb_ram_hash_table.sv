// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_ram_hash_table;
    parameter integer SLOTS=32,KEY_W=32,VALUE_W=32,TAG_W=8,CASES=1,RESPONSES=1;
    localparam integer CW=(SLOTS<2)?1:$clog2(SLOTS+1);
    reg clk=0;
    always #5 clk=~clk;
    reg rst=1,c_valid=0,r_ready=0;
    wire c_ready,r_valid,r_found,r_inserted;
    reg [1:0] c_op=0;
    reg [KEY_W-1:0] c_key=0;
    reg [VALUE_W-1:0] c_value=0;
    reg [TAG_W-1:0] c_tag=0;
    wire [1:0] r_status;
    wire [VALUE_W-1:0] r_old_value;
    wire [CW-1:0] r_count;
    wire [TAG_W-1:0] r_tag;
    ram_hash_table #(.SLOTS(SLOTS),.KEY_W(KEY_W),.VALUE_W(VALUE_W),.TAG_W(TAG_W)) dut(.*);
    reg [KEY_W+VALUE_W-1:0] expected [0:CASES*SLOTS-1];
    localparam integer RW=2+1+1+VALUE_W+CW+TAG_W;
    wire [RW-1:0] response={r_status,r_found,r_inserted,r_old_value,r_count,r_tag};
    reg held=0;
    reg [RW-1:0] held_response;
    integer cycle=0,stalls=0,outputs=0,probe_reads=0,case_number;
    always @(posedge clk) begin
        cycle<=cycle+1;
        if (cycle>5000000) $fatal(1,"bounded cycle timeout");
        if (rst) begin held<=0;probe_reads<=0;end
        else begin
            if (held && (!r_valid || response!==held_response)) $fatal(1,"held response changed");
            held<=r_valid&&!r_ready;held_response<=response;
            if (r_valid&&!r_ready) stalls<=stalls+1;
            if (r_valid && c_ready) $fatal(1,"overlapped ownership");
            if (c_valid && c_ready) probe_reads<=0;
            else if (dut.state==2) begin
                probe_reads<=probe_reads+1;
                if (probe_reads>=SLOTS) $fatal(1,"lookup exceeded complete table");
            end
            if (r_count>SLOTS) $fatal(1,"occupancy overflow");
        end
    end

    task automatic reset_now;
        integer waited,k;
        begin
            rst=1;c_valid=0;r_ready=0;
            @(negedge clk);rst=0;waited=0;
            while (!c_ready) begin
                @(negedge clk);waited=waited+1;
                if (r_valid) $fatal(1,"ghost reset response");
                if (waited>SLOTS+3) $fatal(1,"metadata clear timeout");
            end
            if (r_count!==0) $fatal(1,"reset did not empty dictionary");
            for (k=0;k<SLOTS;k=k+1)
                if (dut.slot_state[k]!==0) $fatal(1,"metadata reset sweep mismatch");
        end
    endtask
    task automatic reset_core;
        begin @(negedge clk);reset_now();end
    endtask
    task automatic launch(input [1:0] op,input [KEY_W-1:0] key,input [VALUE_W-1:0] value,input [TAG_W-1:0] tag);
        begin
            @(negedge clk);c_valid=1;c_op=op;c_key=key;c_value=value;c_tag=tag;r_ready=0;
            @(posedge clk);while (!c_ready) @(posedge clk);
            @(negedge clk);c_valid=0;
        end
    endtask
    task automatic finish_response(input [1:0] status,input found,inserted,input [VALUE_W-1:0] old,
                                   input [CW-1:0] count,input [TAG_W-1:0] tag);
        integer waited;
        begin
            waited=0;
            while (!r_valid) begin
                @(negedge clk);waited=waited+1;
                if (waited>2*SLOTS+4) $fatal(1,"command did not terminate case=%0d",case_number);
            end
            if (response!=={status,found,inserted,old,count,tag})
                $fatal(1,"response mismatch case=%0d got status=%d found=%d insert=%d old=%h count=%d tag=%h",
                    case_number,r_status,r_found,r_inserted,r_old_value,r_count,r_tag);
            repeat (3) @(negedge clk);
            r_ready=1;@(negedge clk);r_ready=0;outputs=outputs+1;
        end
    endtask

    // Compare the physical table to a sorted dictionary snapshot using binary
    // search, independent of hashing, probe paths or tombstone placement.
    task automatic check_dictionary(input integer count);
        integer slot,live,low,high,middle,found_index;
        reg [SLOTS-1:0] seen;
        reg [KEY_W-1:0] actual_key,expected_key;
        begin
            live=0;seen=0;
            for (slot=0;slot<SLOTS;slot=slot+1) begin
                if (dut.slot_state[slot]!==0 && dut.slot_state[slot]!==1 && dut.slot_state[slot]!==2)
                    $fatal(1,"invalid metadata encoding");
                if (dut.slot_state[slot]==1) begin
                    live=live+1;actual_key=dut.entries[slot][KEY_W+VALUE_W-1:VALUE_W];
                    low=0;high=count-1;found_index=-1;
                    while (low<=high) begin
                        middle=(low+high)/2;
                        expected_key=expected[case_number*SLOTS+middle][KEY_W+VALUE_W-1:VALUE_W];
                        if (actual_key==expected_key) begin found_index=middle;low=high+1;end
                        else if (actual_key<expected_key) high=middle-1;
                        else low=middle+1;
                    end
                    if (found_index<0) $fatal(1,"unexpected resident key case=%0d",case_number);
                    if (seen[found_index]) $fatal(1,"duplicate resident key");
                    seen[found_index]=1;
                    if (dut.entries[slot][VALUE_W-1:0]!==expected[case_number*SLOTS+found_index][VALUE_W-1:0])
                        $fatal(1,"resident value mismatch case=%0d",case_number);
                end
            end
            if (live!=count || r_count!==CW'(count)) $fatal(1,"dictionary occupancy mismatch");
        end
    endtask

    string commands_path,expected_path;
    integer fd,fields,op,status_value,found_value,inserted_value,count_value,hash_value,probe,waited;
    reg [KEY_W-1:0] key_value;
    reg [VALUE_W-1:0] value,old_value;
    reg [TAG_W-1:0] tag;
    initial begin
        if (!$value$plusargs("COMMANDS=%s",commands_path) || !$value$plusargs("EXPECTED=%s",expected_path))
            $fatal(1,"missing vectors");
        fd=$fopen(commands_path,"r");if (!fd) $fatal(1,"cannot open commands");
        $readmemh(expected_path,expected);
        reset_core();
        for (case_number=0;case_number<CASES;case_number=case_number+1) begin
            fields=$fscanf(fd,"%d %h %h %h %d %d %d %h %d %d\n",op,key_value,value,tag,
                status_value,found_value,inserted_value,old_value,count_value,hash_value);
            if (fields!=10) $fatal(1,"bad command vector");
            if (op==4) reset_core();
            else begin
                launch(op[1:0],key_value,value,tag);
                if (op!=3 && dut.probe_index!==hash_value) $fatal(1,"hash mapping mismatch");
                finish_response(status_value[1:0],found_value[0],inserted_value[0],old_value,CW'(count_value),tag);
            end
            check_dictionary(count_value);
        end
        if (outputs!=RESPONSES) $fatal(1,"response count mismatch");
        $fclose(fd);
        for (probe=0;probe<7;probe=probe+1) begin
            reset_core();
            if (probe==0 || probe==5) begin
                launch(1,0,1,0);finish_response(0,0,1,0,1,0);
            end
            if (probe==0) launch(3,0,0,1);
            else if (probe==5) launch(2,0,0,1);
            else if (probe!=1) launch(1,0,1,1);
            waited=0;
            while (dut.state!=probe) begin
                @(negedge clk);waited=waited+1;
                if (waited>2*SLOTS+5) $fatal(1,"missing reset phase probe=%0d",probe);
            end
            // Immediately cancel the observed state; no extra active edge.
            reset_now();
            launch(0,0,0,0);finish_response(1,0,0,0,0,0);
        end
        if (stalls<1) $fatal(1,"no stall coverage");
        $display("PASS cases=%0d responses=%0d dictionary_checks=%0d reset_probes=7 stalls=%0d",CASES,RESPONSES,CASES,stalls);
        $finish;
    end
endmodule
