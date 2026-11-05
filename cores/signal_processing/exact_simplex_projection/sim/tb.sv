// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb;
    parameter integer N=16, DATA_W=16, TAG_W=8;
    localparam integer L=(N>1)?$clog2(N):0;
    localparam integer IW=(N>1)?$clog2(N):1;
    localparam integer CW=(N>1)?$clog2(N+1):1;
    localparam integer UW=DATA_W+L, AW=DATA_W+L+2, PW=DATA_W+CW+1;
    localparam integer PAY_W=N+3*CW+2*AW+PW+2*DATA_W+TAG_W+UW;
    localparam integer BOUND=1+N*(3*N+1)+4*N;
    reg clk=0; always #5 clk=~clk;
    reg rst=1, s_valid=0, m_ready=0;
    reg signed [DATA_W-1:0] s_data=0;
    reg [DATA_W-1:0] s_mass=0;
    reg [TAG_W-1:0] s_tag=0;
    wire s_ready,m_valid,m_last;
    wire [UW-1:0] m_numerator;
    wire [CW-1:0] m_denominator;
    wire [IW-1:0] m_index;
    wire [TAG_W-1:0] m_tag;
    exact_simplex_projection #(.N(N),.DATA_W(DATA_W),.TAG_W(TAG_W)) dut(.*);

    integer mode,fd,ncommands,hn,hw,ht,rc,j,b,ch,cycle=0;
    reg [2047:0] filename;
    reg signed [31:0] cx[0:127]; reg [63:0] cn[0:127];
    reg [63:0] cm[0:1],ct[0:1]; integer cd[0:1];
    reg signed [63:0] scan_x; reg [63:0] scan_num,scan_mass,scan_tag;
    integer scan_den;
    integer src_slot=0,src_id=0,src_phase=0,owner_slot=0,owner_id=0,owner_phase=0;
    integer frame_begins=0,samples=0,completed=0,canceled=0,outputs=0,prefix_outputs=0,fresh_outputs=0;
    integer source_holds=0,output_holds=0,input_gaps=0,reset_offers=0,resets=0,next_offers=0;
    integer load_count=0,part=0,last_input_cycle=0,frame_stalls=0,hold_wait=0;
    integer target_id,next_offer,target_mask,target_state,target_index,target_prefix,target_k,target_round,target_kept;
    reg signed [63:0] target_acc,target_threshold,target_read,target_product;
    reg [63:0] target_active;
    reg pending=0,loaded=0,started=0,owner_mode=0,in_blocked=0,out_blocked=0;
    reg [2*DATA_W+TAG_W-1:0] held_in;
    reg [UW+CW+IW+TAG_W:0] held_out;
    wire [2*DATA_W+TAG_W-1:0] packed_in={s_data,s_mass,s_tag};
    wire [UW+CW+IW+TAG_W:0] packed_out={m_numerator,m_denominator,m_index,m_last,m_tag};
    wire [PAY_W-1:0] payload={dut.active,dut.active_k,dut.kept_count,dut.round_count,
        dut.sum_reg,dut.threshold,dut.product_reg,dut.read_data,dut.mass,dut.frame_tag,dut.numerator};
    reg [PAY_W-1:0] saved_payload;

    task tick; begin @(negedge clk); #2; end endtask
    task read_command(input integer slot);
        integer a;
        begin
            rc=$fscanf(fd,"%h %h %d",scan_mass,scan_tag,scan_den);
            if(rc!=3 || scan_den<1 || scan_den>N) $fatal(1,"command header");
            cm[slot]=scan_mass;ct[slot]=scan_tag;cd[slot]=scan_den;
            for(a=0;a<N;a=a+1)begin
                rc=$fscanf(fd,"%d %h",scan_x,scan_num);
                if(rc!=2)$fatal(1,"command data");
                cx[slot*64+a]=scan_x;cn[slot*64+a]=scan_num;
            end
        end
    endtask
    task set_source(input integer slot,id,phase,element);
        begin
            src_slot=slot;src_id=id;src_phase=phase;
            s_data=cx[slot*64+element][DATA_W-1:0];
            // Only first-beat metadata is contractual; later beats intentionally disagree.
            s_mass=(element==0)?cm[slot][DATA_W-1:0]:~cm[slot][DATA_W-1:0];
            s_tag=(element==0)?ct[slot][TAG_W-1:0]:~ct[slot][TAG_W-1:0];
            s_valid=1;
        end
    endtask
    task send_elements(input integer slot,id,phase,first,count);
        integer a,before_samples;
        begin
            for(a=first;a<count;a=a+1)begin
                tick();
                if(a%3==1)begin s_valid=0;input_gaps=input_gaps+1;tick();end
                before_samples=samples;set_source(slot,id,phase,a);
                while(samples==before_samples)tick();
                s_valid=0;
            end
        end
    endtask
    task check_output;
        begin
            if(!pending || !loaded || part>=N)$fatal(1,"unowned output");
            if(m_numerator!==cn[owner_slot*64+part][UW-1:0] ||
               m_denominator!==cd[owner_slot][CW-1:0] || m_index!==part[IW-1:0] ||
               m_last!==(part==N-1) || m_tag!==ct[owner_slot][TAG_W-1:0])
                $fatal(1,"projection mismatch id=%0d phase=%0d part=%0d got=%h/%0d",owner_id,owner_phase,part,m_numerator,m_denominator);
        end
    endtask
    function predicate;
        begin
            predicate=pending && owner_phase==1 && part==target_prefix &&
                dut.state===target_state[3:0] && dut.index===target_index[IW-1:0] &&
                dut.mass===cm[0][DATA_W-1:0] && dut.frame_tag===ct[0][TAG_W-1:0];
            if(target_mask&1)predicate=predicate && dut.active_k===target_k[CW-1:0] &&
                dut.round_count===target_round[CW-1:0] && dut.kept_count===target_kept[CW-1:0] &&
                dut.sum_reg===target_acc[AW-1:0] && dut.threshold===target_threshold[AW-1:0] &&
                dut.active===target_active[N-1:0];
            if(target_mask&2)predicate=predicate && dut.read_data===target_read[DATA_W-1:0];
            if(target_mask&4)predicate=predicate && dut.product_reg===target_product[PW-1:0];
            if(target_mask&16)predicate=predicate && dut.sum_reg===target_acc[AW-1:0];
        end
    endfunction

    always @(negedge clk)begin
        if(rst || owner_mode && (!pending || part>=target_prefix))begin m_ready=0;hold_wait=0;end
        else if(mode==0)m_ready=1;
        else if(!m_valid)begin m_ready=0;hold_wait=0;end
        else if(hold_wait<3)begin m_ready=0;hold_wait=hold_wait+1;end
        else m_ready=1;
    end
    always @(posedge clk)begin
        cycle=cycle+1;
        if(cycle>5000000)$fatal(1,"fixed cycle watchdog");
        if(rst)begin
            if(s_ready || m_valid)$fatal(1,"reset handshake mask");
            if(started && s_valid)reset_offers=reset_offers+1;
            if(pending)begin canceled=canceled+1;pending=0;end
            load_count=0;loaded=0;part=0;in_blocked=0;out_blocked=0;
        end else begin
            if(in_blocked && (!s_valid || packed_in!==held_in))$fatal(1,"source hold");
            if(out_blocked && (!m_valid || packed_out!==held_out))$fatal(1,"output hold");
            in_blocked=s_valid&&!s_ready;held_in=packed_in;
            out_blocked=m_valid&&!m_ready;held_out=packed_out;
            if(in_blocked)source_holds=source_holds+1;
            if(out_blocked)begin output_holds=output_holds+1;frame_stalls=frame_stalls+1;end
            if(s_valid && s_ready)begin
                if(load_count==0)begin
                    if(pending)$fatal(1,"accepted next frame before retirement");
                    pending=1;loaded=0;owner_slot=src_slot;owner_id=src_id;owner_phase=src_phase;
                    frame_begins=frame_begins+1;part=0;frame_stalls=0;
                end else if(src_slot!=owner_slot || src_phase!=owner_phase || src_id!=owner_id)$fatal(1,"mixed input owner");
                if(loaded || dut.index!==load_count[IW-1:0] || s_data!==cx[owner_slot*64+load_count][DATA_W-1:0])$fatal(1,"input sample ownership");
                load_count=load_count+1;samples=samples+1;
                if(load_count==N)begin loaded=1;last_input_cycle=cycle;end
            end
            if(m_valid)check_output();
            if(m_valid && m_ready)begin
                $display("REC id=%0d phase=%0d index=%0d numerator=%h denominator=%0d tag=%h last=%0d",owner_id,owner_phase,part,m_numerator,m_denominator,m_tag,m_last);
                outputs=outputs+1;
                if(owner_phase==1)prefix_outputs=prefix_outputs+1;
                if(owner_phase==2)fresh_outputs=fresh_outputs+1;
                if(m_last)begin
                    if(cycle-last_input_cycle>BOUND+frame_stalls)$fatal(1,"always-ready architectural bound");
                    completed=completed+1;pending=0;load_count=0;loaded=0;
                    $display("FRAME id=%0d phase=%0d count=%0d",owner_id,owner_phase,N);
                end
                part=part+1;
            end
            if(pending && dut.state>=2 && dut.state<=9)begin
                if(dut.active_k==0 || dut.active_k>N || dut.round_count>N)$fatal(1,"positive count / finite pass bound");
            end
            if(pending && dut.state==5 && dut.kept_count==0)$fatal(1,"empty positive-mass survivor set");
        end
    end

    initial begin
        if(!$value$plusargs("MODE=%d",mode) || mode<0 || mode>2)$fatal(1,"MODE");
        if(!$value$plusargs("FILE=%s",filename))$fatal(1,"FILE");
        fd=$fopen(filename,"r");if(!fd)$fatal(1,"fixture open");
        rc=$fscanf(fd,"%d %d %d %d",ncommands,hn,hw,ht);
        if(rc!=4 || hn!=N || hw!=DATA_W || ht!=TAG_W || ncommands<1 || ncommands>32)$fatal(1,"fixture header");
        repeat(3)tick();rst=0;started=1;
        if(mode!=2)begin
            for(j=0;j<ncommands;j=j+1)begin
                read_command(j%2);send_elements(j%2,j,0,0,N);
            end
            while(completed<ncommands)tick();
            if(frame_begins!=ncommands || canceled!=0 || samples!=ncommands*N || outputs!=samples)$fatal(1,"main conservation");
        end else begin
            for(j=0;j<ncommands;j=j+1)begin
                rc=$fscanf(fd,"%d %d",target_id,next_offer);if(rc!=2)$fatal(1,"probe header");
                rc=$fscanf(fd,"%d %d %d %d %d %d %d",target_mask,target_state,target_index,target_prefix,target_k,target_round,target_kept);
                if(rc!=7)$fatal(1,"probe scalars");
                rc=$fscanf(fd,"%d %d %d %d %h",target_acc,target_threshold,target_read,target_product,target_active);
                if(rc!=5)$fatal(1,"probe arithmetic");
                read_command(0);read_command(1);owner_mode=1;
                send_elements(0,target_id,1,0,(target_id==0)?1:N);
                b=cycle;
                while(!predicate())begin
                    if(cycle-b>BOUND+4*N+30)$fatal(1,"fixed actual-state witness not reached id=%0d",target_id);
                    tick();
                end
                if(target_state==9)begin
                    if(next_offer)begin
                        set_source(1,target_id,2,0);
                        repeat(3)begin tick();if(!s_valid || s_ready || !m_valid || m_ready)$fatal(1,"actual next offer not held");end
                        next_offers=next_offers+1;
                    end else repeat(3)tick();
                    if(!predicate())$fatal(1,"held witness changed");
                end
                $display("PROBE id=%0d mask=%0d state=%0d index=%0d prefix=%0d k=%0d round=%0d kept=%0d acc=%0d threshold=%0d active=%h read=%0d product=%0d offer=%0d",target_id,target_mask,dut.state,dut.index,part,
                    (target_mask&1)?dut.active_k:0,(target_mask&1)?dut.round_count:0,(target_mask&1)?dut.kept_count:0,
                    ((target_mask&1)||(target_mask&16))?$signed(dut.sum_reg):0,
                    (target_mask&1)?$signed(dut.threshold):0,(target_mask&1)?dut.active:{N{1'b0}},
                    (target_mask&2)?$signed(dut.read_data):0,(target_mask&4)?$signed(dut.product_reg):0,next_offer);
                set_source(1,target_id,2,0);saved_payload=payload;rst=1;
                repeat(3)tick();
                if(payload!==saved_payload)$fatal(1,"reset changed arithmetic payload");
                b=samples;rst=0;owner_mode=0;
                while(samples==b)tick();
                s_valid=0;send_elements(1,target_id,2,1,N);
                while(completed<j+1)tick();
                resets=resets+1;
            end
            if(frame_begins!=2*ncommands || completed!=ncommands || canceled!=ncommands ||
               reset_offers!=3*ncommands || next_offers!=1)$fatal(1,"reset conservation");
        end
        ch=$fgetc(fd);
        while(ch!=-1)begin
            if(ch!=32 && ch!=9 && ch!=10 && ch!=13)$fatal(1,"trailing fixture byte");
            ch=$fgetc(fd);
        end
        $fclose(fd);repeat(2)tick();
        if(pending || m_valid)$fatal(1,"tail not empty");
        $display("PASS mode=%0d N=%0d DATA_W=%0d TAG_W=%0d frame_begins=%0d samples=%0d completed=%0d canceled=%0d outputs=%0d prefix=%0d fresh=%0d resets=%0d next=%0d reset_offers=%0d source_holds=%0d output_holds=%0d input_gaps=%0d",mode,N,DATA_W,TAG_W,frame_begins,samples,completed,canceled,outputs,prefix_outputs,fresh_outputs,resets,next_offers,reset_offers,source_holds,output_holds,input_gaps);
        $finish;
    end
endmodule
