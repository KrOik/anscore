// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_indexed_bilinear_porter_duff;
    parameter integer W=5,H=4,TAG_W=8;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,c_valid=0,r_ready=0,t_valid=0,p_valid=0,s_valid=0,m_ready=0;
    wire c_ready,r_valid,t_ready,p_ready,s_ready,m_valid,resident,busy;
    reg [1:0] c_op=0;reg [TAG_W-1:0] c_tag=0;
    wire [1:0] r_status;wire [TAG_W-1:0] r_tag;wire [16:0] r_tex_count;wire [8:0] r_pal_count;
    reg [7:0] t_index=0;reg [31:0] p_argb=0;
    reg [15:0] u=0,v=0,x=0,y=0;reg [31:0] dst=0;reg [3:0] mode=0;reg [TAG_W-1:0] tag=0;
    wire [31:0] rgba;wire [1:0] error;wire [3:0] mmode;wire oob;
    wire [15:0] mx,my;wire [TAG_W-1:0] mt;
    indexed_bilinear_porter_duff #(.TEX_WIDTH(W),.TEX_HEIGHT(H),.TAG_W(TAG_W)) dut(
        .clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),.c_op(c_op),.c_tag(c_tag),
        .r_valid(r_valid),.r_ready(r_ready),.r_status(r_status),.r_tag(r_tag),.r_tex_count(r_tex_count),.r_pal_count(r_pal_count),
        .t_valid(t_valid),.t_ready(t_ready),.t_index(t_index),.p_valid(p_valid),.p_ready(p_ready),.p_argb(p_argb),
        .s_valid(s_valid),.s_ready(s_ready),.s_u(u),.s_v(v),.s_dst(dst),.s_mode(mode),.s_x(x),.s_y(y),.s_tag(tag),
        .m_valid(m_valid),.m_ready(m_ready),.m_rgba(rgba),.m_error(error),.m_mode(mmode),.m_oob(oob),
        .m_x(mx),.m_y(my),.m_tag(mt),.resident(resident),.busy(busy));
    integer cases=0,holds=0,management_holds=0,responses=0,reset_fixtures=0,management_queries=0;
    integer future_results=0,future_holds=0,future_blocked=0;
    function automatic [31:0] pal(input integer index);
        integer a;
        begin
            case(index%6)0:a=0;1:a=1;2:a=127;3:a=128;4:a=254;default:a=255;endcase
            pal={8'(a),8'(index*73+255),8'(index*29+128),8'(index*11+1)};
        end
    endfunction
    task automatic reset_now;
        begin
            @(negedge clk);rst=1;c_valid=0;r_ready=0;t_valid=0;p_valid=0;s_valid=0;m_ready=0;
            #1;if(c_ready || r_valid || t_ready || p_ready || s_ready || m_valid || resident || busy)$fatal(1,"wrapper reset masks");
            repeat(2)@(posedge clk);@(negedge clk);rst=0;
            if(m_valid || resident || s_ready)$fatal(1,"wrapper reset ownership");
        end
    endtask
    task automatic response(input integer status);
        reg [TAG_W+27:0] held;
        integer j;
        begin
            while(!r_valid)@(negedge clk);
            held={r_status,r_tag,r_tex_count,r_pal_count};
            for(j=0;j<3;j=j+1)begin
                if(!r_valid || r_status!==2'(status) || r_tag!==TAG_W'(32'h7fffffff) ||
                   {r_status,r_tag,r_tex_count,r_pal_count}!==held || c_ready || s_ready)$fatal(1,"management hold");
                @(negedge clk);management_holds=management_holds+1;
            end
            r_ready=1;@(posedge clk);@(negedge clk);r_ready=0;responses=responses+1;
        end
    endtask
    task automatic command(input integer op,status);
        begin
            @(negedge clk);c_valid=1;c_op=2'(op);c_tag=TAG_W'(32'h7fffffff);
            do @(posedge clk);while(!c_ready);
            @(negedge clk);c_valid=0;response(status);
        end
    endtask
    task automatic load(input integer epoch);
        integer tc,pc;
        begin
            command(0,0);command(1,1);tc=0;pc=0;
            while(tc<W*H || pc<256)begin
                @(negedge clk);t_valid=tc<W*H;p_valid=pc<256;
                t_index=8'(tc*37+(tc/W)*11+epoch*17);p_argb=pal(pc);
                @(posedge clk);if(t_valid && t_ready)tc=tc+1;if(p_valid && p_ready)pc=pc+1;
            end
            @(negedge clk);t_valid=0;p_valid=0;
            command(1,0);if(!resident || !s_ready)$fatal(1,"publish resident");
        end
    endtask
    task automatic score(input integer iu,iv,input [31:0] idst,input integer imode,ix,iy,
                         input [31:0] it,expected,input integer expected_error,expected_oob,pending);
        integer latency,j;
        begin
            @(negedge clk);s_valid=1;u=16'(iu);v=16'(iv);dst=idst;mode=4'(imode);x=16'(ix);y=16'(iy);tag=TAG_W'(it);
            @(posedge clk);if(!s_ready)$fatal(1,"wrapper admission");
            @(negedge clk);s_valid=0;u=0;v=0;dst=0;mode=0;x=0;y=0;tag=0;
            if(pending!=0)begin c_valid=1;c_op=3;c_tag=TAG_W'(32'h7fffffff);management_queries=management_queries+1;end
            latency=0;
            while(!m_valid)begin
                if(c_ready || t_ready || p_ready || s_ready || !busy)$fatal(1,"owned management/query gate");
                @(negedge clk);latency=latency+1;if(latency>91)$fatal(1,"wrapper deadline");
            end
            if(latency!=(expected_oob!=0?73:89))$fatal(1,"wrapper latency %0d oob%0d",latency,expected_oob);
            for(j=0;j<4;j=j+1)begin
                if(!m_valid || rgba!==expected || error!==2'(expected_error) || mmode!==4'(imode) ||
                   oob!==1'(expected_oob) || mx!==16'(ix) || my!==16'(iy) || mt!==TAG_W'(it) ||
                   c_ready || s_ready || t_ready || p_ready || !busy)$fatal(1,"wrapper value/held owner case%0d got%h exp%h error%0d",cases,rgba,expected,error);
                if(error==2)$fatal(1,"filter produced invalid premult source");
                @(negedge clk);holds=holds+1;
            end
            m_ready=1;@(posedge clk);@(negedge clk);m_ready=0;cases=cases+1;
            if(m_valid || busy)$fatal(1,"wrapper retire state");
            if(pending!=0)begin
                if(!c_ready)$fatal(1,"management cannot resume after retirement");
                @(posedge clk);@(negedge clk);c_valid=0;response(3);
            end
        end
    endtask
    task automatic future_request;
        integer phase,j,latency;
        begin
            @(negedge clk);s_valid=1;u=0;v=0;dst=0;mode=1;x=1;y=2;tag=1;
            @(posedge clk);if(!s_ready)$fatal(1,"wrapper future first accept");
            @(negedge clk);dst=32'h80402080;mode=2;x=3;y=4;tag=TAG_W'(2);
            for(phase=0;phase<2;phase=phase+1)begin
                latency=0;
                while(!m_valid)begin
                    if(s_ready || c_ready || !busy)$fatal(1,"wrapper future ownership");
                    if(phase==0)future_blocked=future_blocked+1;
                    @(negedge clk);latency=latency+1;
                    if(latency>90)$fatal(1,"wrapper future watchdog");
                end
                if(latency!=89)$fatal(1,"wrapper future latency");
                for(j=0;j<4;j=j+1)begin
                    if(!m_valid || s_ready || c_ready || rgba!==(phase==0?32'h00000000:32'h80402080) ||
                       error!==0 || oob!==0 || mmode!==4'(phase==0?1:2) || mx!==16'(phase==0?1:3) ||
                       my!==16'(phase==0?2:4) || mt!==TAG_W'(phase==0?1:2))$fatal(1,"wrapper future held result");
                    if(phase==0)future_blocked=future_blocked+1;
                    @(negedge clk);future_holds=future_holds+1;
                end
                m_ready=1;@(posedge clk);if(s_ready)$fatal(1,"wrapper same-edge future fallthrough");
                @(negedge clk);m_ready=0;future_results=future_results+1;
                if(phase==0)begin
                    if(!s_valid || !s_ready)$fatal(1,"wrapper future did not resume");
                    @(posedge clk);if(!s_ready)$fatal(1,"wrapper future second accept");
                    @(negedge clk);s_valid=0;
                end
            end
        end
    endtask
    integer i,j,epoch,f,n,rc,iu,iv,imode,ix,iy,ie,io,delay_edges;
    reg [31:0] idst,it,expected;reg [1023:0] folder,filename;
    initial begin repeat(3000000)@(posedge clk);$fatal(1,"wrapper global watchdog");end
    initial begin
        if(!$value$plusargs("vectors=%s",folder))$fatal(1,"vectors argument");
        reset_now();command(1,2);command(3,3);load(0);
        for(i=0;i<4;i=i+1)begin
            @(negedge clk);s_valid=1;u=0;v=0;dst=0;mode=1;x=1;y=2;tag=1;
            @(posedge clk);if(!s_ready)$fatal(1,"fixture accept");
            @(negedge clk);s_valid=0;
            case(i)0:delay_edges=2;1:delay_edges=25;2:delay_edges=86;default:delay_edges=95;endcase
            repeat(delay_edges)@(negedge clk);
            reset_now();reset_fixtures=reset_fixtures+1;
            repeat(95)begin @(negedge clk);if(m_valid || r_valid || resident || s_ready)$fatal(1,"wrapper canceled work leaked");end
            load(0);
        end
        future_request();
        for(epoch=0;epoch<2;epoch=epoch+1)begin
            if(epoch==1)load(1);
            if(epoch==0)filename={folder,"/vectors0.txt"};else filename={folder,"/vectors1.txt"};
            f=$fopen(filename,"r");if(f==0)$fatal(1,"wrapper vector open");
            rc=$fscanf(f,"%d\n",n);if(rc!=1 || n!=588)$fatal(1,"wrapper vector count");
            for(j=0;j<n;j=j+1)begin
                rc=$fscanf(f,"%d %d %h %d %d %d %h %h %d %d\n",iu,iv,idst,imode,ix,iy,it,expected,ie,io);
                if(rc!=10)$fatal(1,"wrapper vector parse");score(iu,iv,idst,imode,ix,iy,it,expected,ie,io,(j%31)==0);
            end
            if($fgetc(f)!=-1)$fatal(1,"wrapper trailing vectors");$fclose(f);
        end
        if(cases!=1176 || holds!=4704 || reset_fixtures!=4 || management_queries!=38 ||
           responses!=58 || management_holds!=174 || future_results!=2 || future_holds!=8 || future_blocked!=93)$fatal(1,"wrapper counters");
        $display("B46_C_WRAP_PASS cases=%0d holds=%0d reset_fixtures=%0d management_queries=%0d management_holds=%0d responses=%0d future_results=%0d future_holds=%0d future_blocked=%0d W=%0d H=%0d TAG=%0d",cases,holds,reset_fixtures,management_queries,management_holds,responses,future_results,future_holds,future_blocked,W,H,TAG_W);
        $finish;
    end
endmodule
