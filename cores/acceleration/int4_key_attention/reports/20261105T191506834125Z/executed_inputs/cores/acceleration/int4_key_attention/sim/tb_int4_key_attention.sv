// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_int4_key_attention;
    parameter integer C=9,V=3,T=8;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,c_valid=0,c_rsp_ready=0,cmd_valid=0,s_valid=0,m_ready=0;
    wire c_ready,c_rsp_valid,cmd_ready,s_ready,m_valid;
    reg [2:0] c_op=0;reg [15:0] c_row=0,c_word=0;reg [31:0] c_data=0;
    reg signed [31:0] c_bias=0;reg [15:0] c_scale=0;reg [4:0] c_shift=0;reg signed [7:0] c_zero=0;
    wire [1:0] c_error;
    reg [15:0] cmd_tokens=0,cmd_cols=0,cmd_values=0;reg [7:0] cmd_x_zero=0;reg [T-1:0] cmd_tag=0;
    reg [7:0] s_data=0;reg s_last=0;wire signed [7:0] m_data;
    wire [15:0] m_index;wire m_last;wire [2:0] m_error;wire [T-1:0] m_tag;
    wire m_score_clip,m_score_inexact,m_prob_clip;wire [12:0] m_prob_sum;
    int4_key_attention #(.MAX_COLS(C),.MAX_VALUES(V),.TAG_W(T)) dut(.*);
    integer fd,rc,kind,op,row,word,bias,scale,shift,zero,error;
    reg [63:0] data,tag;
    integer nt,nc,nv,xz,ni,no,phase,j,k,value,last,idx,sc,si,pc,psum,steps=0,outputs=0,configs=0,stalls=0;
    reg [1023:0] file;
    task tick;begin @(posedge clk);#1;end endtask
    task ntick;begin @(negedge clk);end endtask
    task reset_all;begin
        ntick();rst=1;c_valid=0;cmd_valid=0;s_valid=0;c_rsp_ready=0;m_ready=0;
        #1;if(c_ready||c_rsp_valid||cmd_ready||s_ready||m_valid)$fatal(1,"reset handshake");
        repeat(3)tick();ntick();rst=0;repeat(3)tick();
        if(c_rsp_valid||m_valid)$fatal(1,"reset ghost");
    end endtask
    task busy_check;begin if(c_ready||cmd_ready)$fatal(1,"ownership step %0d",steps);end endtask
    task launch_config;begin
        ntick();c_op=op;c_row=row;c_word=word;c_data=data;c_bias=bias;c_scale=scale;c_shift=shift;c_zero=zero;c_valid=1;
        do @(posedge clk);while(!c_ready);
        #1;ntick();c_valid=0;
    end endtask
    task launch_query;begin
        ntick();cmd_tokens=nt;cmd_cols=nc;cmd_values=nv;cmd_x_zero=xz;cmd_tag=tag;cmd_valid=1;
        do @(posedge clk);while(!cmd_ready);
        #1;ntick();cmd_valid=0;
        cmd_tokens=0;cmd_cols=0;cmd_values=0;cmd_x_zero=255;cmd_tag=0;
    end endtask
    task send_byte(input integer val,input integer is_last);begin
        ntick();s_valid=1;s_data=val;s_last=is_last;
        do @(posedge clk);while(!s_ready);
        #1;ntick();s_valid=0;s_data=~val;s_last=!is_last;
    end endtask
    task check_output;begin
        if({m_data,m_index,m_last,m_error,m_score_clip,m_score_inexact,m_prob_clip,m_prob_sum,m_tag}!==
           {8'(value),16'(idx),1'(last),3'(error),1'(sc),1'(si),1'(pc),13'(psum),T'(tag)})
            $fatal(1,"step %0d output %0d value %0d/%0d err %0d/%0d flags %0d%0d%0d/%0d%0d%0d psum %0d/%0d",steps,j,m_data,value,m_error,error,m_score_clip,m_score_inexact,m_prob_clip,sc,si,pc,m_prob_sum,psum);
    end endtask
    initial begin
        if(!$value$plusargs("vectors=%s",file))$fatal(1,"missing vectors");fd=$fopen(file,"r");if(!fd)$fatal(1,"open vectors");reset_all();
        while(!$feof(fd))begin
            rc=$fscanf(fd,"%d",kind);
            if(rc==1)begin
                steps=steps+1;
                case(kind)
                    0:begin
                        rc=$fscanf(fd,"%d %d %d %d %d %d %d %d %d",op,row,word,data,bias,scale,shift,zero,error);if(rc!=9)$fatal(1,"cfg vector");
                        launch_config();while(!c_rsp_valid)tick();
                        repeat(1+steps%3)begin
                            if(c_error!==2'(error))$fatal(1,"cfg status step %0d",steps);busy_check();tick();
                            if(!c_rsp_valid)$fatal(1,"cfg hold");
                        end
                        ntick();c_rsp_ready=1;tick();ntick();c_rsp_ready=0;configs=configs+1;
                    end
                    1:begin
                        rc=$fscanf(fd,"%d %d %d %d %d %d %d",nt,nc,nv,xz,tag,ni,no);if(rc!=7)$fatal(1,"query vector");launch_query();
                        for(j=0;j<ni;j=j+1)begin
                            rc=$fscanf(fd,"%d %d",value,last);if(rc!=2)$fatal(1,"sample vector");
                            if(j%4==1)repeat(2)tick();send_byte(value,last);
                        end
                        for(j=0;j<no;j=j+1)begin
                            rc=$fscanf(fd,"%d %d %d %d %d %d %d %d %d",value,idx,last,error,sc,si,pc,psum,tag);if(rc!=9)$fatal(1,"output vector");
                            while(!m_valid)begin tick();busy_check();if(c_rsp_valid)$fatal(1,"wrong output");end
                            for(k=0;k<1+(steps+j)%5;k=k+1)begin
                                check_output();busy_check();ntick();c_data=~c_data;cmd_cols=~cmd_cols;tick();stalls=stalls+1;
                                if(!m_valid)$fatal(1,"output hold");
                            end
                            check_output();ntick();m_ready=1;tick();ntick();m_ready=0;outputs=outputs+1;
                        end
                    end
                    2:begin
                        rc=$fscanf(fd,"%d",phase);if(rc!=1)$fatal(1,"reset vector");
                        if(phase==4)begin
                            op=3;row=0;word=0;data=0;bias=0;scale=0;shift=0;zero=0;launch_config();while(!c_rsp_valid)tick();
                        end else begin
                            nt=1;nc=1;nv=1;xz=128;tag=0;launch_query();
                            if(phase==0)begin while(!s_ready)tick();end
                            else begin
                                send_byte(129,1);
                                if(phase==1)while(dut.state!=8)tick();
                                else if(phase==2)while(dut.state!=13)tick();
                                else while(!m_valid)tick();
                            end
                        end
                        busy_check();reset_all();
                    end
                    3:begin
                        // A real query remains offered behind config until acceptance.
                        ntick();c_valid=1;c_op=3;c_row=0;c_word=0;c_data=37;c_bias=0;c_scale=0;c_shift=0;c_zero=0;
                        cmd_valid=1;cmd_tokens=1;cmd_cols=1;cmd_values=1;cmd_x_zero=128;cmd_tag=0;
                        do begin @(posedge clk);if(cmd_ready)$fatal(1,"cfg priority");end while(!c_ready);
                        #1;ntick();c_valid=0;while(!c_rsp_valid)begin tick();if(cmd_ready)$fatal(1,"early query");end
                        repeat(4)begin busy_check();tick();end
                        ntick();c_rsp_ready=1;tick();ntick();c_rsp_ready=0;
                        do @(posedge clk);while(!cmd_ready);
                        #1;ntick();cmd_valid=0;send_byte(128,1);while(!m_valid)tick();
                        if(m_data!=37||!m_last||m_error||m_prob_sum!=255)$fatal(1,"priority result");
                        // Hold a real next configuration through the stalled output.
                        ntick();c_valid=1;c_op=3;c_row=0;c_word=0;c_data=38;
                        repeat(4)begin busy_check();tick();if(!m_valid||m_data!=37)$fatal(1,"future config hold");end
                        ntick();m_ready=1;tick();ntick();m_ready=0;
                        do @(posedge clk);while(!c_ready);
                        #1;ntick();c_valid=0;while(!c_rsp_valid)tick();if(c_error)$fatal(1,"future config reply");
                        ntick();c_rsp_ready=1;tick();ntick();c_rsp_ready=0;
                    end
                    default:$fatal(1,"unknown vector kind");
                endcase
            end
        end
        repeat(4)tick();if(m_valid||c_rsp_valid)$fatal(1,"trailing output");
        $display("PASS int4_key_attention C=%0d V=%0d T=%0d steps=%0d configs=%0d outputs=%0d stalls=%0d",C,V,T,steps,configs,outputs,stalls);$finish;
    end
    initial begin repeat(3000000)@(posedge clk);$fatal(1,"cycle watchdog");end
endmodule
