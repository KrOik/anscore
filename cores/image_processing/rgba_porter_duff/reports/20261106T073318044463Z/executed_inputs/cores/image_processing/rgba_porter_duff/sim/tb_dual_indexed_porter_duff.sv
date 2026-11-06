// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_dual_indexed_porter_duff;
    parameter integer W=8,H=8,T=8;
    localparam integer N=256,P=W*H,QW=68+T,OW=70+T;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,cv=0,cb=0,rr=0,lb=0,tv=0,pv=0,sv=0,mr=0;
    reg [1:0] cop=0;reg [T-1:0] ct=0;
    reg [7:0] ti=0;reg [31:0] pa=0;reg [QW-1:0] qi=0;
    wire cr,rv,rb,tr,pr,sr,mv,resident,busy;
    wire [1:0] rs;wire [T-1:0] rt;wire [16:0] rtc;wire [8:0] rpc;
    wire [OW-1:0] mo;
    reg [QW-1:0] queries[0:2*N-1];reg [OW-1:0] golden[0:2*N-1];
    reg [7:0] tex0[0:2*P-1],tex1[0:2*P-1];reg [31:0] pal0[0:511],pal1[0:511];
    dual_indexed_porter_duff #(.TEX_WIDTH(W),.TEX_HEIGHT(H),.TAG_W(T)) dut(
        .clk(clk),.rst(rst),.c_valid(cv),.c_ready(cr),.c_bank(cb),.c_op(cop),.c_tag(ct),
        .r_valid(rv),.r_ready(rr),.r_bank(rb),.r_status(rs),.r_tag(rt),.r_tex_count(rtc),.r_pal_count(rpc),
        .load_bank(lb),.t_valid(tv),.t_ready(tr),.t_index(ti),.p_valid(pv),.p_ready(pr),.p_argb(pa),
        .s_valid(sv),.s_ready(sr),.s_src_u(qi[7:0]),.s_src_v(qi[15:8]),.s_dst_u(qi[23:16]),.s_dst_v(qi[31:24]),
        .s_mode(qi[35:32]),.s_x(qi[51:36]),.s_y(qi[67:52]),.s_tag(qi[QW-1:68]),
        .m_valid(mv),.m_ready(mr),.m_rgba(mo[31:0]),.m_error(mo[33:32]),.m_mode(mo[37:34]),
        .m_x(mo[53:38]),.m_y(mo[69:54]),.m_tag(mo[OW-1:70]),.resident(resident),.pipeline_busy(busy));
    integer checked=0,resets=0,commands=0,responses=0,pending=0,holds=0,gaps=0,cycles=0;
    reg oh=0,rh=0,ih=0;reg [OW-1:0] hold_o;reg [T+28:0] hold_r;reg [QW-1:0] hold_i;
    wire [T+28:0] response={rb,rs,rt,rtc,rpc};
    always @(posedge clk)begin
        cycles=cycles+1;if(cycles>30000)$fatal(1,"pair watchdog");
        if(rst)begin oh=0;rh=0;ih=0;end
        else begin
            if(oh&&(!mv||mo!==hold_o))$fatal(1,"pair output changed while held");
            if(rh&&(!rv||response!==hold_r))$fatal(1,"management response changed while held");
            if(ih&&(!sv||qi!==hold_i))$fatal(1,"pair source driver hold violation");
            oh=mv&&!mr;rh=rv&&!rr;ih=sv&&!sr;hold_o=mo;hold_r=response;hold_i=qi;
            if(mv&&!mr)holds=holds+1;
            if(cv&&cr)commands=commands+1;
            if(rv&&rr)responses=responses+1;
            if(dut.a_q_fire!==dut.b_q_fire)$fatal(1,"unpaired sampler query ownership");
            if(dut.a_mv && dut.b_mv && dut.pre_sr && ({dut.a_x,dut.a_y,dut.a_tag}!=={dut.b_x,dut.b_y,dut.b_tag}))$fatal(1,"sample metadata pairing");
            if(busy && (dut.a_cv || dut.b_cv || cr || tr || pr))$fatal(1,"management admitted with owned token");
        end
    end
    task command(input integer bank,input integer op);
        begin
            @(negedge clk);cv=1;cb=bank!=0;cop=2'(op);ct=T'(commands+1);
            @(posedge clk);while(!cr)@(posedge clk);
            @(negedge clk);cv=0;
        end
    endtask
    task response_ok(input integer bank,input integer op);
        begin
            wait(rv);repeat(3)@(negedge clk);
            if(rb!=(bank!=0)||rs!=0||rt!==ct || rtc!=(op==0?0:P) || rpc!=(op==0?0:256))$fatal(1,"management response payload");
            rr=1;@(posedge clk);@(negedge clk);rr=0;
        end
    endtask
    task load_data(input integer bank,input integer phase);
        integer i,j;
        begin
            i=0;j=0;lb=bank!=0;
            while(i<P || j<256)begin
                @(negedge clk);tv=i<P;pv=j<256;
                if(tv)ti=bank==0?tex0[phase*P+i]:tex1[phase*P+i];
                if(pv)pa=bank==0?pal0[phase*256+j]:pal1[phase*256+j];
                @(posedge clk);if(tv&&tr)i=i+1;if(pv&&pr)j=j+1;
            end
            @(negedge clk);tv=0;pv=0;
        end
    endtask
    task initialize_bank(input integer bank,input integer phase);
        begin command(bank,0);response_ok(bank,0);load_data(bank,phase);command(bank,1);response_ok(bank,1);end
    endtask
    task traffic(input integer phase);
        integer sent,received,ticks,source_pending;
        begin
            sent=0;received=0;ticks=0;source_pending=0;
            while(received<N)begin
                @(negedge clk);mr=ticks%13>=5;
                if(!source_pending)begin
                    sv=sent<N && ticks%7!=1 && ticks%7!=2;
                    if(sv)qi=queries[phase*N+sent];else if(sent<N)gaps=gaps+1;
                end
                @(posedge clk);if(sv&&sr)begin sent=sent+1;source_pending=0;end
                else source_pending=sv;
                if(mv&&mr)begin
                    if(mo!==golden[phase*N+received])$fatal(1,"pair mismatch phase=%0d index=%0d got=%h expected=%h",phase,received,mo,golden[phase*N+received]);
                    checked=checked+1;received=received+1;
                end
                ticks=ticks+1;
            end
            @(negedge clk);sv=0;mr=1;
            repeat(10)begin @(posedge clk);if(mv||busy)$fatal(1,"extra pair output");end
        end
    endtask
    task pending_management;
        integer sent,received;
        begin
            sent=0;received=0;
            while(sent<4)begin
                @(negedge clk);sv=1;mr=0;qi=queries[sent];
                @(posedge clk);if(sv&&sr)sent=sent+1;
            end
            @(negedge clk);sv=0;wait(mv);
            @(negedge clk);cv=1;cb=0;cop=0;ct=T'(commands+1);
            repeat(5)begin @(posedge clk);if(cr||sr||!busy)$fatal(1,"pending management crossed ownership");end
            @(negedge clk);mr=1;
            while(received<4)begin
                @(posedge clk);
                if(cr)$fatal(1,"management accepted before final owned output");
                if(mv&&mr)begin
                    if(mo!==golden[received])$fatal(1,"pending management drain mismatch");
                    checked=checked+1;received=received+1;
                end
            end
            @(posedge clk);while(!cr)@(posedge clk);
            @(negedge clk);cv=0;pending=pending+1;response_ok(0,0);
        end
    endtask
    initial begin
        $readmemh("query.hex",queries);$readmemh("golden.hex",golden);
        $readmemh("tex0.hex",tex0);$readmemh("tex1.hex",tex1);$readmemh("pal0.hex",pal0);$readmemh("pal1.hex",pal1);
        repeat(2)@(negedge clk);rst=0;resets=resets+1;
        initialize_bank(0,0);initialize_bank(1,0);if(!resident)$fatal(1,"not resident");
        traffic(0);pending_management();load_data(0,1);command(0,1);response_ok(0,1);
        initialize_bank(1,1);traffic(1);
        // Reset a held composed output and both resident banks, retaining no ownership.
        @(negedge clk);sv=1;mr=0;qi=queries[N];@(posedge clk);while(!sr)@(posedge clk);
        @(negedge clk);sv=0;wait(mv);@(negedge clk);rst=1;@(negedge clk);rst=0;mr=1;resets=resets+1;
        repeat(10)begin @(posedge clk);if(mv||rv||resident||busy||sr)$fatal(1,"pair reset flush");end
        command(0,0);wait(rv);repeat(3)@(negedge clk);
        rst=1;@(negedge clk);rst=0;resets=resets+1;
        repeat(5)begin @(posedge clk);if(rv||mv||busy||resident)$fatal(1,"held response reset flush");end
        if(checked!=516||commands!=9||responses!=8||pending!=1||resets!=3||holds==0||gaps==0)$fatal(1,"pair coverage checked=%0d cmd=%0d rsp=%0d resets=%0d",checked,commands,responses,resets);
        $display("PASS RGBA_PD_PAIR W=%0d H=%0d T=%0d checked=%0d resets=%0d commands=%0d responses=%0d pending=%0d holds=%0d gaps=%0d",W,H,T,checked,resets,commands,responses,pending,holds,gaps);$finish;
    end
endmodule
