// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_perspective_indexed;
    parameter integer W=8,H=7,TW=5,TH=4,Q=16,T=8;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,tcv=0,trr=0,iv=0,pv=0,cv=0,mr=0,dr=0;
    reg [1:0] op=0;reg [7:0] index=0;reg [31:0] rgba=0;
    reg [T-1:0] tctag=0,ctag=0;
    wire tcr,trv,ir,pr,resident,cr,mvalid,dvalid,visible,first;
    wire [1:0] trs,ds;wire [T-1:0] trtag,mtag,dtag;
    wire [16:0] trtc,dc;wire [8:0] trpc;
    wire [7:0] mx,my,alpha;wire [23:0] rgb;wire [2:0] reason;
    reg signed [9:0] x0=0,y0=0,x1=0,y1=0,x2=0,y2=0;
    reg [7:0] u0=0,v0=0,u1=0,v1=0,u2=0,v2=0;
    reg [Q-1:0] q0=0,q1=0,q2=0;
    perspective_indexed_triangle #(.WIDTH(W),.HEIGHT(H),.TEX_WIDTH(TW),.TEX_HEIGHT(TH),.Q_W(Q),.TAG_W(T)) dut(
        .clk(clk),.rst(rst),.tex_c_valid(tcv),.tex_c_ready(tcr),.tex_c_op(op),.tex_c_tag(tctag),
        .tex_r_valid(trv),.tex_r_ready(trr),.tex_r_status(trs),.tex_r_tag(trtag),.tex_r_tex_count(trtc),.tex_r_pal_count(trpc),
        .i_valid(iv),.i_ready(ir),.i_index(index),.p_valid(pv),.p_ready(pr),.p_rgba(rgba),.texture_resident(resident),
        .c_valid(cv),.c_ready(cr),.c_x0(x0),.c_y0(y0),.c_x1(x1),.c_y1(y1),.c_x2(x2),.c_y2(y2),
        .c_u0(u0),.c_v0(v0),.c_u1(u1),.c_v1(v1),.c_u2(u2),.c_v2(v2),
        .c_q0(q0),.c_q1(q1),.c_q2(q2),.c_tag(ctag),
        .m_valid(mvalid),.m_ready(mr),.m_x(mx),.m_y(my),.m_rgb(rgb),.m_alpha(alpha),
        .m_visible(visible),.m_reason(reason),.m_first(first),.m_tag(mtag),
        .d_valid(dvalid),.d_ready(dr),.d_status(ds),.d_count(dc),.d_tag(dtag));
    integer fd,fp,nc,np,rc,ci,pi,code,tagvalue,count;
    integer a,b,c,d,e,f,g,h,i,j,k,l,m,n,o;
    integer ex,ey,ergb,ea,ev,er,ef,et;
    integer configs=0,outputs=0,config_faults=0,resets=0,holds=0,done_holds=0,management_holds=0;
    integer timeout,ii,probe;
    reg [T+52:0] held_pixel;
    reg [T+18:0] held_done;
    reg [T+27:0] held_management;
    function automatic [31:0] palette(input integer value);
        integer aa,rr,gg,bb;
        begin
            aa=value%7==0?0:(value*11+1)%255+1;
            rr=(value*17+9)%256;gg=(value*29+3)%256;bb=(value*43+5)%256;
            palette={8'(aa),8'(rr),8'(gg),8'(bb)};
        end
    endfunction
    task reset_now;
        begin
            @(negedge clk);rst=1;tcv=0;trr=0;iv=0;pv=0;cv=0;mr=0;dr=0;
            #1;if(tcr||trv||ir||pr||resident||cr||mvalid||dvalid)$fatal(1,"wrapper reset masks");
            repeat(2)@(posedge clk);
            @(negedge clk);rst=0;resets=resets+1;
            repeat(3)begin @(negedge clk);if(trv||resident||cr||mvalid||dvalid)$fatal(1,"wrapper stale reset");end
        end
    endtask
    task management(input integer command,input integer expected_status,input integer texcount,input integer palcount);
        begin
            @(negedge clk);op=command;tctag=1;tcv=1;
            while(!tcr)@(negedge clk);
            @(posedge clk);@(negedge clk);tcv=0;op=3;tctag=0;
            if(!trv||trs!==2'(expected_status)||trtc!==17'(texcount)||trpc!==9'(palcount)||trtag!==T'(1))$fatal(1,"management response");
            held_management={trs,trtag,trtc,trpc};
            repeat(3)begin
                if(!trv||{trs,trtag,trtc,trpc}!==held_management||ir||pr||cr)$fatal(1,"management hold");
                management_holds=management_holds+1;@(negedge clk);
            end
            trr=1;@(posedge clk);@(negedge clk);trr=0;
        end
    endtask
    task load_texture;
        begin
            management(0,0,0,0);
            // An offered triangle must not interfere with runtime texture loading.
            cv=1;
            for(ii=0;ii<TW*TH;ii=ii+1)begin
                @(negedge clk);iv=1;index=(3*(ii%TW)+5*(ii/TW))%256;
                if(!ir||cr)$fatal(1,"texture load ownership");
                @(posedge clk);
            end
            @(negedge clk);iv=0;
            for(ii=0;ii<256;ii=ii+1)begin
                @(negedge clk);pv=1;rgba=palette(ii);
                if(!pr||cr)$fatal(1,"palette load ownership");
                @(posedge clk);
            end
            @(negedge clk);pv=0;
            // Incomplete publication and unsupported management are separately checked below.
            management(1,0,TW*TH,256);
            // Retire the held offer before the first edge at which it could be accepted.
            cv=0;
            if(!resident)$fatal(1,"resident publication");
        end
    endtask
    task fixture;
        begin
            x0=0;y0=0;x1=4;y1=0;x2=0;y2=4;
            u0=0;v0=0;u1=TW-1;v1=0;u2=0;v2=TH-1;
            q0=1;q1={Q{1'b1}};q2=1;ctag=1;
        end
    endtask
    task submit;
        begin
            @(negedge clk);cv=1;
            while(!cr)@(negedge clk);
            @(posedge clk);@(negedge clk);cv=0;x0=511;q0=0;ctag=0;
        end
    endtask
    task lock_probe;
        begin
            tcv=1;op=0;iv=1;pv=1;cv=1;
            #1;if(tcr||ir||pr||cr)$fatal(1,"primitive management lock");
        end
    endtask
    task unlock_probe;
        begin tcv=0;iv=0;pv=0;cv=0;end
    endtask
    initial begin #50000000;$fatal(1,"wrapper global timeout");end
    initial begin
        reset_now();
        management(1,2,0,0);management(0,0,0,0);management(1,1,0,0);management(3,3,0,0);
        // Six owned-transaction aborts: load/config/raster/projector/output/DONE.
        for(probe=0;probe<6;probe=probe+1)begin
            if(probe==0)begin
                @(negedge clk);iv=1;index=8'h83;
                @(posedge clk);@(negedge clk);iv=0;
            end else begin
                load_texture();fixture();submit();
                case(probe)
                    1:repeat(1)@(negedge clk);
                    2:repeat(25)@(negedge clk);
                    3:begin
                        timeout=0;while(!dut.fragment_owned)begin @(negedge clk);timeout=timeout+1;if(timeout>300)$fatal(1,"ownership timeout");end
                        repeat(8)@(negedge clk);
                    end
                    4:begin
                        timeout=0;while(!mvalid)begin @(negedge clk);timeout=timeout+1;if(timeout>500)$fatal(1,"held output timeout");end
                        repeat(3)@(negedge clk);
                    end
                    5:begin
                        mr=1;timeout=0;
                        while(!dvalid)begin @(negedge clk);timeout=timeout+1;if(timeout>3000)$fatal(1,"probe done timeout");end
                        mr=0;repeat(3)@(negedge clk);
                    end
                endcase
            end
            reset_now();
        end
        load_texture();
        fd=$fopen("config.txt","r");fp=$fopen("pixel.txt","r");
        if(fd==0||fp==0)$fatal(1,"missing wrapper vectors");
        rc=$fscanf(fd,"%d",nc);if(rc!=1||nc!=9)$fatal(1,"wrapper config header");
        rc=$fscanf(fp,"%d",np);if(rc!=1||np<1||np>512)$fatal(1,"wrapper pixel header");
        for(ci=0;ci<nc;ci=ci+1)begin
            rc=$fscanf(fd,"%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d",
                a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,tagvalue,code,count);
            if(rc!=18||count<0||count>256)$fatal(1,"wrapper config row");
            x0=a;y0=b;u0=c;v0=d;q0=e;x1=f;y1=g;u1=h;v1=i;q1=j;x2=k;y2=l;u2=m;v2=n;q2=o;ctag=tagvalue;
            submit();lock_probe();
            for(pi=0;pi<count;pi=pi+1)begin
                rc=$fscanf(fp,"%d %d %d %d %d %d %d %d",ex,ey,ergb,ea,ev,er,ef,et);
                if(rc!=8)$fatal(1,"wrapper pixel row");
                timeout=0;while(!mvalid)begin
                    @(negedge clk);timeout=timeout+1;
                    if(dvalid||timeout>2000||tcr||ir||pr||cr)$fatal(1,"early done/lock/fragment timeout");
                end
                if({mx,my,rgb,alpha,visible,reason,first,mtag}!=={8'(ex),8'(ey),24'(ergb),8'(ea),1'(ev),3'(er),1'(ef),T'(et)})
                    $fatal(1,"render mismatch cfg=%0d pixel=%0d xy=%0d,%0d reason=%0d",ci,pi,mx,my,reason);
                held_pixel={mx,my,rgb,alpha,visible,reason,first,mtag};
                repeat(4)begin
                    if(!mvalid||{mx,my,rgb,alpha,visible,reason,first,mtag}!==held_pixel||dvalid||tcr||ir||pr||cr)$fatal(1,"fragment hold/drain");
                    holds=holds+1;@(negedge clk);
                end
                mr=1;@(posedge clk);@(negedge clk);mr=0;outputs=outputs+1;
            end
            timeout=0;while(!dvalid)begin
                @(negedge clk);timeout=timeout+1;
                if(mvalid||timeout>2000||tcr||ir||pr||cr)$fatal(1,"done closure");
            end
            if(ds!==2'(code)||dc!==17'(count)||dtag!==T'(tagvalue))$fatal(1,"done mismatch");
            held_done={ds,dc,dtag};
            repeat(4)begin
                if(!dvalid||{ds,dc,dtag}!==held_done||mvalid||tcr||ir||pr||cr)$fatal(1,"done hold");
                done_holds=done_holds+1;@(negedge clk);
            end
            unlock_probe();dr=1;@(posedge clk);@(negedge clk);dr=0;
            configs=configs+1;if(code==1||code==3)config_faults=config_faults+1;
        end
        rc=$fscanf(fd,"%d",a);if(rc==1)$fatal(1,"extra wrapper config");
        rc=$fscanf(fp,"%d",a);if(rc==1)$fatal(1,"extra wrapper pixel");
        $fclose(fd);$fclose(fp);
        if(configs!=9||outputs!=np||config_faults!=2||resets!=7)$fatal(1,"wrapper counter closure");
        $display("B45_C_PASS configs=%0d outputs=%0d config_faults=%0d resets=%0d holds=%0d done_holds=%0d management_holds=%0d",configs,outputs,config_faults,resets,holds,done_holds,management_holds);
        $finish;
    end
endmodule
