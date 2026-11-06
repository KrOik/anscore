// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_multistop_linear_gradient;
    parameter integer MAX_STOPS=16,TAG_W=8,EXAMPLE=0;
    reg clk=0;always #5 clk=!clk;
    reg rst=1,c_valid=0,r_ready=0,t_valid=0,s_valid=0,m_ready=0;
    wire c_ready,r_valid,t_ready,s_ready,m_valid,configured,loading,busy;
    reg [1:0] c_op=0,c_spread=0;
    reg [31:0] c_count=0,t_rgba=0,s_dst=0;
    reg signed [17:0] c_x0=0,c_y0=0,c_x1=0,c_y1=0,s_px=0,s_py=0;
    reg [TAG_W-1:0] c_tag=0,s_tag=0;
    wire [TAG_W-1:0] r_tag,m_tag;
    wire [2:0] r_status;wire [31:0] r_count;
    reg [16:0] t_offset=0;reg [15:0] s_x=0,s_y=0;
    reg [3:0] s_mode=0;
    wire [31:0] m_rgba;wire [15:0] m_x,m_y;
    wire m_degenerate;wire [1:0] m_error;wire [3:0] m_mode;
    generate if(EXAMPLE)begin:with_blend
        linear_gradient_porter_duff #(.MAX_STOPS(MAX_STOPS),.TAG_W(TAG_W)) dut(.*);
    end else begin:paint_only
        multistop_linear_gradient #(.MAX_STOPS(MAX_STOPS),.TAG_W(TAG_W)) dut(
            .clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),.c_op(c_op),.c_count(c_count),
            .c_spread(c_spread),.c_x0(c_x0),.c_y0(c_y0),.c_x1(c_x1),.c_y1(c_y1),.c_tag(c_tag),
            .r_valid(r_valid),.r_ready(r_ready),.r_status(r_status),.r_count(r_count),.r_tag(r_tag),
            .t_valid(t_valid),.t_ready(t_ready),.t_offset(t_offset),.t_rgba(t_rgba),
            .s_valid(s_valid),.s_ready(s_ready),.s_px(s_px),.s_py(s_py),.s_x(s_x),.s_y(s_y),.s_tag(s_tag),
            .m_valid(m_valid),.m_ready(m_ready),.m_rgba(m_rgba),.m_x(m_x),.m_y(m_y),.m_tag(m_tag),
            .m_degenerate(m_degenerate),.configured(configured),.loading(loading),.busy(busy));
        assign m_error=0;assign m_mode=0;
    end endgenerate
    integer file_handle,rc,case_total,case_index,stop_total,spread_value,query_total,index;
    integer x0_value,y0_value,x1_value,y1_value,offset_value,px_value,py_value,x_value,y_value,mode_value,error_value,degenerate_value;
    reg [31:0] color_value,destination_value,tag_value,expected_value;
    integer main_outputs=0,main_holds=0,live_resets=0,recovery_outputs=0,future_results=0,management_results=0;
    integer ticks,hold_index,phase;
    string vector_path;
    reg [70+TAG_W:0] held_output;
    reg [34+TAG_W:0] held_response;
    task wait_reply;
        begin ticks=0;while(!r_valid)begin @(negedge clk);ticks=ticks+1;if(ticks>5000)$fatal(1,"reply timeout");end end
    endtask
    task command(input [1:0] op,input integer count_value,input integer spread_input,
                 input integer ax,input integer ay,input integer bx,input integer by,input integer tag_input);
        begin
            @(negedge clk);c_valid=1;c_op=op;c_count=count_value;c_spread=spread_input;
            c_x0=ax;c_y0=ay;c_x1=bx;c_y1=by;c_tag=tag_input;
            begin:admit_command
                integer guard;guard=0;
                forever begin @(posedge clk);guard=guard+1;if(c_ready)disable admit_command;if(guard>5000)$fatal(1,"command admission");end
            end
            @(negedge clk);c_valid=0;c_count=32'hffffffff;c_x0=18'sh20000;c_x1=18'sh1ffff;
        end
    endtask
    task retire_reply(input integer status_value,input integer count_value,input integer tag_input);
        begin
            wait_reply();
            if(r_status!==status_value || r_count!==count_value || r_tag!==TAG_W'(tag_input))
                $fatal(1,"reply got status=%0d count=%0d tag=%0h expected=%0d/%0d/%0h",r_status,r_count,r_tag,status_value,count_value,TAG_W'(tag_input));
            held_response={r_status,r_count,r_tag};
            repeat(3)begin @(posedge clk);if(!r_valid || {r_status,r_count,r_tag}!==held_response || s_ready || t_ready || c_ready)$fatal(1,"reply hold");@(negedge clk);end
            r_ready=1;@(posedge clk);if(!r_valid || c_ready || s_ready || t_ready)$fatal(1,"reply fallthrough");
            @(negedge clk);r_ready=0;
        end
    endtask
    task stop_offer(input integer offset_input,input [31:0] rgba_input);
        begin
            @(negedge clk);t_valid=1;t_offset=offset_input;t_rgba=rgba_input;
            begin:admit_stop
                integer guard;guard=0;
                forever begin @(posedge clk);guard=guard+1;if(t_ready)disable admit_stop;if(guard>5000)$fatal(1,"stop admission");end
            end
            @(negedge clk);t_valid=0;t_offset=17'h1ffff;t_rgba=32'hffffffff;
        end
    endtask
    task query_offer(input integer point_x,input integer point_y,input [31:0] destination,
        input integer blend,input integer output_x,input integer output_y,input integer tag_input);
        begin
            @(negedge clk);s_valid=1;s_px=point_x;s_py=point_y;s_dst=destination;s_mode=blend;
            s_x=output_x;s_y=output_y;s_tag=tag_input;
            begin:admit_query
                integer guard;guard=0;
                forever begin @(posedge clk);guard=guard+1;if(s_ready)disable admit_query;if(guard>10000)$fatal(1,"query admission");end
            end
            @(negedge clk);s_valid=0;s_px=-131072;s_py=131071;s_dst=32'hffffffff;s_mode=15;s_x=0;s_y=0;s_tag=0;
        end
    endtask
    task check_output(input [31:0] expected,input integer error_input,input integer degenerate_input,
        input integer output_x,input integer output_y,input integer tag_input,input integer blend,input integer main_case);
        begin
            ticks=0;while(!m_valid)begin
                @(negedge clk);ticks=ticks+1;
                if(s_ready || c_ready || t_ready)$fatal(1,"ownership released early");
                if(ticks>10000)$fatal(1,"output timeout");
            end
            if(m_rgba!==expected || m_error!==error_input || m_degenerate!==degenerate_input ||
               m_x!==16'(output_x) || m_y!==16'(output_y) || m_tag!==TAG_W'(tag_input) ||
               (EXAMPLE && m_mode!==4'(blend)))
                $fatal(1,"output case=%0d query=%0d rgba=%h expected=%h error=%0d/%0d xy=%h/%h tag=%h degenerate=%0d/%0d",case_index,index,m_rgba,expected,m_error,error_input,m_x,m_y,m_tag,m_degenerate,degenerate_input);
            held_output={m_rgba,m_error,m_mode,m_x,m_y,m_tag,m_degenerate};
            repeat(4)begin
                @(posedge clk);if(!m_valid || {m_rgba,m_error,m_mode,m_x,m_y,m_tag,m_degenerate}!==held_output || s_ready || c_ready || t_ready)$fatal(1,"output hold");
                @(negedge clk);if(main_case)main_holds=main_holds+1;
            end
            m_ready=1;@(posedge clk);if(!m_valid || s_ready || c_ready)$fatal(1,"output fallthrough");
            @(negedge clk);m_ready=0;if(main_case)main_outputs=main_outputs+1;
        end
    endtask
    task reset_now;
        begin
            @(negedge clk);rst=1;c_valid=0;t_valid=0;s_valid=0;r_ready=0;m_ready=0;
            #1;if(c_ready || t_ready || s_ready || r_valid || m_valid || configured || loading || busy)$fatal(1,"reset masks");
            repeat(3)@(posedge clk);
            @(negedge clk);rst=0;
            repeat(3)begin @(negedge clk);if(configured || loading || m_valid || r_valid || s_ready || t_ready)$fatal(1,"stale reset state");end
        end
    endtask
    task recover;
        begin
            command(0,1,2,0,0,0,0,3);retire_reply(0,0,3);
            stop_offer(32768,32'h30402080);
            command(1,0,0,0,0,0,0,4);retire_reply(0,1,4);
            query_offer(128,128,0,1,21,22,5);
            check_output(32'h30402080,0,1,21,22,5,1,0);recovery_outputs=recovery_outputs+1;
        end
    endtask
    initial begin
        if(!$value$plusargs("vectors=%s",vector_path))$fatal(1,"vectors missing");
        reset_now();
        file_handle=$fopen(vector_path,"r");if(!file_handle)$fatal(1,"vector open");
        rc=$fscanf(file_handle,"%d",case_total);if(rc!=1 || case_total!=15)$fatal(1,"case header");
        for(case_index=0;case_index<case_total;case_index=case_index+1)begin
            rc=$fscanf(file_handle,"%d %d %d %d %d %d %d",stop_total,spread_value,x0_value,y0_value,x1_value,y1_value,query_total);
            if(rc!=7)$fatal(1,"config vector");
            command(0,stop_total,spread_value,x0_value,y0_value,x1_value,y1_value,case_index);retire_reply(0,0,case_index);
            for(index=0;index<stop_total;index=index+1)begin
                rc=$fscanf(file_handle,"%d %h",offset_value,color_value);if(rc!=2)$fatal(1,"stop vector");
                stop_offer(offset_value,color_value);
            end
            command(1,0,0,0,0,0,0,case_index+1);retire_reply(0,stop_total,case_index+1);
            if(!configured || loading)$fatal(1,"publication");
            for(index=0;index<query_total;index=index+1)begin
                rc=$fscanf(file_handle,"%d %d %h %d %d %d %h %h %d %d",px_value,py_value,destination_value,mode_value,x_value,y_value,tag_value,expected_value,error_value,degenerate_value);
                if(rc!=10)$fatal(1,"query vector");
                query_offer(px_value,py_value,destination_value,mode_value,x_value,y_value,tag_value);
                check_output(expected_value,error_value,degenerate_value,x_value,y_value,tag_value,mode_value,1);
            end
        end
        // Consume only ASCII whitespace through EOF; reject any trailing token/byte.
        rc=$fgetc(file_handle);
        while(rc!=-1)begin
            if(rc!=9 && rc!=10 && rc!=11 && rc!=12 && rc!=13 && rc!=32)$fatal(1,"extra vector bytes");
            rc=$fgetc(file_handle);
        end
        $fclose(file_handle);
        // All management errors are checked without treating unrun model data as proof.
        command(2,0,0,0,0,0,0,0);retire_reply(0,0,0);
        command(1,0,0,0,0,0,0,1);retire_reply(5,0,1);
        command(0,0,0,0,0,256,0,2);retire_reply(2,0,2);
        command(0,MAX_STOPS+1,0,0,0,256,0,3);retire_reply(2,0,3);
        command(0,1,3,0,0,256,0,4);retire_reply(3,0,4);
        command(0,1,0,0,0,256,0,5);retire_reply(0,0,5);
        command(1,0,0,0,0,0,0,6);retire_reply(1,0,6);
        stop_offer(65537,32'h00000000);command(1,0,0,0,0,0,0,7);retire_reply(4,1,7);
        command(0,1,0,0,0,256,0,8);retire_reply(0,0,8);
        stop_offer(0,32'hff000000);command(1,0,0,0,0,0,0,9);retire_reply(4,1,9);
        if(MAX_STOPS>1)begin
            command(0,2,0,0,0,256,0,10);retire_reply(0,0,10);
            stop_offer(40000,0);stop_offer(39999,0);command(1,0,0,0,0,0,0,11);retire_reply(4,2,11);
        end
        command(3,0,0,0,0,0,0,12);retire_reply(6,MAX_STOPS>1?2:1,12);
        // Reset cancels 8 distinct externally owned phases; each gets a fresh load.
        for(phase=0;phase<8;phase=phase+1)begin
            command(0,(phase==4 && MAX_STOPS>1)?2:1,1,-256,0,256,0,phase);
            if(phase==0)repeat(10)@(negedge clk);
            else begin
                if(phase==6)begin wait_reply();end
                else begin
                    retire_reply(0,0,phase);
                    if(phase==7)begin end
                    else begin
                        stop_offer(0,32'h30402080);
                        if(phase==1)repeat(5)@(negedge clk);
                        else begin
                            if(phase==4 && MAX_STOPS>1)stop_offer(65536,32'h10203040);
                            command(1,0,0,0,0,0,0,phase);retire_reply(0,(phase==4 && MAX_STOPS>1)?2:1,phase);
                            query_offer(129,17,0,1,1,2,3);
                            if(phase==5)begin ticks=0;while(!m_valid)begin @(negedge clk);ticks=ticks+1;if(ticks>10000)$fatal(1,"reset held timeout");end end
                            else repeat(phase==2?5:phase==3?40:200)@(negedge clk);
                        end
                    end
                end
            end
            reset_now();live_resets=live_resets+1;recover();
        end
        // Pending management must drain the entire public composition owner.
        query_offer(1,2,0,1,51,52,8);
        @(negedge clk);c_valid=1;c_op=3;c_tag=9;
        check_output(32'h30402080,0,1,51,52,8,1,0);management_results=management_results+1;
        begin:management_admit
            integer guard;guard=0;
            forever begin @(posedge clk);guard=guard+1;if(c_ready)disable management_admit;if(guard>100)$fatal(1,"pending management admission");end
        end
        @(negedge clk);c_valid=0;retire_reply(6,1,9);
        // A legal second query stays offered through the first query and held output.
        query_offer(1,2,0,1,31,32,6);
        @(negedge clk);s_valid=1;s_px=3;s_py=4;s_dst=0;s_mode=1;s_x=41;s_y=42;s_tag=7;
        check_output(32'h30402080,0,1,31,32,6,1,0);future_results=future_results+1;
        begin:future_admit
            integer guard;guard=0;
            forever begin @(posedge clk);guard=guard+1;if(s_ready)disable future_admit;if(guard>100)$fatal(1,"future admission");end
        end
        @(negedge clk);s_valid=0;
        check_output(32'h30402080,0,1,41,42,7,1,0);future_results=future_results+1;
        if(main_outputs!=635 || main_holds!=2540 || live_resets!=8 || recovery_outputs!=8 || future_results!=2)$fatal(1,"counter mismatch");
        $display("GRADIENT_PASS cases=%0d main_outputs=%0d main_holds=%0d live_resets=%0d recovery_outputs=%0d future_results=%0d management_results=%0d",case_total,main_outputs,main_holds,live_resets,recovery_outputs,future_results,management_results);
        $finish;
    end
    initial begin #100000000;$fatal(1,"global watchdog");end
endmodule
