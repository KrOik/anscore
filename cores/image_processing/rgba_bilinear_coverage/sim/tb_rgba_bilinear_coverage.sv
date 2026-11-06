// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_rgba_bilinear_coverage;
    parameter integer TAG_W=8;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,s_valid=0,m_ready=0;
    wire s_ready,m_valid,busy;
    reg [31:0] p00=0,p10=0,p01=0,p11=0;
    reg [7:0] fx=0,fy=0;reg [15:0] x=0,y=0;reg [TAG_W-1:0] tag=0;
    wire [31:0] rgba;wire [15:0] mx,my;wire [TAG_W-1:0] mt;
    rgba_bilinear_coverage #(.TAG_W(TAG_W)) dut(
        .clk(clk),.rst(rst),.s_valid(s_valid),.s_ready(s_ready),
        .s_00(p00),.s_10(p10),.s_01(p01),.s_11(p11),.s_fx(fx),.s_fy(fy),
        .s_x(x),.s_y(y),.s_tag(tag),.m_valid(m_valid),.m_ready(m_ready),
        .m_rgba(rgba),.m_x(mx),.m_y(my),.m_tag(mt),.busy(busy));
    integer holds=0,reset_fixtures=0,fixture_outputs=0,cases=0;
    integer future_results=0,future_holds=0,future_blocked=0;
    task automatic reset_now;
        begin
            @(negedge clk);rst=1;s_valid=0;m_ready=0;
            #1;if(s_ready || m_valid || busy)$fatal(1,"reset masks");
            repeat(2)@(posedge clk);
            @(negedge clk);rst=0;
            if(m_valid)$fatal(1,"reset stale output");
        end
    endtask
    task automatic score(input [31:0] a,b,c,d,input integer fxx,fyy,xx,yy,
                         input [31:0] tt,expected,input integer counted);
        integer latency,j;
        begin
            @(negedge clk);p00=a;p10=b;p01=c;p11=d;fx=8'(fxx);fy=8'(fyy);
            x=16'(xx);y=16'(yy);tag=TAG_W'(tt);s_valid=1;
            @(posedge clk);if(!s_ready)$fatal(1,"unexpected command block");
            @(negedge clk);s_valid=0;p00=~a;p10=~b;p01=~c;p11=~d;fx=0;fy=0;x=0;y=0;tag=0;
            latency=0;
            while(!m_valid)begin
                if(s_ready || !busy)$fatal(1,"ownership during calculation");
                @(negedge clk);latency=latency+1;
                if(latency>70)$fatal(1,"core latency watchdog");
            end
            if(latency!=69)$fatal(1,"core valid latency %0d",latency);
            for(j=0;j<4;j=j+1)begin
                if(!m_valid || s_ready || !busy || rgba!==expected || mx!==16'(xx) ||
                   my!==16'(yy) || mt!==TAG_W'(tt))$fatal(1,"core value/hold case%0d got%h exp%h",cases,rgba,expected);
                if(rgba[31:24]>rgba[7:0] || rgba[23:16]>rgba[7:0] || rgba[15:8]>rgba[7:0])
                    $fatal(1,"premultiplied invariant");
                @(negedge clk);if(counted!=0)holds=holds+1;
            end
            m_ready=1;@(posedge clk);if(!m_valid)$fatal(1,"missing retirement");
            @(negedge clk);m_ready=0;
            if(m_valid || !s_ready || busy)$fatal(1,"core retirement state");
            if(counted!=0)cases=cases+1;else fixture_outputs=fixture_outputs+1;
        end
    endtask
    task automatic future_request;
        integer phase,j,latency;
        reg [31:0] expected;
        begin
            @(negedge clk);s_valid=1;p00=32'hffffffff;p10=p00;p01=p00;p11=p00;
            fx=255;fy=255;x=1;y=2;tag=1;
            @(posedge clk);if(!s_ready)$fatal(1,"future first acceptance");
            @(negedge clk);
            p00=32'h00ffffff;p10=p00;p01=p00;p11=p00;fx=128;fy=128;x=3;y=4;tag=TAG_W'(2);
            for(phase=0;phase<2;phase=phase+1)begin
                latency=0;
                while(!m_valid)begin
                    if(s_ready)$fatal(1,"future accepted during calculation");
                    if(phase==0)future_blocked=future_blocked+1;
                    @(negedge clk);latency=latency+1;
                    if(latency>70)$fatal(1,"future latency watchdog");
                end
                if(latency!=69)$fatal(1,"future latency");
                expected=phase==0?32'hffffffff:32'h00000000;
                for(j=0;j<4;j=j+1)begin
                    if(!m_valid || s_ready || rgba!==expected || mx!==16'(phase==0?1:3) ||
                       my!==16'(phase==0?2:4) || mt!==TAG_W'(phase==0?1:2))$fatal(1,"future held payload/ownership");
                    if(phase==0)future_blocked=future_blocked+1;
                    @(negedge clk);future_holds=future_holds+1;
                end
                m_ready=1;@(posedge clk);if(s_ready)$fatal(1,"future same-edge fallthrough");
                @(negedge clk);m_ready=0;future_results=future_results+1;
                if(phase==0)begin
                    if(!s_ready || !s_valid)$fatal(1,"future did not resume");
                    @(posedge clk);if(!s_ready)$fatal(1,"future second acceptance");
                    @(negedge clk);s_valid=0;
                end
            end
        end
    endtask
    integer f,n,rc,i,j,delay_edges,ix,iy,ifx,ify;
    reg [31:0] a,b,c,d,it,expected;
    reg [1023:0] folder,filename;
    initial begin repeat(1000000)@(posedge clk);$fatal(1,"global watchdog");end
    initial begin
        if(!$value$plusargs("vectors=%s",folder))$fatal(1,"vectors argument");
        reset_now();
        for(i=0;i<6;i=i+1)begin
            case(i)0:delay_edges=2;1:delay_edges=4;2:delay_edges=7;
                    3:delay_edges=11;4:delay_edges=18;default:delay_edges=73;endcase
            @(negedge clk);s_valid=1;p00=32'hffffffff;p10=0;p01=0;p11=0;fx=128;fy=128;
            @(posedge clk);if(!s_ready)$fatal(1,"reset fixture admission");
            @(negedge clk);s_valid=0;
            repeat(delay_edges)@(negedge clk);
            reset_now();reset_fixtures=reset_fixtures+1;
            for(j=0;j<72;j=j+1)begin @(negedge clk);if(m_valid || !s_ready)$fatal(1,"canceled work leaked");end
            score(32'hffffffff,32'hffffffff,32'hffffffff,32'hffffffff,255,255,65535,32768,32'hffffffff,32'hffffffff,0);
        end
        future_request();
        filename={folder,"/vectors0.txt"};f=$fopen(filename,"r");if(f==0)$fatal(1,"vector open");
        rc=$fscanf(f,"%d\n",n);if(rc!=1 || n!=268)$fatal(1,"vector count");
        for(i=0;i<n;i=i+1)begin
            rc=$fscanf(f,"%h %h %h %h %d %d %d %d %h %h\n",a,b,c,d,ifx,ify,ix,iy,it,expected);
            if(rc!=10)$fatal(1,"vector parse");score(a,b,c,d,ifx,ify,ix,iy,it,expected,1);
        end
        if($fgetc(f)!=-1)$fatal(1,"vector trailing data");$fclose(f);
        if(cases!=268 || holds!=1072 || reset_fixtures!=6 || fixture_outputs!=6 ||
           future_results!=2 || future_holds!=8 || future_blocked!=73)$fatal(1,"core counters");
        $display("B46_C_CORE_PASS cases=%0d holds=%0d reset_fixtures=%0d fixture_outputs=%0d future_results=%0d future_holds=%0d future_blocked=%0d TAG=%0d",cases,holds,reset_fixtures,fixture_outputs,future_results,future_holds,future_blocked,TAG_W);
        $finish;
    end
endmodule
