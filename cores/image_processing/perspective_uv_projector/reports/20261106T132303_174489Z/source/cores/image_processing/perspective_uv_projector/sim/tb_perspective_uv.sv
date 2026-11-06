// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_perspective_uv;
    parameter integer Q=16,T=8;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,c_valid=0,r_ready=0,s_valid=0,m_ready=0;
    wire c_ready,r_valid,s_ready,m_valid,configured,busy;
    reg signed [9:0] x0,y0,x1,y1,x2,y2;
    reg [7:0] u0,v0,u1,v1,u2,v2,sx,sy;
    reg [Q-1:0] q0,q1,q2;
    reg [T-1:0] ctag,stag;
    reg sf;
    wire [1:0] status;
    wire [T-1:0] rtag,mtag;
    wire [7:0] mu,mv,mx,my;wire mf,mc;
    perspective_uv_projector #(.Q_W(Q),.TAG_W(T)) dut(
        .clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),
        .c_x0(x0),.c_y0(y0),.c_x1(x1),.c_y1(y1),.c_x2(x2),.c_y2(y2),
        .c_u0(u0),.c_v0(v0),.c_u1(u1),.c_v1(v1),.c_u2(u2),.c_v2(v2),
        .c_q0(q0),.c_q1(q1),.c_q2(q2),.c_tag(ctag),
        .r_valid(r_valid),.r_ready(r_ready),.r_status(status),.r_tag(rtag),
        .s_valid(s_valid),.s_ready(s_ready),.s_x(sx),.s_y(sy),.s_first(sf),.s_tag(stag),
        .m_valid(m_valid),.m_ready(m_ready),.m_u(mu),.m_v(mv),.m_x(mx),.m_y(my),
        .m_first(mf),.m_covered(mc),.m_tag(mtag),.configured(configured),.busy(busy));
    integer fd,fq,nc,nq,rc,ci,qi,queries,code,tagvalue;
    integer a,b,c,d,e,f,g,h,i,j,k,l,m,n,o;
    integer ex,ey,et,ef,eu,ev,ec;
    integer configs=0,outputs=0,config_faults=0,resets=0,holds=0,config_holds=0;
    integer waitcycles,probe,delaycycles;
    reg [T+33:0] saved;
    reg [T+1:0] saved_response;
    task reset_now;
        begin
            @(negedge clk);rst=1;c_valid=0;s_valid=0;r_ready=0;m_ready=0;
            #1;if(c_ready||r_valid||s_ready||m_valid||configured||busy)$fatal(1,"reset masks");
            repeat(2)@(posedge clk);
            @(negedge clk);rst=0;resets=resets+1;
            repeat(2)begin @(negedge clk);if(m_valid||r_valid||configured||s_ready)$fatal(1,"stale reset");end
            if(!c_ready)$fatal(1,"reset readiness");
        end
    endtask
    task fixture;
        begin
            x0=0;y0=0;x1=8;y1=0;x2=0;y2=8;
            u0=0;v0=255;u1=255;v1=0;u2=64;v2=192;q0=1;q1={Q{1'b1}};q2=1;ctag=1;
        end
    endtask
    task offer_config;
        begin
            @(negedge clk);c_valid=1;s_valid=1;sx=255;sy=255;stag=0;sf=0;
            #1;if(s_ready)$fatal(1,"configuration offer priority");
            while(!c_ready)@(negedge clk);
            @(posedge clk);@(negedge clk);c_valid=0;s_valid=0;
            // Inputs cease to belong to the transaction after acceptance.
            x0=511;y0=-512;q0=0;ctag=0;
        end
    endtask
    task retire_config(input integer expected_code,input integer expected_tag,input integer counted);
        begin
            waitcycles=0;
            while(!r_valid)begin @(negedge clk);waitcycles=waitcycles+1;if(waitcycles>20)$fatal(1,"config timeout");end
            if(waitcycles!=(expected_code==0?15:expected_code==1?3:0))$fatal(1,"config service latency");
            if(status!==expected_code[1:0]||rtag!==T'(expected_tag))$fatal(1,"config mismatch");
            saved_response={status,rtag};
            repeat(3)begin
                if(!r_valid||{status,rtag}!==saved_response||c_ready||s_ready)$fatal(1,"response ownership");
                if(counted!=0)config_holds=config_holds+1;
                @(negedge clk);
            end
            r_ready=1;@(posedge clk);@(negedge clk);r_ready=0;
            if(configured!==(expected_code==0))$fatal(1,"configured state");
            if(counted!=0)begin configs=configs+1;if(expected_code!=0)config_faults=config_faults+1;end
        end
    endtask
    task offer_query(input integer xx,input integer yy,input integer tt,input integer ff);
        begin
            @(negedge clk);sx=xx;sy=yy;stag=tt;sf=ff;s_valid=1;
            while(!s_ready)@(negedge clk);
            @(posedge clk);@(negedge clk);s_valid=0;sx=255;sy=255;stag=0;sf=0;
        end
    endtask
    initial begin
        // Fixed global bound is subordinate to the external hard child deadline.
        #1000000;$fatal(1,"global timeout");
    end
    initial begin
        x0=0;y0=0;x1=0;y1=0;x2=0;y2=0;u0=0;v0=0;u1=0;v1=0;u2=0;v2=0;
        q0=0;q1=0;q2=0;ctag=0;stag=0;sx=0;sy=0;sf=0;
        reset_now();
        // Abort area, coefficient preparation, and held response.
        for(probe=0;probe<3;probe=probe+1)begin
            fixture();offer_config();
            case(probe)0:delaycycles=1;1:delaycycles=6;default:delaycycles=17;endcase
            repeat(delaycycles)@(negedge clk);
            reset_now();
        end
        // Abort edge, MAC, U divide, V divide, and held public output.
        for(probe=0;probe<5;probe=probe+1)begin
            fixture();offer_config();retire_config(0,1,0);offer_query(1,1,1,1);
            case(probe)0:delaycycles=1;1:delaycycles=13;2:delaycycles=32;3:delaycycles=42;default:delaycycles=49;endcase
            repeat(delaycycles)@(negedge clk);
            reset_now();
        end
        fd=$fopen("config.txt","r");fq=$fopen("query.txt","r");
        if(fd==0||fq==0)$fatal(1,"missing vectors");
        rc=$fscanf(fd,"%d",nc);if(rc!=1||nc!=12)$fatal(1,"config header");
        rc=$fscanf(fq,"%d",nq);if(rc!=1||nq!=144)$fatal(1,"query header");
        for(ci=0;ci<nc;ci=ci+1)begin
            rc=$fscanf(fd,"%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d",
                a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,tagvalue,code,queries);
            if(rc!=18||queries<0||queries>16)$fatal(1,"config row");
            x0=a;y0=b;u0=c;v0=d;q0=e;x1=f;y1=g;u1=h;v1=i;q1=j;x2=k;y2=l;u2=m;v2=n;q2=o;ctag=tagvalue;
            offer_config();retire_config(code,tagvalue,1);
            if(code!=0)begin
                repeat(3)begin @(negedge clk);if(s_ready)$fatal(1,"bad config admitted query");end
            end
            for(qi=0;qi<queries;qi=qi+1)begin
                rc=$fscanf(fq,"%d %d %d %d %d %d %d",ex,ey,et,ef,eu,ev,ec);
                if(rc!=7)$fatal(1,"query row");
                offer_query(ex,ey,et,ef);waitcycles=0;
                while(!m_valid)begin
                    @(negedge clk);waitcycles=waitcycles+1;
                    if(waitcycles>50||c_ready||s_ready)$fatal(1,"query ownership/timeout");
                end
                if(waitcycles!=(ec!=0?47:10))$fatal(1,"query service latency");
                if({mu,mv,mx,my,mf,mc,mtag}!=={8'(eu),8'(ev),8'(ex),8'(ey),1'(ef),1'(ec),T'(et)})
                    $fatal(1,"UV mismatch cfg=%0d query=%0d u=%0d v=%0d covered=%0d",ci,qi,mu,mv,mc);
                saved={mu,mv,mx,my,mf,mc,mtag};
                repeat(4)begin
                    if(!m_valid||{mu,mv,mx,my,mf,mc,mtag}!==saved||s_ready||c_ready)$fatal(1,"output hold");
                    holds=holds+1;@(negedge clk);
                end
                m_ready=1;@(posedge clk);@(negedge clk);m_ready=0;outputs=outputs+1;
            end
        end
        // Consume whitespace before testing EOF, avoiding simulator-specific EOF returns.
        rc=$fscanf(fd,"%d",a);if(rc==1)$fatal(1,"extra config row");
        rc=$fscanf(fq,"%d",a);if(rc==1)$fatal(1,"extra query row");
        $fclose(fd);$fclose(fq);
        if(configs!=12||outputs!=144||config_faults!=3||resets!=9)$fatal(1,"counter closure");
        $display("B45_C_PASS configs=%0d outputs=%0d config_faults=%0d resets=%0d holds=%0d config_holds=%0d",configs,outputs,config_faults,resets,holds,config_holds);
        $finish;
    end
endmodule
