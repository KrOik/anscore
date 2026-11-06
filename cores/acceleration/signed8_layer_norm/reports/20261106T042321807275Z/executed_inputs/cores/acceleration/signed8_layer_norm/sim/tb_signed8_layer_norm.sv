// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_signed8_layer_norm;
    parameter integer N=9,F=12,T=8,EX=0;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,c_valid=0,c_rsp_ready=0,cmd_valid=0,s_valid=0,m_ready=0;
    wire c_ready,c_rsp_valid,cmd_ready,s_ready,m_valid;
    reg [1:0] c_op=0;reg [15:0] c_index=0;
    reg signed [15:0] c_gamma=0,c_beta=0;reg [4:0] c_shift=0;
    wire [1:0] c_error;reg [15:0] cmd_len=0,cmd_epsilon=0;
    reg [4:0] cmd_input_shift=0;reg [T-1:0] cmd_tag=0;
    reg signed [31:0] source_data=0;reg s_last=0;
    wire signed [7:0] m_data;wire [15:0] m_index;wire m_last;
    wire [2:0] m_error;wire m_clip,m_inexact,m_degenerate;
    wire [T-1:0] m_tag;wire m_input_clip,m_input_inexact;
    wire [3:0] core_state;wire input_pending;
    generate if(EX)begin:g_example
        quantized_layer_norm #(.MAX_LEN(N),.FRAC(F),.TAG_W(T)) dut(
            .clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),.c_op(c_op),
            .c_index(c_index),.c_gamma(c_gamma),.c_beta(c_beta),.c_shift(c_shift),
            .c_rsp_valid(c_rsp_valid),.c_rsp_ready(c_rsp_ready),.c_error(c_error),
            .cmd_valid(cmd_valid),.cmd_ready(cmd_ready),.cmd_len(cmd_len),
            .cmd_epsilon(cmd_epsilon),.cmd_input_shift(cmd_input_shift),.cmd_tag(cmd_tag),
            .s_valid(s_valid),.s_ready(s_ready),.s_data(source_data),.s_last(s_last),
            .m_valid(m_valid),.m_ready(m_ready),.m_data(m_data),.m_index(m_index),
            .m_last(m_last),.m_error(m_error),.m_clip(m_clip),.m_inexact(m_inexact),
            .m_degenerate(m_degenerate),.m_tag(m_tag),
            .m_input_clip(m_input_clip),.m_input_inexact(m_input_inexact));
        assign core_state=dut.normalize.state;
        assign input_pending=dut.pending;
    end else begin:g_core
        signed8_layer_norm #(.MAX_LEN(N),.FRAC(F),.TAG_W(T)) dut(
            .clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),.c_op(c_op),
            .c_index(c_index),.c_gamma(c_gamma),.c_beta(c_beta),.c_shift(c_shift),
            .c_rsp_valid(c_rsp_valid),.c_rsp_ready(c_rsp_ready),.c_error(c_error),
            .cmd_valid(cmd_valid),.cmd_ready(cmd_ready),.cmd_len(cmd_len),
            .cmd_epsilon(cmd_epsilon),.cmd_tag(cmd_tag),
            .s_valid(s_valid),.s_ready(s_ready),.s_data(source_data[7:0]),.s_last(s_last),
            .m_valid(m_valid),.m_ready(m_ready),.m_data(m_data),.m_index(m_index),
            .m_last(m_last),.m_error(m_error),.m_clip(m_clip),.m_inexact(m_inexact),
            .m_degenerate(m_degenerate),.m_tag(m_tag));
        assign core_state=dut.state;
        assign input_pending=0;
        assign m_input_clip=0;assign m_input_inexact=0;
    end endgenerate
    integer fd,rc,kind,op,idx,gamma,beta,shift,error,len,eps,ni,no,pre;
    integer value,last,clip,inexact,deg,ic,ii,phase,j,k,target;
    integer steps=0,configs=0,outputs=0,holds=0,resets=0,priorities=0,cycles=0;
    integer tail_cycle,valid_cycle,pending_resets=0;
    reg [63:0] tag;reg [1023:0] file;
    reg [T+32:0] held;
    always @(posedge clk)begin cycles<=cycles+1;if(cycles>1500000)$fatal(1,"watchdog");end
    task tick;begin @(posedge clk);#1;end endtask
    task ntick;begin @(negedge clk);end endtask
    task reset_now;begin
        rst=1;c_valid=0;c_rsp_ready=0;cmd_valid=0;s_valid=0;m_ready=0;
        #1;if(c_ready||c_rsp_valid||cmd_ready||s_ready||m_valid)$fatal(1,"reset mask");
        repeat(3)tick();ntick();rst=0;repeat(3)tick();resets=resets+1;
        if(c_rsp_valid||m_valid)$fatal(1,"ghost after reset");
    end endtask
    task reset_all;begin ntick();reset_now();end endtask
    task launch_config;begin
        ntick();c_op=op;c_index=idx;c_gamma=gamma;c_beta=beta;c_shift=shift;c_valid=1;
        do @(posedge clk);while(!c_ready);
        #1;ntick();c_valid=0;
    end endtask
    task launch_query;begin
        ntick();cmd_len=len;cmd_epsilon=eps;cmd_tag=tag;cmd_input_shift=pre;cmd_valid=1;
        do @(posedge clk);while(!cmd_ready);
        #1;ntick();cmd_valid=0;cmd_len=0;cmd_epsilon=0;cmd_tag=0;cmd_input_shift=31;
    end endtask
    task send_sample(input integer x,input integer tail);begin
        ntick();repeat(steps%3)ntick();source_data=x;s_last=tail;s_valid=1;
        do @(posedge clk);while(!s_ready);
        #1;ntick();s_valid=0;source_data=~x;s_last=!tail;
    end endtask
    task check_output;begin
        if({m_data,m_index,m_last,m_error,m_clip,m_inexact,m_degenerate,m_tag,m_input_clip,m_input_inexact}!==
           {8'(value),16'(idx),1'(last),3'(error),1'(clip),1'(inexact),1'(deg),T'(tag),1'(ic),1'(ii)})
            $fatal(1,"step%0d j%0d value%0d/%0d err%0d/%0d flags%0d%0d%0d/%0d%0d%0d input%0d%0d/%0d%0d",steps,j,m_data,value,m_error,error,m_clip,m_inexact,m_degenerate,clip,inexact,deg,m_input_clip,m_input_inexact,ic,ii);
    end endtask
    task held_output;begin
        while(!m_valid)tick();
        valid_cycle=cycles;
        if(!EX && j==0 && ni>0 && error==0 &&
           valid_cycle-tail_cycle>((18+2*$clog2(N)+2*(F+2)+1)/2)+(11+$clog2(N)+2*F)+240)
            $fatal(1,"first result source-derived cycle budget");
        repeat(2+(steps+j)%4)begin
            check_output();if(c_ready||cmd_ready||s_ready)$fatal(1,"ownership during output");
            held={m_data,m_index,m_last,m_error,m_clip,m_inexact,m_degenerate,m_tag,m_input_clip,m_input_inexact};
            tick();holds=holds+1;
            if(!m_valid || held!=={m_data,m_index,m_last,m_error,m_clip,m_inexact,m_degenerate,m_tag,m_input_clip,m_input_inexact})$fatal(1,"held payload");
        end
        ntick();m_ready=1;tick();ntick();m_ready=0;outputs=outputs+1;
    end endtask
    task pending_priority;begin
        len=1;eps=1;tag=3;pre=0;launch_query();send_sample(5,1);
        while(!m_valid)tick();if(m_data!==8'sd7 || m_error)$fatal(1,"first priority result");
        ntick();c_op=0;c_index=0;c_gamma=1;c_beta=29;c_shift=F;
        c_valid=1;cmd_len=1;cmd_epsilon=1;cmd_tag=5;cmd_input_shift=0;cmd_valid=1;
        repeat(4)begin if(c_ready||cmd_ready)$fatal(1,"future offer accepted busy");tick();end
        ntick();m_ready=1;tick();ntick();m_ready=0;
        do @(posedge clk);while(!c_ready);
        if(cmd_ready)$fatal(1,"configuration priority");
        #1;ntick();c_valid=0;
        while(!c_rsp_valid)tick();
        repeat(3)begin if(cmd_ready||c_error)$fatal(1,"reply ownership");tick();end
        ntick();c_rsp_ready=1;tick();ntick();c_rsp_ready=0;
        do @(posedge clk);while(!cmd_ready);
        #1;ntick();cmd_valid=0;send_sample(5,1);
        while(!m_valid)tick();if(m_data!==8'sd29 || m_error || m_tag!==T'(5))$fatal(1,"future command result");
        ntick();m_ready=1;tick();ntick();m_ready=0;priorities=priorities+1;
    end endtask
    initial begin
        if(!$value$plusargs("vectors=%s",file))$fatal(1,"missing vectors");
        fd=$fopen(file,"r");if(!fd)$fatal(1,"vectors open");reset_all();
        while(!$feof(fd))begin
            rc=$fscanf(fd,"%d",kind);
            if(rc==1)begin
                steps=steps+1;
                case(kind)
                    0:begin
                        rc=$fscanf(fd,"%d %d %d %d %d %d",op,idx,gamma,beta,shift,error);if(rc!=6)$fatal(1,"cfg format");
                        launch_config();while(!c_rsp_valid)tick();
                        repeat(2+steps%3)begin
                            if(c_error!==2'(error) || c_ready || cmd_ready)$fatal(1,"config response");tick();
                            if(!c_rsp_valid)$fatal(1,"config hold");
                        end
                        ntick();c_rsp_ready=1;tick();ntick();c_rsp_ready=0;configs=configs+1;
                    end
                    1:begin
                        rc=$fscanf(fd,"%d %d %d %d %d %d",len,eps,tag,pre,ni,no);if(rc!=6)$fatal(1,"query format");
                        launch_query();
                        for(j=0;j<ni;j=j+1)begin
                            rc=$fscanf(fd,"%d %d",value,last);if(rc!=2)$fatal(1,"input format");send_sample(value,last);
                        end
                        tail_cycle=cycles;
                        for(j=0;j<no;j=j+1)begin
                            rc=$fscanf(fd,"%d %d %d %d %d %d %d %d %d %d",value,idx,last,error,clip,inexact,deg,tag,ic,ii);
                            if(rc!=10)$fatal(1,"output format");held_output();
                        end
                    end
                    2:begin
                        rc=$fscanf(fd,"%d",phase);if(rc!=1)$fatal(1,"reset format");
                        if(phase==7)begin
                            op=0;idx=0;gamma=3;beta=2;shift=F;launch_config();while(!c_rsp_valid)tick();
                        end else begin
                            len=(N<3)?N:3;eps=1;tag=1;pre=0;launch_query();
                            if(phase==0)begin while(core_state!=2)tick();end
                            else if(phase==6 && EX)begin
                                send_sample(17,len==1);
                                if(!input_pending)$fatal(1,"example no pending input");
                            end else begin
                                for(k=0;k<len;k=k+1)send_sample((k==0)?-128:127,k==len-1);
                                case(phase)
                                    1:target=5;2:target=7;3:target=11;4:target=14;default:target=15;
                                endcase
                                while(core_state!=target)tick();
                            end
                        end
                        if(phase==6 && EX)begin
                            if(!input_pending)$fatal(1,"input pending lost before reset");
                            pending_resets=pending_resets+1;reset_now();
                        end else reset_all();
                    end
                    3:pending_priority();
                    default:$fatal(1,"unknown vector kind");
                endcase
            end
        end
        $fclose(fd);repeat(5)tick();if(m_valid||c_rsp_valid)$fatal(1,"tail ghost");
        $display("PASS signed8_layer_norm N=%0d F=%0d T=%0d EX=%0d configs=%0d outputs=%0d holds=%0d resets=%0d priorities=%0d pending_resets=%0d cycles=%0d",N,F,T,EX,configs,outputs,holds,resets,priorities,pending_resets,cycles);
        $finish;
    end
endmodule
