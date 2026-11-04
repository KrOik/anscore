// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_stream_sparse_matvec;
    parameter integer DATA_W=16,VECTOR_LEN=64,MAX_TERMS=64,TAG_W=8;
    localparam integer INDEX_W=(VECTOR_LEN<2)?1:$clog2(VECTOR_LEN);
    localparam integer TERM_W=(MAX_TERMS<2)?1:$clog2(MAX_TERMS+1);
    localparam integer ACC_W=2*DATA_W+$clog2(MAX_TERMS);
    reg clk=0,rst=1,v_valid=0,reload_valid=0,s_valid=0,m_ready=0;
    reg signed [DATA_W-1:0] v_data=0,s_value=0;
    reg [INDEX_W-1:0] s_index=0;
    reg s_keep=0,s_last=0;
    reg [TAG_W-1:0] s_tag=0;
    wire v_ready,reload_ready,s_ready,m_valid,m_index_error,m_overflow;
    wire signed [ACC_W-1:0] m_sum;
    wire [TERM_W-1:0] m_terms;
    wire [TAG_W-1:0] m_tag;
    stream_sparse_matvec #(.DATA_W(DATA_W),.VECTOR_LEN(VECTOR_LEN),.MAX_TERMS(MAX_TERMS),.TAG_W(TAG_W)) dut(.*);
    always #5 clk=~clk;
    integer fd,rc,kind,keep,last,nt,ie,ov,rows=0,beats=0,phase,j;
    reg [DATA_W-1:0] value;
    reg [INDEX_W-1:0] index;
    reg [TAG_W-1:0] tag,expected_tag;
    reg [ACC_W-1:0] expected_sum;
    reg [1023:0] vector_path;

    task reset_core;
        begin
            @(negedge clk);rst=1;v_valid=0;reload_valid=0;s_valid=0;m_ready=0;
            repeat(2) @(posedge clk);
            @(negedge clk);rst=0;
            #1;
            if(!v_ready || s_ready || m_valid) $fatal(1,"reset ownership");
        end
    endtask
    task load_word(input [DATA_W-1:0] data);
        begin
            @(negedge clk);v_valid=1;v_data=data;
            do @(posedge clk);while(!v_ready);
            @(negedge clk);v_valid=0;v_data=~data;
        end
    endtask
    task term(input [INDEX_W-1:0] column,input [DATA_W-1:0] data,
              input bit selected,input bit row_last,input [TAG_W-1:0] row_tag);
        integer cycles;
        begin
            @(negedge clk);s_valid=1;s_index=column;s_value=data;
            s_keep=selected;s_last=row_last;s_tag=row_tag;cycles=0;
            @(posedge clk);
            while(!s_ready) begin
                cycles=cycles+1;
                if(cycles>100) $fatal(1,"row input timeout");
                @(posedge clk);
            end
            @(negedge clk);s_valid=0;s_value=~data;s_index=~column;s_tag=~row_tag;
        end
    endtask
    task result(input [ACC_W-1:0] sum,input integer terms,
                input bit error,input bit overflow,input [TAG_W-1:0] result_tag);
        integer cycles,stall;
        begin
            cycles=0;
            while(!m_valid) begin
                @(negedge clk);cycles=cycles+1;
                if(cycles>20) $fatal(1,"result timeout");
            end
            for(stall=0;stall<6;stall=stall+1) begin
                if(!m_valid || {m_sum,m_terms,m_index_error,m_overflow,m_tag} !==
                    {sum,TERM_W'(terms),error,overflow,result_tag})
                    $fatal(1,"row%0d got sum%h terms%0d err%b ov%b tag%h expected %h/%0d/%b/%b/%h",
                        rows,m_sum,m_terms,m_index_error,m_overflow,m_tag,sum,terms,error,overflow,result_tag);
                if(s_ready || reload_ready || v_ready) $fatal(1,"accepted work with held result");
                @(negedge clk);
            end
            m_ready=1;@(posedge clk);@(negedge clk);m_ready=0;
            if(m_valid) $fatal(1,"extra result");
        end
    endtask
    task reload_vector;
        integer cycles;
        begin
            if(!reload_valid) begin @(negedge clk);reload_valid=1;end
            cycles=0;
            @(posedge clk);
            while(!reload_ready) begin
                cycles=cycles+1;
                if(cycles>20) $fatal(1,"reload timeout");
                @(posedge clk);
            end
            if(s_ready) $fatal(1,"reload priority not enforced");
            @(negedge clk);reload_valid=0;
            if(!v_ready) $fatal(1,"reload did not request full vector");
        end
    endtask

    initial begin
        // Reset while loading, computing, and holding a response, followed by
        // a complete reload and exact public-interface reuse each time.
        for(phase=0;phase<3;phase=phase+1) begin
            reset_core();
            if(phase==0) begin
                for(j=0;j<VECTOR_LEN/2;j=j+1) load_word(1);
            end else begin
                for(j=0;j<VECTOR_LEN;j=j+1) load_word({DATA_W{1'b1}});
                term(0,{DATA_W{1'b1}},1,phase==2,0);
                if(phase==2) begin
                    wait(m_valid);repeat(3) @(negedge clk);
                end
            end
            reset_core();
            for(j=0;j<VECTOR_LEN;j=j+1) load_word({DATA_W{1'b1}});
            term(0,{DATA_W{1'b1}},1,1,1);
            result(1,1,0,0,1);
        end
        reset_core();
        if(!$value$plusargs("VECTORS=%s",vector_path)) $fatal(1,"missing vectors");
        fd=$fopen(vector_path,"r");if(!fd) $fatal(1,"cannot read vectors");
        while(!$feof(fd)) begin
            rc=$fscanf(fd,"%d %h %h %d %d %h %h %d %d %d %h\n",
                kind,value,index,keep,last,tag,expected_sum,nt,ie,ov,expected_tag);
            if(rc!=11) $fatal(1,"malformed vector");
            case(kind)
                0: load_word(value);
                1: begin
                    repeat(beats%3) @(negedge clk);
                    term(index,value,1'(keep),1'(last),tag);beats=beats+1;
                    if(last) begin
                        result(expected_sum,nt,1'(ie),1'(ov),expected_tag);
                        rows=rows+1;
                    end
                end
                2: reload_vector();
                4: begin
                    @(negedge clk);reload_valid=1;
                    if(reload_ready) $fatal(1,"mid-row reload unexpectedly ready");
                end
                default: $fatal(1,"bad vector opcode");
            endcase
        end
        $fclose(fd);
        $display("PASS rows=%0d supplied_terms=%0d reset_load_compute_output=3",rows,beats);
        $finish;
    end
    initial begin #5000000;$fatal(1,"global timeout");end
endmodule
