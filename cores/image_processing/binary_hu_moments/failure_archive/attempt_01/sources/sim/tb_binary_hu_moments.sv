`timescale 1ns/1ps
`default_nettype none
module tb_binary_hu_moments;
    parameter integer WIDTH=8,HEIGHT=8,TAG_W=8,CYCLE_LIMIT=64000;
    localparam integer N=WIDTH*HEIGHT,A=($clog2(N)<1)?1:$clog2(N),
      L=($clog2((WIDTH>HEIGHT)?WIDTH:HEIGHT)<1)?1:$clog2((WIDTH>HEIGHT)?WIDTH:HEIGHT),
      RW=A+3*L+1,WW=(12*(A+L)+9>18*A+2)?12*(A+L)+9:18*A+2,CW=$clog2(N+1);
    reg clk=0,rst=1,s_valid=0,m_ready=0;
    always #5 clk=~clk;
    reg s_pixel=0,s_sof=0,s_eol=0,s_bad=0;
    reg [TAG_W-1:0] s_tag=0;
    wire s_ready,m_valid,m_keep,m_last;
    wire signed [WW-1:0] m_numerator;
    wire [WW-1:0] m_denominator;
    wire [2:0] m_index;
    wire [3:0] m_errors;
    wire [CW-1:0] m_area;
    wire [TAG_W-1:0] m_tag;
    binary_hu_moments #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.TAG_W(TAG_W)) dut(.*);
    integer nt[0:3],no[0:3],errs[0:3],areas[0:3],is_complete[0:3],first_latency[0:3];
    integer td[0:3][0:1023],ts[0:3][0:1023],te[0:3][0:1023],tb[0:3][0:1023];
    reg [TAG_W-1:0] tt[0:3][0:1023],tags[0:3];
    reg signed [255:0] en[0:3][0:6];
    reg [255:0] ed[0:3][0:6],cd[0:3][0:6];
    integer ei[0:3][0:6],ek[0:3][0:6],el[0:3][0:6],ee[0:3][0:6],ea[0:3][0:6];
    reg [TAG_W-1:0] et[0:3][0:6];
    reg [127:0] raw_expect[0:3][0:9];
    integer accepted[0:3],retired[0:3],completed[0:3],last_cycle[0:3],seen[0:3],blocked[0:3];
    integer mode,target=-1,entries,drive_slot=-1,active_slot=-1,cycles=0,hold_age=0;
    integer frames=0,outputs=0,queued=0,source_holds=0,output_holds=0,latency=0;
    integer bank=0,alu=0,mul=0,raw_checks=0,resets=0,reset_offers=0,next_seen=0,state_mask=0;
    integer reset_search=0,fd,rc,k,z,slot,index,goal,tail_byte;
    reg [4095:0] input_path;
    reg [31:0] owned=0;
    reg held_s=0,held_m=0;
    reg [TAG_W+3:0] source_hold;
    reg [2*WW+CW+TAG_W+8:0] output_hold;
    wire [TAG_W+3:0] source_bundle={s_pixel,s_sof,s_eol,s_bad,s_tag};
    wire [2*WW+CW+TAG_W+8:0] output_bundle={m_numerator,m_denominator,m_index,m_keep,m_last,m_errors,m_area,m_tag};
    reg signed [511:0] num_w,expected_num_w,den_w,expected_den_w,ratio_a,ratio_b;
    `include "instruction_bounds.vh"
    reg [511:0] mag_a,mag_b,full_product,partial,shift_reference;
    integer old_state,old_raw,old_pc,old_addr,old_slot,old_accept;
    reg signed [WW-1:0] old_result;
    task load_case;
        input integer s;
        integer u,p,q,x,y,bit_in,sof_in,eol_in,bad_in,idx,keep_in,last_in,err_in,area_in;
        reg [31:0] tag_in;
        reg signed [255:0] num_in;
        reg [255:0] den_in,contract_in;
        reg [127:0] vx,vy;
        begin
            rc=$fscanf(fd,"%d %d %d %d %d %d %d",u,p,err_in,area_in,tag_in,q,idx);
            if(rc!=7 || u<0 || u>N || p<0 || p>7)$fatal(1,"bad case header");
            nt[s]=u;no[s]=p;errs[s]=err_in;areas[s]=area_in;tags[s]=tag_in;is_complete[s]=q;first_latency[s]=idx;
            for(u=0;u<10;u=u+1)raw_expect[s][u]=0;
            for(u=0;u<nt[s];u=u+1)begin
                rc=$fscanf(fd,"%d %d %d %d %d",bit_in,sof_in,eol_in,bad_in,tag_in);
                if(rc!=5)$fatal(1,"bad raster token");
                td[s][u]=bit_in;ts[s][u]=sof_in;te[s][u]=eol_in;tb[s][u]=bad_in;tt[s][u]=tag_in;
                if(bit_in)begin
                    x=u%WIDTH;y=u/WIDTH;vx=x;vy=y;
                    raw_expect[s][0]=raw_expect[s][0]+1;
                    raw_expect[s][1]=raw_expect[s][1]+vx;raw_expect[s][2]=raw_expect[s][2]+vy;
                    raw_expect[s][3]=raw_expect[s][3]+vx*vx;raw_expect[s][4]=raw_expect[s][4]+vx*vy;raw_expect[s][5]=raw_expect[s][5]+vy*vy;
                    raw_expect[s][6]=raw_expect[s][6]+vx*vx*vx;raw_expect[s][7]=raw_expect[s][7]+vx*vx*vy;
                    raw_expect[s][8]=raw_expect[s][8]+vx*vy*vy;raw_expect[s][9]=raw_expect[s][9]+vy*vy*vy;
                end
            end
            for(u=0;u<no[s];u=u+1)begin
                rc=$fscanf(fd,"%d %d %d %d %d %d %d %d %d",num_in,den_in,contract_in,idx,keep_in,last_in,err_in,tag_in,area_in);
                if(rc!=9)$fatal(1,"bad Fraction output");
                en[s][u]=num_in;ed[s][u]=den_in;cd[s][u]=contract_in;
                ei[s][u]=idx;ek[s][u]=keep_in;el[s][u]=last_in;ee[s][u]=err_in;et[s][u]=tag_in;ea[s][u]=area_in;
            end
        end
    endtask
    function actual_next;
        begin actual_next=(drive_slot==1 && active_slot==0 && s_valid && !s_ready &&
            s_pixel===td[1][0][0] && s_sof===ts[1][0][0] && s_eol===te[1][0][0] &&
            s_bad===tb[1][0][0] && s_tag===tt[1][0]);end
    endfunction
    function hit;
        input integer id;
        begin
            hit=0;
            if(id<=14)hit=dut.state==id;
            else if(id>=27 && id<=33)hit=(dut.state==13 && dut.out_index==id-27 && retired[0]==id-27 && !m_ready);
            else case(id)
                15:hit=(dut.state==0 && accepted[0]==1 && dut.raw[0]==0);
                16:hit=(dut.state==0 && accepted[0]==1 && dut.raw[0]==1);
                17:hit=(dut.state==0 && accepted[0]==N/2);
                18:hit=(dut.state==0 && accepted[0]==N-1);
                19:hit=(dut.state==7 && dut.pc==0 && dut.mul_step==0);
                20:hit=(dut.state==7 && dut.pc==0 && dut.mul_step==WW/2);
                21:hit=(dut.state==7 && dut.pc==0 && dut.mul_step==WW-1);
                22:hit=(dut.state==7 && dut.pc==78 && dut.mul_step==WW/2);
                23:hit=(dut.state==1 && dut.raw_index==0);
                24:hit=(dut.state==1 && dut.raw_index==9);
                25:hit=(dut.state==2 && dut.pc==78);
                26:hit=(dut.state==9 && dut.pc==78);
                34:hit=(dut.state==2 && dut.pc==0 && actual_next());
                35:hit=(dut.state==13 && dut.out_index==0 && actual_next());
                36:hit=(dut.state==7 && dut.pc==78 && dut.mul_step==WW/2 && dut.mul_acc!=0);
                default:hit=0;
            endcase
        end
    endfunction
    task ready_now;
        reg freeze;
        begin
            freeze=reset_search && m_valid &&
                (target==13 || target==14 || target==35 ||
                 (target>=27 && target<=33 && m_index==target-27));
            m_ready=!rst && m_valid && hold_age>=2 && !freeze;
        end
    endtask
    task tick;begin ready_now;@(posedge clk);#2;@(negedge clk);end endtask
    task drive;
        input integer s,u;
        begin drive_slot=s;s_pixel=td[s][u];s_sof=ts[s][u];s_eol=te[s][u];s_bad=tb[s][u];s_tag=tt[s][u];s_valid=1;end
    endtask
    task send_case;
        input integer s;
        integer u,want;
        begin
            for(u=0;u<nt[s];u=u+1)begin
                if(u%5==2)begin s_valid=0;tick;end
                drive(s,u);want=accepted[s]+1;
                while(accepted[s]<want)tick;
            end
        end
    endtask
    always @(posedge clk)begin
        cycles=cycles+1;if(cycles>CYCLE_LIMIT)$fatal(1,"frozen watchdog target=%0d state=%0d pc=%0d",target,dut.state,dut.pc);
        old_state=dut.state;old_raw=dut.raw_index;old_pc=dut.pc;old_addr=dut.addr_d;old_result=dut.result;
        old_accept=s_valid&&s_ready;old_slot=active_slot;
        if(rst)begin
            if(s_ready || m_valid)$fatal(1,"reset gating");
            owned=0;held_s=0;held_m=0;hold_age=0;active_slot=-1;
            if(s_valid)reset_offers=reset_offers+1;
        end else begin
            state_mask=state_mask|(1<<dut.state);
            if(held_s && (!s_valid || source_bundle!==source_hold))$fatal(1,"source changed while blocked");
            if(held_m && (!m_valid || output_bundle!==output_hold))$fatal(1,"response changed while held");
            held_s=s_valid&&!s_ready;source_hold=source_bundle;
            held_m=m_valid&&!m_ready;output_hold=output_bundle;
            if(held_s)begin source_holds=source_holds+1;if(mode==0 && drive_slot>active_slot)blocked[drive_slot]=1;end
            if(held_m)begin output_holds=output_holds+1;hold_age=hold_age+1;end else hold_age=0;
            if(old_accept)begin
                if(dut.state!=0)$fatal(1,"accept while owner busy");
                if(dut.capture_count==0)begin
                    active_slot=drive_slot;owned=0;
                    if(mode==0 && drive_slot>0)begin
                        if(!completed[drive_slot-1] || !blocked[drive_slot])$fatal(1,"queued frame ownership");queued=queued+1;
                    end
                end
                z=accepted[drive_slot];if(z>=nt[drive_slot])$fatal(1,"extra input");
                if(source_bundle!=={td[drive_slot][z][0],ts[drive_slot][z][0],te[drive_slot][z][0],tb[drive_slot][z][0],tt[drive_slot][z]})$fatal(1,"raster token mismatch");
                accepted[drive_slot]=z+1;
                if(z==N-1)last_cycle[drive_slot]=cycles;
            end
            old_slot=active_slot;
            if(m_valid)begin
                if(active_slot<0 || retired[active_slot]>=no[active_slot] || s_ready)$fatal(1,"unexpected/stale response");
                z=retired[active_slot];
                num_w={{(512-WW){m_numerator[WW-1]}},m_numerator};
                den_w={{(512-WW){1'b0}},m_denominator};
                expected_num_w={{256{en[active_slot][z][255]}},en[active_slot][z]};
                expected_den_w={256'd0,ed[active_slot][z]};
                ratio_a=num_w*expected_den_w;ratio_b=expected_num_w*den_w;
                if(m_denominator==0 || ratio_a!==ratio_b || m_denominator!==cd[active_slot][z] ||
                   m_index!==ei[active_slot][z][2:0] || m_keep!==ek[active_slot][z][0] ||
                   m_last!==el[active_slot][z][0] || m_errors!==ee[active_slot][z][3:0] ||
                   m_tag!==et[active_slot][z] || m_area!==ea[active_slot][z][CW-1:0])
                    $fatal(1,"exact Fraction/metadata mismatch slot=%0d index=%0d",active_slot,z);
                if(m_ready)begin
                    retired[active_slot]=z+1;outputs=outputs+1;
                    if(m_last)begin completed[active_slot]=1;frames=frames+1;end
                end
            end
            if(active_slot>=0)case(dut.state)
                1:begin
                    if(dut.raw[dut.raw_index]!==raw_expect[active_slot][dut.raw_index])$fatal(1,"direct-coordinate raw moment");
                    owned[dut.raw_index]=1;bank=bank+1;raw_checks=raw_checks+1;
                end
                2:begin if(!owned[dut.addr_a])$fatal(1,"A scratch ownership");bank=bank+1;end
                3:begin if(!owned[dut.addr_b])$fatal(1,"B scratch ownership");bank=bank+1;end
                4:if(dut.op!=2)begin
                    num_w={{(512-WW){dut.operand_a[WW-1]}},dut.operand_a};
                    den_w={{(512-WW){dut.shifted_b[WW-1]}},dut.shifted_b};
                    expected_num_w=(dut.op==1)?num_w-den_w:num_w+den_w;
                    ratio_a={{(512-WW){dut.alu_result[WW-1]}},dut.alu_result};
                    if(ratio_a!==expected_num_w ||
                       (expected_num_w<0?-expected_num_w:expected_num_w)>instruction_bound(dut.pc))$fatal(1,"signed instruction prefix/bound");
                    alu=alu+1;
                end
                5:begin
                    num_w={{(512-WW){dut.operand_a[WW-1]}},dut.operand_a};mag_a=num_w<0?-num_w:num_w;
                    if($unsigned(dut.alu_result)!==mag_a)$fatal(1,"A magnitude");alu=alu+1;
                end
                6:begin
                    num_w={{(512-WW){dut.operand_b[WW-1]}},dut.operand_b};mag_b=num_w<0?-num_w:num_w;
                    full_product=mag_a*mag_b;
                    if(full_product>=(512'd1<<(WW-1)))$fatal(1,"full product exceeds signed work range");
                    if(full_product>instruction_bound(dut.pc) || $unsigned(dut.alu_result)!==mag_b)$fatal(1,"B magnitude/product bound");
                    alu=alu+1;
                end
                7:begin
                    partial=mag_a*(mag_b&((512'd1<<dut.mul_step)-1));
                    shift_reference=mag_a<<dut.mul_step;
                    if($unsigned(dut.mul_acc)!==partial || $unsigned(dut.mul_factor)!==(mag_b>>dut.mul_step))$fatal(1,"multiply partial/factor invariant");
                    if(dut.mul_factor!=0 && $unsigned(dut.mul_shift)!==shift_reference)$fatal(1,"significant shift truncation");
                    if($unsigned(dut.mul_shift)>=(512'd1<<(WW-1)) || $unsigned(dut.alu_result)>full_product)$fatal(1,"magnitude bound");
                    mul=mul+1;
                end
                8:begin
                    if($unsigned(dut.mul_acc)!==full_product)$fatal(1,"completed magnitude");
                    expected_num_w=dut.mul_negative?-$signed(full_product):$signed(full_product);
                    ratio_a={{(512-WW){dut.alu_result[WW-1]}},dut.alu_result};
                    if(ratio_a!==expected_num_w)$fatal(1,"restore sign");alu=alu+1;
                end
                9:begin
                    num_w={{(512-WW){dut.result[WW-1]}},dut.result};
                    if((num_w<0?-num_w:num_w)>refined_bound(dut.pc))$fatal(1,"refined central/output bound");
                    owned[dut.addr_d]=1;bank=bank+1;
                end
                10:begin if(!owned[dut.out_num_addr])$fatal(1,"numerator scratch ownership");bank=bank+1;end
                11:begin if(!owned[dut.out_den_addr])$fatal(1,"denominator scratch ownership");bank=bank+1;end
                default:begin end
            endcase
        end
        #1;
        if(rst)begin if(s_ready || m_valid || dut.state!==0 || dut.capture_count!==0)$fatal(1,"reset edge");end
        else begin
            if(old_slot>=0 && old_state==1 && dut.scratch[old_raw]!==raw_expect[old_slot][old_raw])$fatal(1,"raw scratch payload");
            if(old_slot>=0 && old_state==9 && dut.scratch[old_addr]!==old_result)$fatal(1,"instruction scratch payload");
            if(m_valid && active_slot>=0 && !seen[active_slot])begin
                if(cycles-last_cycle[active_slot]!=first_latency[active_slot])$fatal(1,"fixed first valid latency actual=%0d expected=%0d",cycles-last_cycle[active_slot],first_latency[active_slot]);
                seen[active_slot]=1;latency=latency+1;
            end
        end
    end
    initial begin
        for(k=0;k<4;k=k+1)begin accepted[k]=0;retired[k]=0;completed[k]=0;last_cycle[k]=-1;seen[k]=0;blocked[k]=0;end
        if(!$value$plusargs("INPUT=%s",input_path))$fatal(1,"missing frozen input");
        fd=$fopen(input_path,"r");if(!fd)$fatal(1,"cannot open input");
        rc=$fscanf(fd,"%d %d",mode,entries);if(rc!=2)$fatal(1,"bad fixture header");
        if(mode==0)begin if(entries<1 || entries>4)$fatal(1,"group size");for(slot=0;slot<entries;slot=slot+1)load_case(slot);end
        else begin target=entries;load_case(0);load_case(1);end
        tail_byte=$fgetc(fd);
        while(tail_byte!=-1)begin
            if(tail_byte!=32 && tail_byte!=9 && tail_byte!=13 && tail_byte!=10)$fatal(1,"non-whitespace fixture tail");tail_byte=$fgetc(fd);
        end
        $fclose(fd);
        @(negedge clk);repeat(3)tick;rst=0;
        if(mode==0)begin
            for(slot=0;slot<entries;slot=slot+1)send_case(slot);s_valid=0;
            while(!completed[entries-1])tick;
            for(slot=0;slot<entries;slot=slot+1)if(accepted[slot]!=nt[slot] || retired[slot]!=no[slot])$fatal(1,"incomplete main frame");
        end else begin
            reset_search=1;send_case(0);s_valid=0;
            if(target==34 || target==35)drive(1,0);
            ready_now;while(!hit(target))tick;
            if(target>=27 && target<=33)begin if(retired[0]!=target-27)$fatal(1,"retired prefix");end
            else if(retired[0]!=0)$fatal(1,"unexpected retired owner output");
            if(target==34 || target==35)begin if(!actual_next())$fatal(1,"actual next missing");next_seen=1;end
            $display("OBS target=%0d state=%0d pc=%0d step=%0d raw=%0d index=%0d count=%0d mass=%0d errors=%0d prefix=%0d next=%0d accepted=%0d owned=%h acc=%0d",target,dut.state,dut.pc,dut.mul_step,dut.raw_index,dut.out_index,dut.capture_count,dut.raw[0],dut.errors,retired[0],next_seen,accepted[0],owned,dut.mul_acc);
            goal=accepted[0]+accepted[1];z=outputs;rst=1;
            if(target!=34 && target!=35)begin s_pixel=1;s_sof=1;s_eol=1;s_bad=1;s_tag=0;s_valid=1;end
            #1;if(s_ready || m_valid)$fatal(1,"immediate reset gate");
            repeat(3)tick;
            if(accepted[0]+accepted[1]!=goal || outputs!=z)$fatal(1,"reset-high acceptance");
            resets=1;rst=0;reset_search=0;send_case(1);s_valid=0;
            while(!completed[1])tick;
            if(accepted[1]!=N || retired[1]!=7)$fatal(1,"complete fresh seven");
        end
        repeat(5)begin tick;if(m_valid)$fatal(1,"late duplicate");end
        $display("PASS mode=%0d W=%0d H=%0d T=%0d frames=%0d outputs=%0d queued=%0d resets=%0d fresh=%0d prefix=%0d next=%0d reset_offers=%0d latency=%0d bank=%0d alu=%0d mul=%0d raw_checks=%0d source_holds=%0d output_holds=%0d states=%h cycles=%0d",mode,WIDTH,HEIGHT,TAG_W,(mode==0)?frames:completed[1],(mode==0)?outputs:retired[1],queued,resets,(mode==0)?0:completed[1],(mode==0)?0:retired[0],next_seen,(mode==0)?0:reset_offers,latency,bank,alu,mul,raw_checks,source_holds,output_holds,state_mask,cycles);
        $finish;
    end
endmodule
`default_nettype wire
