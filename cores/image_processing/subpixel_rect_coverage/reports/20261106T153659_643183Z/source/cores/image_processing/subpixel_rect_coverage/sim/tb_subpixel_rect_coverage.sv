// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_subpixel_rect_coverage;
    parameter integer WIDTH=7,HEIGHT=5,TAG_W=8,BLEND=0;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,c_valid=0,d_valid=0,m_ready=0,r_ready=0;
    wire c_ready,d_ready,m_valid,r_valid,busy;
    reg signed [23:0] c_x0=0,c_y0=0,c_x1=0,c_y1=0;
    reg [31:0] c_paint=0,d_rgba=0;
    reg [3:0] c_mode=0;
    reg [TAG_W-1:0] c_tag=0;
    wire [15:0] m_x,m_y;
    wire [16:0] m_area,r_count,r_error_count;
    wire [32:0] r_area_sum;
    wire m_last;
    wire [TAG_W-1:0] m_tag,r_tag;
    wire [31:0] m_rgba;
    wire [1:0] m_error,r_status;
    wire [3:0] m_mode;
    generate if(BLEND) begin:g_blend
        rgba_aa_rect_blend #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.TAG_W(TAG_W)) dut(.*);
    end else begin:g_core
        subpixel_rect_coverage #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.TAG_W(TAG_W)) dut(
            .clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),
            .c_x0(c_x0),.c_y0(c_y0),.c_x1(c_x1),.c_y1(c_y1),.c_tag(c_tag),
            .m_valid(m_valid),.m_ready(m_ready),.m_x(m_x),.m_y(m_y),.m_area(m_area),
            .m_last(m_last),.m_tag(m_tag),.r_valid(r_valid),.r_ready(r_ready),
            .r_status(r_status),.r_count(r_count),.r_area_sum(r_area_sum),.r_tag(r_tag),.busy(busy));
        assign d_ready=0;assign m_rgba=0;assign m_error=0;assign m_mode=0;assign r_error_count=0;
    end endgenerate
    integer cycles=0,fd,scan,record_rows,case_count,fragment_count;
    integer case_index,pixel_index,expected_count,expected_status,expected_errors;
    integer ex,ey,ea,ee,el,mode_i,x0_i,y0_i,x1_i,y1_i;
    integer compared=0,read_rows=0,reset_checks=0,queued_commands=0;
    reg [63:0] expected_sum;
    reg [31:0] expected_tag,paint_i,destination_i,rgba_i;
    reg [1023:0] vector_path,kind,junk;
    reg [159:0] held_m,held_r;
    reg prev_m_hold=0,prev_r_hold=0,prev_d_hold=0,start_resets=0,resets_done=0;
    reg [31:0] held_d;
    wire [159:0] bundle_m={m_x,m_y,m_area,m_last,m_tag,m_rgba,m_error,m_mode};
    wire [159:0] bundle_r={r_status,r_count,r_area_sum,r_tag,r_error_count};
    always @(posedge clk) begin
        cycles=cycles+1;
        if(cycles>500000) $fatal(1,"finite cycle watchdog");
        if(rst) begin prev_m_hold=0;prev_r_hold=0;prev_d_hold=0;end
        else begin
            if(BLEND && prev_d_hold && (!d_valid || d_rgba!==held_d)) $fatal(1,"destination source changed while held");
            prev_d_hold=BLEND && d_valid && !d_ready;held_d=d_rgba;
            if(prev_m_hold && (!m_valid || bundle_m!==held_m)) $fatal(1,"fragment changed while held");
            if(prev_r_hold && (!r_valid || bundle_r!==held_r)) $fatal(1,"completion changed while held");
            prev_m_hold=m_valid && !m_ready;held_m=bundle_m;
            prev_r_hold=r_valid && !r_ready;held_r=bundle_r;
            if(busy && c_ready) $fatal(1,"command ownership escaped");
            if(m_valid && (m_area==0 || m_area>65536 || m_x>=WIDTH || m_y>=HEIGHT))
                $fatal(1,"invalid sparse fragment");
            if(m_valid && r_valid) $fatal(1,"completion overlaps final fragment");
        end
    end
    task reset_now;
        begin
            rst=1;c_valid=0;d_valid=0;m_ready=0;r_ready=0;
            #1;if(c_ready || d_ready || m_valid || r_valid || busy) $fatal(1,"reset public mask");
            repeat(2) @(posedge clk);
            @(negedge clk);rst=0;#1;
            if(!c_ready || m_valid || r_valid || busy) $fatal(1,"reset cancellation");
        end
    endtask
    task send_simple(input integer two_pixels,input [TAG_W-1:0] tag_value);
        begin
            @(negedge clk);
            if(!c_ready) $fatal(1,"simple command not ready");
            c_x0=0;c_y0=0;c_x1=two_pixels && WIDTH>1 ? 512:256;
            c_y1=two_pixels && WIDTH==1 && HEIGHT>1 ? 512:256;
            c_tag=tag_value;c_paint=32'h11223344;c_mode=1;c_valid=1;
            @(posedge clk);#1;
            @(negedge clk);c_valid=0;
        end
    endtask
    task consume_simple_pixel(input integer last_value,input [TAG_W-1:0] tag_value);
        reg done_pixel,destination_taken;
        begin
            done_pixel=0;destination_taken=0;
            while(!done_pixel) begin
                @(negedge clk);d_valid=BLEND && !destination_taken;d_rgba=0;m_ready=1;
                @(posedge clk);
                if(BLEND && d_valid && d_ready) destination_taken=1;
                if(m_valid && m_ready) begin
                    if(m_area!==17'd65536 || m_tag!==tag_value || m_last!==last_value[0] ||
                       (BLEND && (m_rgba!==32'h11223344 || m_error!==0 || m_mode!==1)))
                        $fatal(1,"simple pixel mismatch");
                    done_pixel=1;
                end
            end
            #1;@(negedge clk);d_valid=0;m_ready=0;
        end
    endtask
    task consume_simple_done(input integer count_value,input [TAG_W-1:0] tag_value);
        begin
            while(!r_valid) @(negedge clk);
            if(r_status!==0 || r_count!==count_value || r_area_sum!==count_value*65536 ||
                r_tag!==tag_value || r_error_count!==0) $fatal(1,"simple completion mismatch");
            repeat(3) @(negedge clk);
            r_ready=1;@(posedge clk);#1;@(negedge clk);r_ready=0;
        end
    endtask
    task recovery;
        begin
            send_simple(0,{TAG_W{1'b1}});
            consume_simple_pixel(1,{TAG_W{1'b1}});
            consume_simple_done(1,{TAG_W{1'b1}});
        end
    endtask
    // These target reads occur only in the matching elaborated generate branch.
    generate if(BLEND) begin:g_reset_blend
        task run_resets;
            integer stage;
            begin
                for(stage=0;stage<8;stage=stage+1) begin
                    send_simple(stage==6,1);
                    case(stage)
                        0:begin end // core CALC, immediately following command acceptance
                        1:while(!g_blend.dut.cm_valid) @(negedge clk);
                        2,3,4:begin
                            d_valid=1;d_rgba=0;
                            while(g_blend.dut.fstate!=(stage==2 ? 1:stage==3 ? 2:3)) @(negedge clk);
                        end
                        5:begin
                            d_valid=1;d_rgba=0;
                            while(!m_valid) @(negedge clk);
                        end
                        6:begin
                            consume_simple_pixel((WIDTH==1 && HEIGHT==1),1);
                        end
                        7:begin
                            consume_simple_pixel(1,1);
                            while(!r_valid) @(negedge clk);
                        end
                    endcase
                    reset_now();reset_checks=reset_checks+1;recovery();
                end
            end
        endtask
        initial begin wait(start_resets);run_resets();resets_done=1;end
    end else begin:g_reset_core
        task run_resets;
            integer stage;
            begin
                for(stage=0;stage<4;stage=stage+1) begin
                    send_simple(stage==2,1);
                    case(stage)
                        0:begin end
                        1:while(!m_valid) @(negedge clk);
                        2:consume_simple_pixel((WIDTH==1 && HEIGHT==1),1);
                        3:begin
                            consume_simple_pixel(1,1);
                            while(!r_valid) @(negedge clk);
                        end
                    endcase
                    reset_now();reset_checks=reset_checks+1;recovery();
                end
            end
        endtask
        initial begin wait(start_resets);run_resets();resets_done=1;end
    end endgenerate
    task queue_two_commands;
        reg done_second,destination_taken;
        begin
            send_simple(0,0);
            // A real second command is stable throughout first pixel and completion.
            c_x0=1;c_y0=2;c_x1=2;c_y1=3;c_tag=1;
            c_paint=32'hffffffff;c_mode=1;c_valid=1;
            consume_simple_pixel(1,0);
            consume_simple_done(1,0);
            // consume_simple_done returned at the first negedge after retirement.
            if(!c_ready) $fatal(1,"queued command did not become ready");
            @(posedge clk);if(!c_ready) $fatal(1,"queued command acceptance");
            #1;@(negedge clk);c_valid=0;d_valid=BLEND;d_rgba=0;m_ready=1;
            done_second=0;destination_taken=0;
            while(!done_second) begin
                @(posedge clk);
                if(BLEND && d_valid && d_ready) destination_taken=1;
                if(m_valid && m_ready) begin
                    if(m_area!==1 || !m_last || m_x!==0 || m_y!==0 || m_tag!==1 ||
                        (BLEND && (m_rgba!==0 || m_error!==0 || m_mode!==1)))
                        $fatal(1,"queued second result mismatch");
                    done_second=1;
                end
                #1;@(negedge clk);d_valid=BLEND && !destination_taken;
            end
            d_valid=0;m_ready=0;
            while(!r_valid) @(negedge clk);
            if(r_status!==0 || r_count!==1 || r_area_sum!==1 || r_tag!==1 || r_error_count!==0)
                $fatal(1,"queued second completion mismatch");
            r_ready=1;@(posedge clk);#1;@(negedge clk);r_ready=0;
            queued_commands=2;
        end
    endtask
    reg destination_sent,retired;
    initial begin
        if(!$value$plusargs("VECTORS=%s",vector_path)) $fatal(1,"missing vector file");
        fd=$fopen(vector_path,"r");if(!fd) $fatal(1,"cannot open vectors");
        scan=$fscanf(fd,"%d %d %d",record_rows,case_count,fragment_count);
        if(scan!=3 || case_count!=(BLEND ? 44:24)) $fatal(1,"bad vector header");
        reset_now();
        for(case_index=0;case_index<case_count;case_index=case_index+1) begin
            scan=$fscanf(fd,"%s %d %d %d %d %h %h %d %d %d %d %d",kind,
                x0_i,y0_i,x1_i,y1_i,expected_tag,paint_i,mode_i,expected_status,
                expected_count,expected_sum,expected_errors);
            if(scan!=12 || kind!="C") $fatal(1,"bad command record");read_rows=read_rows+1;
            @(negedge clk);if(!c_ready) $fatal(1,"command not ready");
            c_x0=x0_i;c_y0=y0_i;c_x1=x1_i;c_y1=y1_i;c_tag=expected_tag;
            c_paint=paint_i;c_mode=mode_i;c_valid=1;
            @(posedge clk);#1;@(negedge clk);
            c_valid=0;c_x0=-8388608;c_y0=8388607;c_x1=-1;c_y1=0;
            c_paint=32'h01000000;c_mode=15;c_tag=~expected_tag;
            for(pixel_index=0;pixel_index<expected_count;pixel_index=pixel_index+1) begin
                scan=$fscanf(fd,"%s %d %d %d %h %h %d %d",kind,ex,ey,ea,destination_i,rgba_i,ee,el);
                if(scan!=8 || kind!="P") $fatal(1,"bad pixel record");read_rows=read_rows+1;
                destination_sent=0;retired=0;
                while(!retired) begin
                    @(negedge clk);
                    d_valid=BLEND && !destination_sent && (d_valid || cycles%5>=2);
                    d_rgba=destination_i;m_ready=cycles%7>=2;
                    @(posedge clk);
                    if(r_valid) $fatal(1,"premature completion");
                    if(BLEND && d_valid && d_ready) begin
                        if(destination_sent) $fatal(1,"duplicate destination");
                        destination_sent=1;
                    end
                    if(m_valid && m_ready) begin
                        if(m_x!==ex || m_y!==ey || m_area!==ea || m_last!==el[0] ||
                            m_tag!==expected_tag[TAG_W-1:0] || m_rgba!==rgba_i || m_error!==ee ||
                            (BLEND && (m_mode!==mode_i[3:0] || !destination_sent)))
                            $fatal(1,"oracle mismatch case=%0d pixel=%0d got=(%0d,%0d,%0d,%h,%0d)",
                                case_index,pixel_index,m_x,m_y,m_area,m_rgba,m_error);
                        compared=compared+1;retired=1;
                    end
                    #1;
                end
            end
            @(negedge clk);d_valid=0;m_ready=0;
            while(!r_valid) begin
                if(d_ready || m_valid) $fatal(1,"unexpected extra fragment");
                @(negedge clk);
            end
            if(r_status!==expected_status || r_count!==expected_count || r_area_sum!==expected_sum ||
                r_tag!==expected_tag[TAG_W-1:0] || r_error_count!==expected_errors)
                $fatal(1,"completion oracle mismatch case=%0d",case_index);
            repeat(3) begin
                @(negedge clk);
                if(c_ready || d_ready || m_valid || !r_valid) $fatal(1,"held completion ownership");
            end
            r_ready=1;@(posedge clk);#1;@(negedge clk);r_ready=0;
        end
        scan=$fscanf(fd,"%s",junk);
        if((scan!=0 && scan!=-1) || !$feof(fd) || read_rows!=record_rows || compared!=fragment_count)
            $fatal(1,"strict vector EOF/count");
        $fclose(fd);
        queue_two_commands();
        start_resets=1;wait(resets_done);
        $display("B47_PASS cases=%0d fragments=%0d reset_checks=%0d queued_commands=%0d",
            case_count,compared,reset_checks,queued_commands);
        $finish;
    end
endmodule
