// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_indexed_texture;
    parameter W=9,H=5,T=8,EPOCHS=3,Q=72,PROTOCOL=1;
    localparam N=W*H;
    reg clk=0,rst=1,c_valid=0,r_ready=0,t_valid=0,p_valid=0,s_valid=0,m_ready=0;
    always #5 clk=~clk;
    reg [1:0] c_op=0;reg [T-1:0] c_tag=0,s_tag=0;
    reg [7:0] t_index=0,s_u=0,s_v=0;reg [31:0] p_rgba=0;
    reg [15:0] s_x=0,s_y=0;
    wire c_ready,r_valid,t_ready,p_ready,s_ready,m_valid,m_visible,resident,pipeline_busy;
    wire [1:0] r_status,m_reason;wire [T-1:0] r_tag,m_tag;
    wire [16:0] r_tex_count;wire [8:0] r_pal_count;
    wire [23:0] m_rgb;wire [7:0] m_alpha;wire [15:0] m_x,m_y;
    indexed_texture_sampler #(.TEX_WIDTH(W),.TEX_HEIGHT(H),.TAG_W(T)) dut(.*);
    reg [7:0] texture[0:EPOCHS*N-1];reg [31:0] palette[0:EPOCHS*256-1];
    reg [T+47:0] requests[0:EPOCHS*Q-1];reg [T+66:0] golden[0:EPOCHS*Q-1];
    wire [T+66:0] payload={m_tag,m_reason,m_visible,m_alpha,m_rgb,m_y,m_x};
    wire [T+27:0] response={r_status,r_tag,r_tex_count,r_pal_count};
    reg [T+66:0] held_payload;reg [T+27:0] held_response;
    reg held=0,rheld=0;
    integer checked=0,resets=0,holds=0,admin=0,timing=0,cycles=0;
    always @(posedge clk)begin
        cycles=cycles+1;if(cycles>1000000)$fatal(1,"finite watchdog");
        if(rst)begin held=0;rheld=0;end
        else begin
            if(held && (!m_valid || payload!==held_payload))$fatal(1,"held lookup changed");
            if(rheld && (!r_valid || response!==held_response))$fatal(1,"held management changed");
            if(m_valid && c_ready)$fatal(1,"management before pipeline drain");
            held=m_valid&&!m_ready;rheld=r_valid&&!r_ready;
            held_payload=payload;held_response=response;if(held)holds=holds+1;
        end
    end
    task reset_here;
        begin
            @(negedge clk);rst=1;c_valid=0;r_ready=0;t_valid=0;p_valid=0;s_valid=0;m_ready=0;
            #1;if(c_ready||t_ready||p_ready||s_ready||m_valid||r_valid)$fatal(1,"reset masks");
            @(posedge clk);#1;if(resident||pipeline_busy)$fatal(1,"reset ownership");
            @(negedge clk);rst=0;resets=resets+1;
        end
    endtask
    task response_ack(input integer status,input integer tc,input integer pc,input integer tag);
        begin
            #1;
            if(!r_valid || r_status!==2'(status) || r_tex_count!==17'(tc) ||
               r_pal_count!==9'(pc) || r_tag!==T'(tag))$fatal(1,"management response %0d %0d %0d",r_status,r_tex_count,r_pal_count);
            repeat(3)begin @(posedge clk);#1;if(!r_valid||c_ready||s_ready||t_ready||p_ready)$fatal(1,"management ownership");end
            @(negedge clk);r_ready=1;@(posedge clk);#1;if(r_valid)$fatal(1,"response release");
            @(negedge clk);r_ready=0;admin=admin+1;
        end
    endtask
    task command(input integer op,input integer status,input integer tc,input integer pc);
        begin
            @(negedge clk);c_valid=1;c_op=2'(op);c_tag=T'(admin+129);
            @(posedge clk);while(!c_ready)@(posedge clk);
            @(negedge clk);c_valid=0;
            response_ack(status,tc,pc,admin+129);
        end
    endtask
    task load_image(input integer epoch);
        integer ti,pi,attempt;
        begin
            command(0,0,0,0);command(1,1,0,0);
            ti=0;pi=0;attempt=0;
            while(ti<N || pi<256)begin
                @(negedge clk);t_valid=ti<N && attempt%5!=1;p_valid=pi<256 && attempt%7!=2;
                if(ti<N)t_index=texture[epoch*N+ti];
                if(pi<256)p_rgba=palette[epoch*256+pi];
                @(posedge clk);if(t_valid&&t_ready)ti=ti+1;if(p_valid&&p_ready)pi=pi+1;
                #1;attempt=attempt+1;if(attempt>N*3+1024)$fatal(1,"load watchdog");
                if(m_valid||resident||s_ready)$fatal(1,"unpublished access");
            end
            @(negedge clk);t_valid=0;p_valid=0;
            if(t_ready||p_ready)$fatal(1,"full load ports did not close");
            command(1,0,N,256);if(!resident)$fatal(1,"publication failed");
        end
    endtask
    task lookup_image(input integer epoch,input integer stress,input integer pending_admin);
        integer sent,received,attempt,first_send,last_receive,now_edge;
        begin
            sent=0;received=0;attempt=0;first_send=-1;last_receive=-1;
            while(received<Q)begin
                @(negedge clk);s_valid=sent<Q && (!stress || attempt%5!=2);
                if(sent<Q){s_tag,s_v,s_u,s_y,s_x}=requests[epoch*Q+sent];
                m_ready=!stress || attempt%7>2;
                if(pending_admin && sent==Q)begin c_valid=1;c_op=2;c_tag=T'(admin+129);end
                @(posedge clk);
                if(s_valid&&s_ready)begin if(sent==0)first_send=$time/10;sent=sent+1;end
                if(c_valid&&c_ready)$fatal(1,"command accepted before sample tail retired");
                if(m_valid&&m_ready)begin
                    if(payload!==golden[epoch*Q+received])$fatal(1,"lookup e%0d q%0d got%h expected%h",epoch,received,payload,golden[epoch*Q+received]);
                    now_edge=$time/10;
                    if(!stress)begin
                        if(received==0 && now_edge-first_send!=3)$fatal(1,"lookup acceptance latency");
                        if(received>0 && now_edge-last_receive!=1)$fatal(1,"lookup II1");
                    end
                    last_receive=now_edge;received=received+1;checked=checked+1;
                end
                #1;attempt=attempt+1;if(attempt>Q*20+100)$fatal(1,"lookup watchdog");
            end
            if(sent!=Q)$fatal(1,"input accounting");
            if(!stress)timing=timing+1;
            @(negedge clk);s_valid=0;m_ready=0;
            if(pending_admin)begin
                @(posedge clk);if(!c_ready)$fatal(1,"drained command blocked");
                @(negedge clk);c_valid=0;
                response_ack(3,N,256,admin+129);
            end
        end
    endtask
    task cancel_phase(input integer phase);
        begin
            if(phase==0)begin
                command(0,0,0,0);
                @(negedge clk);t_valid=1;p_valid=1;t_index=123;p_rgba=32'h12345678;
                @(posedge clk);#1;
            end else if(phase==4)begin
                @(negedge clk);c_valid=1;c_op=0;c_tag=1;
                @(posedge clk);while(!c_ready)@(posedge clk);#1;
                if(!r_valid)$fatal(1,"missing reset response");
            end else begin
                @(negedge clk);s_valid=1;{s_tag,s_v,s_u,s_y,s_x}=requests[0];m_ready=0;
                @(posedge clk);while(!s_ready)@(posedge clk);#1;
                if(phase!=1)begin @(negedge clk);s_valid=0;end
                if(phase==3)begin while(!m_valid)begin @(posedge clk);#1;end repeat(3)@(posedge clk);end
            end
            reset_here();load_image(0);lookup_image(0,1,1);
        end
    endtask
    integer epoch,phase;
    initial begin
        $readmemh("texture.hex",texture);$readmemh("palette.hex",palette);
        $readmemh("requests.hex",requests);$readmemh("golden.hex",golden);
        reset_here();command(1,2,0,0);
        for(epoch=0;epoch<EPOCHS;epoch=epoch+1)begin
            load_image(epoch);lookup_image(epoch,epoch!=0,PROTOCOL);
        end
        if(PROTOCOL)for(phase=0;phase<5;phase=phase+1)cancel_phase(phase);
        if(checked!=Q*(EPOCHS+(PROTOCOL?5:0)) || resets!=(PROTOCOL?6:1) || timing!=1)
            $fatal(1,"coverage accounting");
        $display("PASS INDEXED W=%0d H=%0d T=%0d epochs=%0d checked=%0d resets=%0d timing=%0d holds=%0d admin=%0d",W,H,T,EPOCHS,checked,resets,timing,holds,admin);$finish;
    end
endmodule
