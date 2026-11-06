// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_causal_palette;
    parameter integer W=7,H=5,B=10,T=8,WRAP=0;
    localparam integer N=W*H,MAX=(1<<B)-1;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,cv=0,sv=0,sof=0,eol=0,last=0,mr=0,dr=0;
    reg [B-1:0] low=0,high=0;reg [T-1:0] tag=0;
    reg [23:0] source=0;
    wire cr,sr,mv,mc,ms,me,ml,dv;wire [B-1:0] md;
    wire [15:0] mx,my;wire [T-1:0] mt,dt;wire [1:0] de;wire [3:0] phase;
    generate if(WRAP)begin:a
        rgb_palette_diffusion #(.WIDTH(W),.HEIGHT(H),.TAG_W(T)) dut(
            .clk(clk),.rst(rst),.c_valid(cv),.c_ready(cr),.c_low(low),.c_high(high),.c_tag(tag),
            .s_valid(sv),.s_ready(sr),.s_rgb(source),.s_sof(sof),.s_eol(eol),.s_last(last),
            .m_valid(mv),.m_ready(mr),.m_data(md),.m_code(mc),.m_sof(ms),.m_eol(me),.m_last(ml),
            .m_x(mx),.m_y(my),.m_tag(mt),.d_valid(dv),.d_ready(dr),.d_error(de),.d_tag(dt));
        assign phase=dut.diffuser.state;
    end else begin:c
        causal_palette_diffusion #(.WIDTH(W),.HEIGHT(H),.BITS(B),.TAG_W(T)) dut(
            .clk(clk),.rst(rst),.c_valid(cv),.c_ready(cr),.c_low(low),.c_high(high),.c_tag(tag),
            .s_valid(sv),.s_ready(sr),.s_data(source[B-1:0]),.s_sof(sof),.s_eol(eol),.s_last(last),
            .m_valid(mv),.m_ready(mr),.m_data(md),.m_code(mc),.m_sof(ms),.m_eol(me),.m_last(ml),
            .m_x(mx),.m_y(my),.m_tag(mt),.d_valid(dv),.d_ready(dr),.d_error(de),.d_tag(dt));
        assign phase=dut.state;
    end endgenerate
    reg [23:0] inputs[0:10*N-1];reg [B:0] expected[0:10*N-1];
    reg [2*B-1:0] palettes[0:9];
    integer cycle=0,epoch=0,received=0,accepted=0,total_outputs=0;
    integer frames=0,faults=0,invalids=0,resets=0,early=0,holds=0,gaps=0;
    reg checking=0,free_run=0,force_hold=0,held=0,done_held=0;
    reg [B+T+35:0] saved_output;reg [T+1:0] saved_done;
    wire [B+T+35:0] output_word={md,mc,ms,me,ml,mx,my,mt};
    always @(negedge clk)begin
        if(rst)mr=0;
        else mr=force_hold?0:free_run?1:(cycle%7!=2&&cycle%7!=3&&cycle%11!=5);
    end
    always @(posedge clk)begin
        cycle=cycle+1;
        if(cycle>250000)$fatal(1,"watchdog");
        if(rst)begin held=0;done_held=0;end
        else begin
            if(held&&(!mv||output_word!==saved_output))$fatal(1,"output hold changed");
            held=mv&&!mr;if(held)begin saved_output=output_word;holds=holds+1;end
            if(done_held&&(!dv||{de,dt}!==saved_done))$fatal(1,"done hold changed");
            done_held=dv&&!dr;if(done_held)saved_done={de,dt};
            if(checking&&sv&&sr)accepted=accepted+1;
            if(mv&&mr&&checking)begin
                if(received>=N||{mc,md}!==expected[epoch*N+received])
                    $fatal(1,"numeric epoch=%0d index=%0d got=%h expected=%h",epoch,received,{mc,md},expected[epoch*N+received]);
                if(mx!==received%W||my!==received/W||ms!==(received==0)||
                    me!==(received%W==W-1)||ml!==(received==N-1)||mt!==T'(epoch+1))
                    $fatal(1,"metadata index=%0d x=%0d y=%0d",received,mx,my);
                if(received==0&&N>1)begin
                    if(accepted>=N)$fatal(1,"frame buffered before first output");
                    early=early+1;
                end
                received=received+1;total_outputs=total_outputs+1;
            end
        end
    end
    task reset_now;
        begin
            @(negedge clk);rst=1;cv=0;sv=0;dr=0;checking=0;
            repeat(2)@(posedge clk);
            @(negedge clk);rst=0;force_hold=0;free_run=0;
        end
    endtask
    task command;
        input integer ep;input integer bad;
        begin
            @(negedge clk);epoch=ep;received=0;accepted=0;
            low=palettes[ep][B-1:0];high=palettes[ep][2*B-1:B];
            if(bad==1)high=low;
            if(bad==2)begin low=MAX;high=0;end
            tag=T'(ep+1);cv=1;
            do @(posedge clk);while(!cr);
            @(negedge clk);cv=0;
            // Live command inputs deliberately cease to describe the frame.
            low=MAX;high=0;tag=~tag;
        end
    endtask
    task pixel;
        input integer index;input integer bad;
        begin
            repeat(index%3==1?2:0)begin @(negedge clk);gaps=gaps+1;end
            @(negedge clk);source=inputs[epoch*N+index];sv=1;
            sof=index==0;eol=index%W==W-1;last=index==N-1;
            if(bad==1)sof=!sof;
            if(bad==2)eol=!eol;
            if(bad==3)last=!last;
            do @(posedge clk);while(!sr);
            @(negedge clk);sv=0;source=24'h654321;sof=0;eol=0;last=0;
        end
    endtask
    task finish;
        input integer error;input integer count;
        begin
            wait(dv);@(negedge clk);
            if(de!==error||dt!==T'(epoch+1)||received!=count)
                $fatal(1,"done mismatch error=%0d count=%0d expected=%0d",de,received,count);
            repeat(4)@(posedge clk);
            @(negedge clk);dr=1;
            @(posedge clk);@(negedge clk);dr=0;checking=0;
        end
    endtask
    task good_frame;
        input integer ep;integer i;
        begin
            command(ep,0);checking=1;
            for(i=0;i<N;i=i+1)pixel(i,0);
            finish(0,N);frames=frames+1;
        end
    endtask
    task marker_fault;
        input integer which;integer i,stop;
        begin
            command(which+2,0);checking=1;stop=N>1?N/2:0;
            for(i=0;i<stop;i=i+1)pixel(i,0);
            pixel(stop,which);finish(2,stop);faults=faults+1;
        end
    endtask
    task reset_probe;
        input integer probe;integer target,i;
        begin
            command(probe,0);checking=0;force_hold=1;
            case(probe)
                0:target=1;1:target=2;2:target=3;3:target=4;
                4:target=H>1?5:4;5:target=H>1?6:3;6:target=H>1?7:4;
                7:target=8;default:target=9;
            endcase
            if(probe==8)begin
                force_hold=0;free_run=1;
                for(i=0;i<N;i=i+1)pixel(i,0);
            end else if(probe>1)pixel(0,0);
            wait(phase==target);
            if(probe==7)begin
                @(negedge clk);cv=1;
                repeat(3)begin @(posedge clk);if(cr)$fatal(1,"command crossed held output");end
            end
            reset_now();resets=resets+1;
            good_frame(probe);
        end
    endtask
    integer e;
    initial begin
        $readmemh("input.hex",inputs);$readmemh("expected.hex",expected);$readmemh("palette.hex",palettes);
        reset_now();
        for(e=0;e<10;e=e+1)good_frame(e);
        command(0,1);checking=1;finish(1,0);invalids=invalids+1;
        command(1,2);checking=1;finish(1,0);invalids=invalids+1;
        for(e=1;e<=3;e=e+1)marker_fault(e);
        for(e=0;e<9;e=e+1)reset_probe(e);
        if(frames!=19||faults!=3||invalids!=2||resets!=9||holds==0||
            (N>1&&early!=22))$fatal(1,"coverage frames=%0d faults=%0d invalids=%0d resets=%0d early=%0d holds=%0d",frames,faults,invalids,resets,early,holds);
        $display("B43_C_PASS frames=%0d faults=%0d invalids=%0d resets=%0d outputs=%0d early=%0d holds=%0d gaps=%0d",frames,faults,invalids,resets,total_outputs,early,holds,gaps);
        $finish;
    end
endmodule
