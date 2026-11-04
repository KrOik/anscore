`timescale 1ns/1ps
module tb_point_delaunay;
    parameter integer C=8,N=8,T=8,NUM_INPUTS=1000,NUM_OUTPUTS=1000,CYCLE_LIMIT=1000000,TAIL_BOUND=11316;
    localparam IW=(N<2)?1:$clog2(N),CW=(N<2)?1:$clog2(N+1),TM=(2*N-5<1)?1:2*N-5,TCW=(TM<2)?1:$clog2(TM+1);
    localparam OW=3*IW+6*C+2*CW+2*TCW+3+2+3+T;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,s_valid=0,s_keep=0,s_last=0,s_error=0,m_ready=0;
    reg signed [C-1:0] s_x=0,s_y=0;reg[T-1:0]s_tag=0;
    wire s_ready,m_valid,m_has_triangle,m_first,m_last;
    wire[IW-1:0]m_id0,m_id1,m_id2;wire signed[C-1:0]m_x0,m_y0,m_x1,m_y1,m_x2,m_y2;
    wire[CW-1:0]m_points,m_unique;wire[TCW-1:0]m_count,m_index;wire[2:0]m_error;wire[1:0]m_dimension;wire[T-1:0]m_tag;
    point_delaunay #(.COORD_W(C),.MAX_POINTS(N),.TAG_W(T)) dut(.*);
    wire[OW-1:0]out_word={m_id0,m_id1,m_id2,m_x0,m_y0,m_x1,m_y1,m_x2,m_y2,m_points,m_unique,m_count,m_index,m_error,m_dimension,m_has_triangle,m_first,m_last,m_tag};
    wire[2*C+T+2:0]in_word={s_x,s_y,s_keep,s_last,s_error,s_tag};
    longint signed ins[0:NUM_INPUTS-1][0:5],gold[0:NUM_OUTPUTS-1][0:18];
    integer main_first[0:NUM_INPUTS-1];
    integer ids[0:58],os[0:58],oe[0:58],fs[0:58],fe[0:58],gs[0:58],ge[0:58];
    integer ni=0,no=0,main_input_end,main_output_end,main_frames,reset_number;
    integer fd,rd,r,a,b,q,z,target,src,src_end,exp_pos,exp_end,fallback,phase;
    integer cycles=0,frames=0,fresh_count=0,resets=0,queued=0,starts=0,out_age=0;
    integer source_holds=0,output_holds=0,bank_reads=0,multiplies=0,orientations=0,incircles=0,latency_checks=0,max_latency=0;
    integer prior_retire=-100,last_accept=0,latency;
    reg waiting_first=0,source_block=0,output_block=0;
    reg[2*C+T+2:0]prior_input;reg[OW-1:0]prior_output;
    reg[N-1:0]point_valid=0;reg[TM-1:0]tri_valid=0;
    reg signed[C-1:0]shadow_x[0:N-1],shadow_y[0:N-1],want_x,want_y,before_x,before_y;
    reg[3*IW-1:0]shadow_tri[0:TM-1],want_tri,before_tri;
    reg do_read,do_tri,do_mul;
    reg signed[127:0]want_product;
    reg[26:0]state_mask=0;reg[14:0]job_mask=0;reg[58:0]reset_mask=0;
    reg[4:0]circle_mask=0;reg negative_turn=0,zero_turn=0;
    longint signed ux,uy,vx,vy,wx,wy,bc,ca,ab,det,turn;
    string fixture,reset_file;

    function automatic longint signed field(input integer index);
        case(index)
            0:field=m_id0;1:field=m_id1;2:field=m_id2;
            3:field=$signed(m_x0);4:field=$signed(m_y0);5:field=$signed(m_x1);
            6:field=$signed(m_y1);7:field=$signed(m_x2);8:field=$signed(m_y2);
            9:field=m_points;10:field=m_unique;11:field=m_count;12:field=m_index;
            13:field=m_error;14:field=m_dimension;15:field=m_has_triangle;
            16:field=m_first;17:field=m_last;18:field=m_tag;default:field=-999;
        endcase
    endfunction
    function automatic integer signum(input longint signed value);
        signum=(value>0)?1:((value<0)?-1:0);
    endfunction
    function automatic integer hit(input integer id);
        if(id<27)hit=(dut.state==id && (id!=0 || dut.seen));
        else if(id<42)hit=(dut.state==26 && dut.math_mode && dut.math_job==id-27);
        else if(id<44)hit=(dut.state==26 && !dut.math_mode && dut.math_job==id-42);
        else case(id)
            44:hit=(dut.state==13 && dut.incircle_q!=0 && ((dut.incircle_q>0)==(dut.orientation_sign>0)));
            45:hit=(dut.state==13 && dut.incircle_q!=0 && ((dut.incircle_q>0)!=(dut.orientation_sign>0)));
            46:hit=(dut.state==13 && dut.incircle_q==0 && dut.p<dut.i);
            47:hit=(dut.state==13 && dut.incircle_q==0 && dut.p>dut.i && ((dut.bc_sign>0)==(dut.orientation_sign>0)));
            48:hit=(dut.state==13 && dut.incircle_q==0 && dut.p>dut.i && ((dut.bc_sign>0)!=(dut.orientation_sign>0)));
            49:hit=(dut.state==10 && dut.orientation_sign<0);
            50:hit=(dut.state==10 && dut.orientation_sign==0);
            51:hit=((dut.state==2 || dut.state==3) && dut.unique_count<dut.point_count && dut.errors==0);
            52:hit=(dut.state==21 && out_age>=3 && m_unique==0 && m_error==0);
            53:hit=(dut.state==21 && out_age>=3 && m_unique==1 && m_error==0);
            54:hit=(dut.state==21 && out_age>=3 && m_dimension==1 && m_error==0);
            55:hit=(dut.state==21 && out_age>=3 && m_error==2);
            56:hit=(dut.state==21 && out_age>=3 && m_error==1);
            57:hit=(dut.state==21 && out_age>=3 && m_error==3);
            58:hit=(dut.state==21 && out_age>=3 && m_has_triangle);
            default:hit=0;
        endcase
    endfunction
    task automatic read_inputs(input integer fileid,input integer count);
        integer h;
        begin
            for(h=0;h<count;h=h+1)begin
                if(ni>=NUM_INPUTS)$fatal(1,"input allocation");
                r=$fscanf(fileid,"%d %d %d %d %d %d",ins[ni][0],ins[ni][1],ins[ni][2],ins[ni][3],ins[ni][4],ins[ni][5]);
                if(r!=6)$fatal(1,"input fixture parse");main_first[ni]=0;ni=ni+1;
            end
        end
    endtask
    task automatic read_outputs(input integer fileid,input integer count);
        integer h,f;
        begin
            for(h=0;h<count;h=h+1)begin
                if(no>=NUM_OUTPUTS)$fatal(1,"output allocation");
                for(f=0;f<19;f=f+1)begin r=$fscanf(fileid,"%d",gold[no][f]);if(r!=1)$fatal(1,"gold parse");end
                no=no+1;
            end
        end
    endtask
    task automatic step;
        integer pos,f;
        begin
            @(negedge clk);
            if(rst)begin s_valid=0;m_ready=0;end
            else begin
                pos=(src<src_end)?src:fallback;
                s_valid=(pos>=0);
                if(pos>=0)begin
                    s_x=ins[pos][0];s_y=ins[pos][1];s_keep=ins[pos][2];
                    s_last=ins[pos][3];s_error=ins[pos][4];s_tag=ins[pos][5];
                end
                m_ready=(phase!=1 && out_age>=3);
            end
            @(posedge clk);
            cycles=cycles+1;
            if(cycles>CYCLE_LIMIT)$fatal(1,"frozen cycle budget exceeded");
            do_read=0;do_tri=0;do_mul=0;
            before_x=dut.x_q;before_y=dut.y_q;before_tri=dut.triangle_q;
            if(rst)begin
                point_valid=0;tri_valid=0;source_block=0;output_block=0;out_age=0;waiting_first=0;
            end else begin
                state_mask[dut.state]=1;
                if(source_block)begin
                    if(!s_valid || in_word!==prior_input)$fatal(1,"whole source token changed while blocked");
                    source_holds=source_holds+1;
                end
                if(output_block)begin
                    if(!m_valid || out_word!==prior_output)$fatal(1,"whole output record changed while held");
                    output_holds=output_holds+1;
                end
                source_block=s_valid && !s_ready;prior_input=in_word;
                output_block=m_valid && !m_ready;prior_output=out_word;
                if(s_valid && s_ready)begin
                    if(src>=src_end)$fatal(1,"queued next token accepted before owner cancellation");
                    if(!dut.seen)begin point_valid=0;tri_valid=0;end
                    if(s_keep && dut.point_count<N)begin
                        shadow_x[dut.point_count]=s_x;shadow_y[dut.point_count]=s_y;point_valid[dut.point_count]=1;
                    end
                    if(phase==0 && main_first[src])begin
                        if(starts>0)begin
                            if(cycles!=prior_retire+1)$fatal(1,"actual queued acceptance edge");queued=queued+1;
                        end
                        starts=starts+1;
                    end
                    if(s_last)begin last_accept=cycles;waiting_first=1;end
                    src=src+1;
                end
                if(m_valid)begin
                    if(phase!=1)begin
                        if(exp_pos>=exp_end)$fatal(1,"unexpected output");
                        for(f=0;f<19;f=f+1)if(field(f)!==gold[exp_pos][f])
                            $fatal(1,"gold mismatch phase=%0d record=%0d field=%0d got=%0d want=%0d",phase,exp_pos,f,field(f),gold[exp_pos][f]);
                    end
                    if(m_ready)begin
                        if(out_age<3)$fatal(1,"missing three full output stalls");
                        if(phase==1)$fatal(1,"owner retired before reset");
                        exp_pos=exp_pos+1;out_age=0;
                        if(m_last)begin
                            if(phase==0)begin frames=frames+1;prior_retire=cycles;end
                            else fresh_count=fresh_count+1;
                        end
                    end else out_age=out_age+1;
                end else out_age=0;
                if(dut.state==23)begin
                    if(dut.load_id>=dut.point_count || !point_valid[dut.load_id])$fatal(1,"point read outside current owned prefix");
                    do_read=1;want_x=shadow_x[dut.load_id];want_y=shadow_y[dut.load_id];bank_reads=bank_reads+2;
                end
                if(dut.state==14 && dut.triangle_count<TM)begin
                    shadow_tri[dut.triangle_count]=(dut.orientation_sign>0)?{dut.i,dut.j,dut.k}:{dut.i,dut.k,dut.j};
                    tri_valid[dut.triangle_count]=1;
                end
                if(dut.state==16)begin
                    if(dut.out_index>=dut.triangle_count || !tri_valid[dut.out_index])$fatal(1,"triangle read ownership");
                    do_tri=1;want_tri=shadow_tri[dut.out_index];bank_reads=bank_reads+1;
                end
                if(dut.state==25)begin
                    do_mul=1;want_product=$signed(dut.mul_a)*$signed(dut.mul_b);multiplies=multiplies+1;
                    if(dut.math_mode)job_mask[dut.math_job]=1;
                end
                if(dut.state==10)begin
                    ux=$signed(dut.bx);ux=ux-$signed(dut.ax);uy=$signed(dut.by);uy=uy-$signed(dut.ay);
                    vx=$signed(dut.cx);vx=vx-$signed(dut.ax);vy=$signed(dut.cy);vy=vy-$signed(dut.ay);
                    turn=ux*vy-uy*vx;
                    if($signed(dut.orientation_sign)!=signum(turn))$fatal(1,"exact orientation");
                    orientations=orientations+1;if(turn<0)negative_turn=1;if(turn==0)zero_turn=1;
                end
                if(dut.state==13)begin
                    ux=$signed(dut.ax);ux=ux-$signed(dut.px);uy=$signed(dut.ay);uy=uy-$signed(dut.py);
                    vx=$signed(dut.bx);vx=vx-$signed(dut.px);vy=$signed(dut.by);vy=vy-$signed(dut.py);
                    wx=$signed(dut.cx);wx=wx-$signed(dut.px);wy=$signed(dut.cy);wy=wy-$signed(dut.py);
                    bc=vx*wy-vy*wx;ca=wx*uy-wy*ux;ab=ux*vy-uy*vx;
                    det=(ux*ux+uy*uy)*bc+(vx*vx+vy*vy)*ca+(wx*wx+wy*wy)*ab;
                    if($signed(dut.incircle_q)!=det || $signed(dut.bc_sign)!=signum(bc))$fatal(1,"exact full incircle");
                    incircles=incircles+1;
                    if(det!=0)begin if((det>0)==(dut.orientation_sign>0))circle_mask[0]=1;else circle_mask[1]=1;end
                    else if(dut.p<dut.i)circle_mask[2]=1;
                    else if((bc>0)==(dut.orientation_sign>0))circle_mask[3]=1;else circle_mask[4]=1;
                end
            end
            #1;
            if(do_read)begin if(dut.x_q!==want_x || dut.y_q!==want_y)$fatal(1,"clocked x/y read mismatch");end
            else if(dut.x_q!==before_x || dut.y_q!==before_y)$fatal(1,"x/y q changed outside clocked read");
            if(do_tri)begin if(dut.triangle_q!==want_tri)$fatal(1,"clocked triangle read mismatch");end
            else if(dut.triangle_q!==before_tri)$fatal(1,"triangle q changed outside read");
            if(do_mul && $signed(dut.product_q)!==want_product)$fatal(1,"shared exact product");
            if(rst)begin
                if(s_ready || m_valid || m_first || m_last || m_has_triangle || dut.state!=0)$fatal(1,"reset gate/state");
            end else begin
                state_mask[dut.state]=1;
                if(m_valid && waiting_first)begin
                    latency=cycles-last_accept;if(latency>TAIL_BOUND)$fatal(1,"paper latency bound");
                    if(phase!=1)begin latency_checks=latency_checks+1;if(latency>max_latency)max_latency=latency;end
                    waiting_first=0;
                end
            end
            #1;
        end
    endtask
    initial begin
        if(!$value$plusargs("FIXTURE=%s",fixture) || !$value$plusargs("RESETS=%s",reset_file))$fatal(1,"fixture args");
        fd=$fopen(fixture,"r");if(!fd)$fatal(1,"fixture open");r=$fscanf(fd,"%d",main_frames);
        for(q=0;q<main_frames;q=q+1)begin
            r=$fscanf(fd,"%d %d",a,b);z=ni;read_inputs(fd,a);main_first[z]=1;read_outputs(fd,b);
        end
        $fclose(fd);main_input_end=ni;main_output_end=no;
        rd=$fopen(reset_file,"r");if(!rd)$fatal(1,"reset open");r=$fscanf(rd,"%d",reset_number);
        for(q=0;q<reset_number;q=q+1)begin
            r=$fscanf(rd,"%d %d %d %d",ids[q],a,b,z);
            os[q]=ni;read_inputs(rd,a);oe[q]=ni;fs[q]=ni;read_inputs(rd,b);fe[q]=ni;
            gs[q]=no;read_outputs(rd,z);ge[q]=no;
        end
        $fclose(rd);if(ni!=NUM_INPUTS || no!=NUM_OUTPUTS)$fatal(1,"exact frozen allocations");
        phase=0;src=0;src_end=main_input_end;exp_pos=0;exp_end=main_output_end;fallback=-1;
        step();rst=0;
        while(exp_pos<exp_end)step();
        if(src!=src_end || frames!=main_frames || queued!=((main_frames>0)?main_frames-1:0))$fatal(1,"main completion");
        for(q=0;q<reset_number;q=q+1)begin
            phase=1;src=os[q];src_end=oe[q];fallback=fs[q];out_age=0;
            step();while(!hit(ids[q]))step();
            $display("OBS id=%0d state=%0d mode=%0d job=%0d slot=%0d index=%0d cycle=%0d",ids[q],dut.state,dut.math_mode,dut.math_job,dut.load_slot,dut.out_index,cycles);
            reset_mask[ids[q]]=1;resets=resets+1;
            rst=1;
            #1;if(s_ready || m_valid || m_first || m_last || m_has_triangle)$fatal(1,"immediate reset gate");
            step();rst=0;
            phase=2;src=fs[q];src_end=fe[q];exp_pos=gs[q];exp_end=ge[q];fallback=-1;
            while(exp_pos<exp_end)step();
            if(src!=src_end)$fatal(1,"fresh incomplete input");
        end
        if(fresh_count!=reset_number || resets!=reset_number || latency_checks!=main_frames+reset_number)$fatal(1,"recovery/latency completion");
        $display("PASS C=%0d N=%0d T=%0d frames=%0d queued=%0d resets=%0d fresh=%0d records=%0d source_holds=%0d output_holds=%0d reads=%0d multiplies=%0d orientations=%0d incircles=%0d latencies=%0d max_latency=%0d states=%h jobs=%h circles=%h negative=%0d zero=%0d resetmask=%h cycles=%0d",C,N,T,frames,queued,resets,fresh_count,NUM_OUTPUTS,source_holds,output_holds,bank_reads,multiplies,orientations,incircles,latency_checks,max_latency,state_mask,job_mask,circle_mask,negative_turn,zero_turn,reset_mask,cycles);
        $finish;
    end
endmodule
