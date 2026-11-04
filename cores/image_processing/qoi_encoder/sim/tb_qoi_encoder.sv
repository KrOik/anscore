`timescale 1ns/1ps
module tb_qoi_encoder;
    parameter integer W=8,H=8,C=4,T=8,NUM_BLOCKS=1,NUM_INPUTS=64,NUM_BYTES=342,CYCLE_LIMIT=100000;
    localparam integer N=W*H,P=8*C,BW=($clog2((C+1)*N+23)<1)?1:$clog2((C+1)*N+23);
    reg clk=0;always #5 clk=~clk;
    reg rst=1,s_valid=0,s_sof=0,s_eol=0,s_error=0,s_colorspace=0,m_ready=0,d_ready=0;
    reg [P-1:0] s_pixel=0;reg [T-1:0] s_tag=0;
    wire s_ready,m_valid,m_sof,m_last,d_valid,d_colorspace;
    wire [7:0] m_byte;wire [BW-1:0] m_index,d_bytes;wire [T-1:0] m_tag,d_tag;wire [2:0] d_errors;
    qoi_encoder #(.WIDTH(W),.HEIGHT(H),.CHANNELS(C),.TAG_W(T)) dut(.*);
    reg [P-1:0] pixels[0:NUM_INPUTS-1];
    reg isof[0:NUM_INPUTS-1],ieol[0:NUM_INPUTS-1],ierror[0:NUM_INPUTS-1],ics[0:NUM_INPUTS-1];
    reg [T-1:0] itag[0:NUM_INPUTS-1],btag[0:NUM_BLOCKS-1];
    reg [7:0] gold[0:NUM_BYTES-1];
    integer meta[0:NUM_BLOCKS-1][0:18],ib[0:NUM_BLOCKS],ob[0:NUM_BLOCKS];
    integer fd,r,b,j,k,ni=0,no=0;
    reg [63:0] value;
    string fixture;
    integer cycles=0,src=0,src_limit=0,out_block=0,phase=0;
    integer last_gapped=-1,byte_age=0,done_age=0,last_accept=0,last_summary=-100,last_byte=-100;
    integer frames=0,fresh=0,resets=0,queued=0,starts=0,latencies=0,bytes=0,ownerbytes=0;
    integer capturewrites=0,reads=0,hreads=0,hwrites=0,sourceholds=0,outputholds=0,max_tail=0;
    integer frame_capture=0,frame_reads=0,frame_hreads=0,frame_hwrites=0,frame_bytes=0,frame_stalls=0;
    integer target=-1,target_hold=0,packet_kind=-1,last_state=-1,active_kind;
    integer ix,holds,trace_position,latency,slot,write_address;
    reg release_next=0,probe_done=0,probe_pending=0,after_flush=0;
    reg source_block=0,byte_block=0,done_block=0;
    reg [P+T+3:0] prior_input;
    reg [BW+T+9:0] prior_byte;
    reg [BW+T+3:0] prior_done;
    wire [P+T+3:0] input_word={s_pixel,s_sof,s_eol,s_error,s_tag,s_colorspace};
    wire [BW+T+9:0] byte_word={m_byte,m_sof,m_last,m_index,m_tag};
    wire [BW+T+3:0] done_word={d_bytes,d_errors,d_tag,d_colorspace};
    reg [N-1:0] owned=0;reg [63:0] history_owned=0;
    reg [P-1:0] shadow[0:N-1],before_frame_q,want_frame_q,want_pixel;
    reg [31:0] history_shadow[0:63],before_history_q,want_history_q,want_history;
    reg do_capture,do_read,do_hread,do_hwrite;
    reg [12:0] states=0;reg [49:0] resetmask=0;reg [5:0] opcodes=0;

    function automatic integer kind_now;
        begin
            if(dut.return_state==3)kind_now=6;
            else if(dut.return_state==10)kind_now=7;
            else if(last_state==11)kind_now=packet_kind;
            else if(m_byte==8'hfe)kind_now=4;
            else if(m_byte==8'hff)kind_now=5;
            else case(m_byte[7:6])
                0:kind_now=0;1:kind_now=1;2:kind_now=2;default:kind_now=3;
            endcase
        end
    endfunction
    function automatic integer target_hit(input integer id);
        integer wanted_kind,wanted_remaining;
        begin
            target_hit=0;
            case(id)
                0:target_hit=dut.state==0 && dut.address==0;
                1:target_hit=dut.state==0 && dut.address==1 && dut.errors!=0;
                2:target_hit=dut.state==1 && dut.errors==0;
                3:target_hit=dut.state==1 && dut.errors==7;
                4,5,6:target_hit=dut.state==2 && dut.clear_cursor==(id==4?0:(id==5?31:63));
                7,8:target_hit=dut.state==3 && dut.cursor==(id==7?0:14);
                9:target_hit=dut.state==4 && dut.address==0;
                10,11,12,13:target_hit=dut.state==5 &&
                    (dut.current_pixel==dut.previous)==(id==10 || id==11) &&
                    (dut.run!=0)==(id==11 || id==13);
                14,47:target_hit=dut.state==6 && after_flush==(id==47);
                15,16:target_hit=dut.state==7 && (dut.history_q==dut.current_pixel)==(id==16);
                17:target_hit=dut.state==8 && dut.current_pixel[7:0]==dut.previous[7:0] && dut.diff_ok;
                18:target_hit=dut.state==8 && dut.current_pixel[7:0]==dut.previous[7:0] && !dut.diff_ok && dut.luma_ok;
                19:target_hit=dut.state==8 && dut.current_pixel[7:0]==dut.previous[7:0] && !dut.diff_ok && !dut.luma_ok;
                20:target_hit=dut.state==8 && dut.current_pixel[7:0]!=dut.previous[7:0];
                21,22:target_hit=dut.state==9 && (dut.address==N-1)==(id==22);
                23,24:target_hit=dut.state==10 && dut.cursor==(id==23?0:8);
                25,26:target_hit=dut.state==12 && (dut.errors==0)==(id==25);
                27,28:target_hit=dut.state==11 && dut.return_state==3 && dut.cursor==(id==27?1:14);
                29,30:target_hit=dut.state==11 && dut.return_state==10 && dut.cursor==(id==29?1:8);
                31,32,33,34,35,36,37,38,39,40,41,42,43,44:begin
                    case(id)
                        31:begin wanted_kind=3;wanted_remaining=1;end
                        32:begin wanted_kind=0;wanted_remaining=1;end
                        33:begin wanted_kind=1;wanted_remaining=1;end
                        34,35:begin wanted_kind=2;wanted_remaining=36-id;end
                        36,37,38,39:begin wanted_kind=4;wanted_remaining=40-id;end
                        default:begin wanted_kind=5;wanted_remaining=45-id;end
                    endcase
                    target_hit=dut.state==11 && kind_now()==wanted_kind && dut.remaining==wanted_remaining;
                end
                45:target_hit=dut.state==5 && dut.current_pixel==dut.previous && dut.run==61;
                46:target_hit=dut.state==5 && dut.current_pixel==dut.previous && dut.run>0 && dut.address==N-1;
                48:target_hit=dut.state==9 && dut.address<N-1 && (dut.address+1)%W==0;
                49:target_hit=dut.state==0 && dut.address==W && dut.x==0 && dut.errors!=0;
                default:target_hit=0;
            endcase
        end
    endfunction

    task automatic tick;
        begin
            @(negedge clk);
            if(release_next)begin rst=0;release_next=0;end
            s_valid=0;
            if(!rst && src<src_limit)begin
                s_pixel=pixels[src];s_sof=isof[src];s_eol=ieol[src];s_error=ierror[src];s_tag=itag[src];s_colorspace=ics[src];s_valid=1;
                ix=src%N;
                if(!source_block && ix>0 && meta[src/N][14]>0 && ix%meta[src/N][14]==0 && last_gapped!=src)begin
                    s_valid=0;last_gapped=src;
                end
            end
            holds=(out_block<NUM_BLOCKS)?meta[out_block][13]:0;
            m_ready=!rst && (phase==1 || byte_age>=holds);
            d_ready=!rst && (phase==1 || done_age>=holds);
            if(!rst && phase==1 && src==src_limit)begin
                trace_position=cycles-last_accept;
                if(probe_pending || (meta[out_block][4]<0 || trace_position==meta[out_block][4]))begin
                    if(dut.state!==meta[out_block][3] || !target_hit(target))
                        $fatal(1,"reset semantic target id=%0d state=%0d want=%0d trace=%0d",target,dut.state,meta[out_block][3],trace_position);
                    if(meta[out_block][5]>0 && target_hold<meta[out_block][5])begin
                        probe_pending=1;m_ready=0;d_ready=0;
                    end else begin
                        if(frame_capture!=meta[out_block][2] || frame_bytes!=meta[out_block][15] ||
                           frame_reads!=meta[out_block][16] || frame_hreads!=meta[out_block][17] || frame_hwrites!=meta[out_block][18])
                            $fatal(1,"reset owner action/prefix mismatch id=%0d capture=%0d bytes=%0d raw=%0d hist=%0d writes=%0d",target,frame_capture,frame_bytes,frame_reads,frame_hreads,frame_hwrites);
                        states[dut.state]=1;resetmask[target]=1;resets=resets+1;probe_done=1;
                        $display("OBS id=%0d state=%0d capture=%0d prefix=%0d reads=%0d hreads=%0d hwrites=%0d held=%0d trace=%0d",target,dut.state,frame_capture,frame_bytes,frame_reads,frame_hreads,frame_hwrites,target_hold,meta[out_block][4]);
                        rst=1;s_valid=0;m_ready=0;d_ready=0;
                        #1;if(s_ready || m_valid || d_valid || m_sof || m_last)$fatal(1,"immediate reset gate");
                    end
                end
            end
            @(posedge clk);
            cycles=cycles+1;if(cycles>CYCLE_LIMIT)$fatal(1,"frozen cycle limit");
            before_frame_q=dut.frame_q;before_history_q=dut.history_q;
            do_capture=0;do_read=0;do_hread=0;do_hwrite=0;
            if(rst)begin
                source_block=0;byte_block=0;done_block=0;byte_age=0;done_age=0;
                frame_capture=0;frame_reads=0;frame_hreads=0;frame_hwrites=0;frame_bytes=0;frame_stalls=0;
                owned=0;history_owned=0;after_flush=0;packet_kind=-1;last_state=-1;
            end else begin
                states[dut.state]=1;
                if(source_block)begin
                    if(!s_valid || input_word!==prior_input)$fatal(1,"blocked source beat changed");
                    sourceholds=sourceholds+1;
                end
                if(byte_block && (!m_valid || byte_word!==prior_byte))$fatal(1,"held byte/metadata changed");
                if(done_block && (!d_valid || done_word!==prior_done))$fatal(1,"held summary/metadata changed");
                source_block=s_valid && !s_ready;prior_input=input_word;
                byte_block=m_valid && !m_ready;prior_byte=byte_word;
                done_block=d_valid && !d_ready;prior_done=done_word;
                if(m_valid && d_valid)$fatal(1,"byte and summary overlap");
                if(!m_valid && (m_sof || m_last))$fatal(1,"unqualified byte markers");
                if(s_valid && s_ready)begin
                    if(src>=src_limit || dut.state!=0 || dut.address!==src%N || dut.x!==(src%N)%W)$fatal(1,"capture ownership/cursor");
                    if(src%N==0)begin
                        owned=0;history_owned=0;frame_capture=0;frame_reads=0;frame_hreads=0;frame_hwrites=0;frame_bytes=0;frame_stalls=0;
                        if(phase==0)begin
                            if(starts>0)begin
                                if(cycles!=last_summary+1)$fatal(1,"queued next frame accepted on wrong edge");
                                queued=queued+1;
                            end
                            starts=starts+1;
                        end
                    end
                    write_address=dut.address;want_pixel=s_pixel;shadow[write_address]=s_pixel;owned[write_address]=1;do_capture=1;
                    capturewrites=capturewrites+1;frame_capture=frame_capture+1;
                    if(src%N==N-1)last_accept=cycles;
                    src=src+1;
                end
                if(dut.state==1 && (frame_capture!=N || !(&owned) || dut.errors!==meta[out_block][7]))$fatal(1,"full-frame atomic check/error capture");
                if(dut.state==4)begin
                    if(frame_capture!=N || !owned[dut.address] || dut.address>=N)$fatal(1,"raw read ownership");
                    if(dut.address==0 && dut.previous!==32'h000000ff)$fatal(1,"initial previous pixel");
                    want_frame_q=shadow[dut.address];do_read=1;reads=reads+1;frame_reads=frame_reads+1;
                end
                if(dut.state==2)begin
                    slot=dut.clear_cursor;want_history=0;do_hwrite=1;history_shadow[slot]=0;history_owned[slot]=1;
                    hwrites=hwrites+1;frame_hwrites=frame_hwrites+1;
                end
                if(dut.state==6 || dut.state==8)begin
                    slot=(dut.current_pixel[31:24]*3+dut.current_pixel[23:16]*5+dut.current_pixel[15:8]*7+dut.current_pixel[7:0]*11)%64;
                    if(dut.color_hash!==slot || !(&history_owned))$fatal(1,"hash residue/history clear ownership");
                    if(C==3 && dut.current_pixel[7:0]!==8'hff)$fatal(1,"RGB alpha must be255");
                    if(dut.state==6)begin
                        want_history_q=history_shadow[slot];do_hread=1;hreads=hreads+1;frame_hreads=frame_hreads+1;after_flush=0;
                    end else begin
                        want_history=dut.current_pixel;do_hwrite=1;history_shadow[slot]=want_history;
                        hwrites=hwrites+1;frame_hwrites=frame_hwrites+1;
                    end
                end
                if(dut.state==9 && dut.previous!==dut.current_pixel)$fatal(1,"previous pixel update");
                if(m_valid)begin
                    if(out_block>=NUM_BLOCKS || frame_capture!=N || frame_bytes>=meta[out_block][6])$fatal(1,"unexpected/partial-frame public byte");
                    if(m_byte!==gold[ob[out_block]+frame_bytes] || m_index!==frame_bytes ||
                       m_sof!==(frame_bytes==0) || m_last!==(frame_bytes==meta[out_block][6]-1) || m_tag!==btag[out_block])
                        $fatal(1,"canonical byte/metadata block=%0d index=%0d byte=%02h want=%02h",out_block,frame_bytes,m_byte,gold[ob[out_block]+frame_bytes]);
                    if(frame_bytes==0 && byte_age==0 && cycles-last_accept!=67)$fatal(1,"first byte latency");
                    active_kind=kind_now();
                    if(last_state!=11)begin packet_kind=active_kind;if(active_kind<6)opcodes[active_kind]=1;end
                    if(m_ready)begin
                        if(phase!=1 && byte_age!=holds)$fatal(1,"byte hold count");
                        frame_bytes=frame_bytes+1;byte_age=0;last_byte=cycles;
                        if(phase==1)ownerbytes=ownerbytes+1;else bytes=bytes+1;
                        if(dut.remaining==1 && dut.return_state==6)after_flush=1;
                    end else begin byte_age=byte_age+1;frame_stalls=frame_stalls+1;outputholds=outputholds+1;end
                end else byte_age=0;
                if(d_valid)begin
                    if(out_block>=NUM_BLOCKS || frame_capture!=N || frame_bytes!=meta[out_block][6] ||
                       d_bytes!==meta[out_block][6] || d_errors!==meta[out_block][7] || d_tag!==btag[out_block] || d_colorspace!==meta[out_block][8])
                        $fatal(1,"summary fields/atomic byte count block=%0d",out_block);
                    if(done_age==0 && ((meta[out_block][7]!=0 && cycles-last_accept!=2) ||
                       (meta[out_block][7]==0 && cycles-last_byte!=2)))$fatal(1,"first summary latency");
                    if(d_ready)begin
                        if(phase==1)$fatal(1,"reset owner summary retired before target");
                        if(done_age!=holds)$fatal(1,"summary hold count");
                        latency=cycles-last_accept;
                        if(latency!=meta[out_block][9]+frame_stalls)$fatal(1,"exact tail block=%0d got=%0d want=%0d stalls=%0d",out_block,latency,meta[out_block][9],frame_stalls);
                        if(frame_capture!=N || frame_reads!=(meta[out_block][7]==0?N:0) || frame_hreads!=meta[out_block][10] ||
                           frame_hwrites!=(meta[out_block][7]==0?64+meta[out_block][11]:0))$fatal(1,"exact frame RAM work");
                        latencies=latencies+1;if(meta[out_block][9]>max_tail)max_tail=meta[out_block][9];
                        last_summary=cycles;done_age=0;
                        if(phase==0)begin frames=frames+1;out_block=out_block+1;end else fresh=fresh+1;
                    end else begin done_age=done_age+1;frame_stalls=frame_stalls+1;outputholds=outputholds+1;end
                end else done_age=0;
                if(probe_pending && !probe_done)target_hold=target_hold+1;
                last_state=dut.state;
            end
            #1;
            if(do_capture && dut.frame_memory[write_address]!==want_pixel)$fatal(1,"clocked accepted raw write");
            if(do_read)begin if(dut.frame_q!==want_frame_q)$fatal(1,"synchronous frame read-q");end
            else if(dut.frame_q!==before_frame_q)$fatal(1,"frame read-q changed outside read");
            if(do_hread)begin if(dut.history_q!==want_history_q)$fatal(1,"synchronous history read-q");end
            else if(dut.history_q!==before_history_q)$fatal(1,"history read-q changed outside read");
            if(do_hwrite && dut.history_memory[slot]!==want_history)$fatal(1,"clocked history write");
            if(rst)begin
                if(s_ready || m_valid || d_valid || m_sof || m_last || dut.state!=0 || dut.return_state!=0 || dut.address!=0 || dut.x!=0 ||
                   dut.cursor!=0 || dut.clear_cursor!=0 || dut.run!=0 || dut.previous!==32'h000000ff || dut.packet!=0 || dut.remaining!=0 ||
                   dut.byte_count!=0 || dut.tag!=0 || dut.errors!=0 || dut.colorspace!=0)$fatal(1,"active reset cancellation");
            end else states[dut.state]=1;
            #1;
        end
    endtask

    initial begin
        if(!$value$plusargs("FIXTURE=%s",fixture))$fatal(1,"fixture argument");
        fd=$fopen(fixture,"r");if(!fd)$fatal(1,"fixture open");
        if(NUM_INPUTS!=N*NUM_BLOCKS)$fatal(1,"stored input allocation");
        for(b=0;b<NUM_BLOCKS;b=b+1)begin
            ib[b]=ni;ob[b]=no;
            for(j=0;j<6;j=j+1)begin r=$fscanf(fd,"%d",k);if(r!=1)$fatal(1,"block header parse");meta[b][j]=k;end
            for(j=6;j<19;j=j+1)begin r=$fscanf(fd,"%d",k);if(r!=1)$fatal(1,"block metadata parse");meta[b][j]=k;end
            r=$fscanf(fd,"%h",value);if(r!=1 || value>((64'd1<<T)-1))$fatal(1,"tag parse/range");btag[b]=value;
            if(meta[b][0]<0 || meta[b][0]>1 || meta[b][2]<0 || meta[b][2]>N || meta[b][6]<0 || meta[b][6]>(C+1)*N+22 ||
               meta[b][7]<0 || meta[b][7]>7 || meta[b][8]<0 || meta[b][8]>1)$fatal(1,"metadata range");
            if(meta[b][0]==0 && (meta[b][1]!=-1 || meta[b][2]!=N || meta[b][3]!=-1 || meta[b][4]!=-1 || meta[b][5]!=0))$fatal(1,"complete metadata");
            if(meta[b][7]!=0 && (meta[b][6]!=0 || meta[b][9]!=2 || meta[b][10]!=0 || meta[b][11]!=0 || meta[b][12]!=0))$fatal(1,"error work separation");
            if(meta[b][7]==0 && meta[b][9]!=112+3*N+2*meta[b][10]+meta[b][11]+meta[b][12])$fatal(1,"tail formula");
            for(j=0;j<N;j=j+1)begin
                r=$fscanf(fd,"%h",value);if(r!=1 || (C==3 && value>64'hffffff) || value>64'hffffffff)$fatal(1,"pixel parse/range");pixels[ni]=value;
                r=$fscanf(fd,"%d",k);if(r!=1 || k<0 || k>1)$fatal(1,"SOF parse");isof[ni]=k;
                r=$fscanf(fd,"%d",k);if(r!=1 || k<0 || k>1)$fatal(1,"EOL parse");ieol[ni]=k;
                r=$fscanf(fd,"%d",k);if(r!=1 || k<0 || k>1)$fatal(1,"error parse");ierror[ni]=k;
                r=$fscanf(fd,"%h",value);if(r!=1 || value>((64'd1<<T)-1))$fatal(1,"input tag parse");itag[ni]=value;
                r=$fscanf(fd,"%d",k);if(r!=1 || k<0 || k>1)$fatal(1,"colorspace parse");ics[ni]=k;
                ni=ni+1;
            end
            for(j=0;j<meta[b][6];j=j+1)begin
                if(no>=NUM_BYTES)$fatal(1,"byte allocation");
                r=$fscanf(fd,"%h",value);if(r!=1 || value>255)$fatal(1,"byte parse/range");gold[no]=value;no=no+1;
            end
        end
        ib[NUM_BLOCKS]=ni;ob[NUM_BLOCKS]=no;
        if(ni!=NUM_INPUTS || no!=NUM_BYTES)$fatal(1,"exact fixture length");
        r=$fscanf(fd,"%h",value);if(r==1)$fatal(1,"trailing fixture data");$fclose(fd);
        phase=0;out_block=0;src=0;src_limit=0;
        tick();tick();
        if(meta[0][0]==0)begin
            src_limit=NUM_INPUTS;release_next=1;
            while(frames<NUM_BLOCKS)tick();
            if(src!=src_limit || queued!=NUM_BLOCKS-1)$fatal(1,"main input/queue count");
        end else begin
            if(NUM_BLOCKS%2!=0)$fatal(1,"owner/fresh pairs");
            for(b=0;b<NUM_BLOCKS;b=b+2)begin
                if(meta[b][0]!=1 || meta[b+1][0]!=0)$fatal(1,"owner/fresh ordering");
                phase=1;out_block=b;src=ib[b];src_limit=ib[b]+meta[b][2];target=meta[b][1];
                probe_done=0;probe_pending=0;target_hold=0;frame_capture=0;frame_reads=0;frame_hreads=0;frame_hwrites=0;frame_bytes=0;frame_stalls=0;
                release_next=1;
                while(!probe_done)tick();
                tick();
                phase=2;out_block=b+1;src=ib[b+1];src_limit=ib[b+2];release_next=1;
                while(fresh<(b/2)+1)tick();
                if(src!=src_limit)$fatal(1,"fresh full-frame input");
            end
        end
        src_limit=src;phase=3;out_block=NUM_BLOCKS;tick();tick();tick();
        if(m_valid || d_valid)$fatal(1,"stale public output after completion");
        $display("PASS W=%0d H=%0d C=%0d T=%0d frames=%0d fresh=%0d resets=%0d queued=%0d latencies=%0d bytes=%0d ownerbytes=%0d capturewrites=%0d reads=%0d hreads=%0d hwrites=%0d sourceholds=%0d outputholds=%0d max_tail=%0d states=%h opcodes=%h resetmask=%h cycles=%0d",W,H,C,T,frames,fresh,resets,queued,latencies,bytes,ownerbytes,capturewrites,reads,hreads,hwrites,sourceholds,outputholds,max_tail,states,opcodes,resetmask,cycles);
        $finish;
    end
endmodule
