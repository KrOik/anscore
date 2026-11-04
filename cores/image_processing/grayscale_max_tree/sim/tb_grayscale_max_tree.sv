`timescale 1ns/1ps
module tb_grayscale_max_tree;
    parameter WIDTH=8,HEIGHT=8,PIXEL_W=8,CONNECTIVITY=4,TAG_W=8,FRAMES=16,RESETS=46;
    localparam N=WIDTH*HEIGHT,G=1<<PIXEL_W,IW=(N<2)?1:$clog2(N),CW=(N<2)?1:$clog2(N+1),
        SW=PIXEL_W+2+TAG_W,OW=2*IW+PIXEL_W+CW+TAG_W+6,
        R=2*HEIGHT*(WIDTH-1)+2*WIDTH*(HEIGHT-1)+((CONNECTIVITY==8)?4*(WIDTH-1)*(HEIGHT-1):0),
        Y=WIDTH*HEIGHT*(HEIGHT-1)/2,BOUND=3*G+(20+2*CONNECTIVITY)*N+Y+2*R+R*N+3;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,s_valid=0,s_sof=0,s_eol=0,m_ready=0;
    reg [PIXEL_W-1:0] s_pixel=0;reg [TAG_W-1:0] s_tag=0;
    wire s_ready,m_valid,m_canonical,m_sof,m_eol,m_last;
    wire [IW-1:0] m_index,m_parent;wire [PIXEL_W-1:0] m_level;wire [CW-1:0] m_area;
    wire [1:0] m_errors;wire [TAG_W-1:0] m_tag;
    grayscale_max_tree #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.PIXEL_W(PIXEL_W),.CONNECTIVITY(CONNECTIVITY),.TAG_W(TAG_W)) dut(.*);
    wire [SW-1:0] source_word={s_pixel,s_sof,s_eol,s_tag};
    wire [OW-1:0] output_word={m_index,m_parent,m_level,m_canonical,m_area,m_sof,m_eol,m_last,m_errors,m_tag};
    reg [SW-1:0] source[0:16383];reg [OW-1:0] expected[0:16383];
    integer expected_errors[0:1023],expected_nodes[0:1023];
    integer fd,scan,raw_error,raw_nodes,mode,group_id,expected_resets,selected_resets,f,p,k,id,guard,latency,nodes;
    reg [SW-1:0] raw_source;reg [OW-1:0] raw_expected;reg [2047:0] fixture_path;
    integer cycle=0,last_cycle=0,resets=0,fresh=0,queued=0,outputs=0,total_nodes=0,max_latency=0;
    integer live_clear=0,live_hist=0,live_prefix=0,live_sort=0,live_activate=0,live_coord=0,
        live_neighbor=0,live_nreads=0,live_finds=0,live_zreads=0,live_halves=0,live_links=0,
        live_canon=0,live_area=0,live_oreads=0,walk_reads=0;
    integer total_zreads=0,total_halves=0,total_links=0,source_holds=0,output_holds=0,ii1=0,last_capture=-99;
    integer image_checks=0,hist_checks=0,order_checks=0,z_checks=0,parent_checks=0,area_checks=0;
    reg [36:0] states=0;
    reg [45:0] reset_targets=0,expected_targets=0;
    reg source_stalled=0,output_stalled=0;reg [SW-1:0] held_source;reg [OW-1:0] held_output;
    reg [N-1:0] image_owned=0,active_reference=0,order_owned=0,parent_owned=0,area_owned=0;
    reg [G-1:0] hist_owned=0;
    reg [PIXEL_W-1:0] pixel_reference[0:N-1];
    reg [IW-1:0] order_reference[0:N-1],z_reference[0:N-1],parent_reference[0:N-1];
    reg [CW-1:0] hist_reference[0:G-1],area_reference[0:N-1];
    reg image_pending=0,hist_pending=0,order_pending=0,z_pending=0,zgrand_pending=0,
        parent_pending=0,grand_pending=0,area_pending=0;
    reg [PIXEL_W:0] image_expected;
    reg [CW-1:0] hist_expected,area_expected;
    reg [IW-1:0] order_expected,z_expected,zgrand_expected,parent_expected,grand_expected;
    integer address,last_activated=-1,last_level=-1;
    task expect_image;input integer a;
        begin
            if(a<0 || a>=N || !image_owned[a])$fatal(1,"unowned image read %0d",a);
            image_expected={active_reference[a],pixel_reference[a]};image_pending=1;
        end
    endtask
    task expect_parent;input integer a;input integer grand;
        begin
            if(a<0 || a>=N || !parent_owned[a])$fatal(1,"unowned tree-parent read");
            if(grand)begin grand_expected=parent_reference[a];grand_pending=1;end
            else begin parent_expected=parent_reference[a];parent_pending=1;end
        end
    endtask
    task expect_area;input integer a;
        begin if(a<0 || a>=N || !area_owned[a])$fatal(1,"unowned area read");area_expected=area_reference[a];area_pending=1;end
    endtask
    always @(posedge clk)begin
        cycle=cycle+1;
        if(rst)begin
            source_stalled=0;output_stalled=0;image_pending=0;hist_pending=0;order_pending=0;
            z_pending=0;zgrand_pending=0;parent_pending=0;grand_pending=0;area_pending=0;
            image_owned=0;active_reference=0;order_owned=0;parent_owned=0;area_owned=0;hist_owned=0;
            live_clear=0;live_hist=0;live_prefix=0;live_sort=0;live_activate=0;live_coord=0;
            live_neighbor=0;live_nreads=0;live_finds=0;live_zreads=0;live_halves=0;live_links=0;
            live_canon=0;live_area=0;live_oreads=0;last_capture=-99;last_activated=-1;last_level=-1;
        end else begin
            states[dut.state]=1;
            if(source_stalled && (!s_valid || source_word!==held_source))$fatal(1,"actual source token withdrawn before accept/reset");
            if(output_stalled && (!m_valid || output_word!==held_output))$fatal(1,"complete held output changed");
            source_stalled=s_valid&&!s_ready;held_source=source_word;
            output_stalled=m_valid&&!m_ready;held_output=output_word;
            if(source_stalled)source_holds=source_holds+1;if(output_stalled)output_holds=output_holds+1;
            if(image_pending)begin if(dut.image_q!==image_expected)$fatal(1,"clocked image RAM");image_pending=0;image_checks=image_checks+1;end
            if(hist_pending)begin if(dut.hist_q!==hist_expected)$fatal(1,"clocked histogram RAM");hist_pending=0;hist_checks=hist_checks+1;end
            if(order_pending)begin if(dut.order_q!==order_expected)$fatal(1,"clocked stable order RAM");order_pending=0;order_checks=order_checks+1;end
            if(z_pending)begin if(dut.z_q!==z_expected)$fatal(1,"clocked union-find RAM");z_pending=0;z_checks=z_checks+1;end
            if(zgrand_pending)begin if(dut.zgrand_q!==zgrand_expected)$fatal(1,"clocked union-find grandparent RAM");zgrand_pending=0;z_checks=z_checks+1;end
            if(parent_pending)begin if(dut.parent_q!==parent_expected)$fatal(1,"clocked tree-parent RAM");parent_pending=0;parent_checks=parent_checks+1;end
            if(grand_pending)begin if(dut.grand_q!==grand_expected)$fatal(1,"clocked canonical grandparent RAM");grand_pending=0;parent_checks=parent_checks+1;end
            if(area_pending)begin if(dut.area_q!==area_expected)$fatal(1,"clocked area RAM");area_pending=0;area_checks=area_checks+1;end
            if(s_valid&&s_ready)begin
                if(dut.capture_index==0)begin
                    image_owned=0;active_reference=0;order_owned=0;parent_owned=0;area_owned=0;hist_owned=0;
                    live_clear=0;live_hist=0;live_prefix=0;live_sort=0;live_activate=0;live_coord=0;
                    live_neighbor=0;live_nreads=0;live_finds=0;live_zreads=0;live_halves=0;live_links=0;
                    live_canon=0;live_area=0;live_oreads=0;last_activated=-1;last_level=-1;
                end
                pixel_reference[dut.capture_index]=s_pixel;image_owned[dut.capture_index]=1;
                if(last_capture==cycle-1)ii1=ii1+1;last_capture=cycle;
                if(dut.capture_index==N-1)last_cycle=cycle;
            end
            case(dut.state)
                2:begin hist_reference[dut.bin_index]=0;hist_owned[dut.bin_index]=1;live_clear=live_clear+1;end
                3,8:expect_image(dut.scan_index);
                4,9:begin
                    address=dut.image_q[PIXEL_W-1:0];if(!hist_owned[address])$fatal(1,"histogram not cleared this frame");
                    hist_expected=hist_reference[address];hist_pending=1;
                end
                5:begin hist_reference[dut.image_q[PIXEL_W-1:0]]=dut.hist_q+1'b1;live_hist=live_hist+1;end
                6:begin hist_expected=hist_reference[dut.bin_index];hist_pending=1;end
                7:begin
                    if(dut.prefix_total+dut.hist_q>N)$fatal(1,"prefix count overflow");
                    hist_reference[dut.bin_index]=dut.prefix_total+dut.hist_q;live_prefix=live_prefix+1;
                end
                10:begin
                    if(dut.hist_q<1 || dut.hist_q>N || order_owned[dut.hist_q-1])$fatal(1,"stable-sort address ownership");
                    order_reference[dut.hist_q-1]=dut.scan_index;order_owned[dut.hist_q-1]=1;
                    hist_reference[dut.image_q[PIXEL_W-1:0]]=dut.hist_q-1'b1;live_sort=live_sort+1;
                end
                11,24,29:begin
                    if(!order_owned[dut.order_position])$fatal(1,"unwritten order read");
                    order_expected=order_reference[dut.order_position];order_pending=1;
                end
                12:expect_image(dut.order_q);
                13:begin
                    if(active_reference[dut.order_q] || image_owned!={N{1'b1}})$fatal(1,"activation before complete fresh capture");
                    if(live_activate!=0 && (dut.image_q[PIXEL_W-1:0]>last_level ||
                       (dut.image_q[PIXEL_W-1:0]==last_level && dut.order_q>=last_activated)))$fatal(1,"exact descending gray/index stable order");
                    last_level=dut.image_q[PIXEL_W-1:0];last_activated=dut.order_q;
                    active_reference[dut.order_q]=1;z_reference[dut.order_q]=dut.order_q;
                    parent_reference[dut.order_q]=dut.order_q;parent_owned[dut.order_q]=1;
                    area_reference[dut.order_q]=1;area_owned[dut.order_q]=1;live_activate=live_activate+1;
                end
                14:live_coord=live_coord+1;
                15:live_neighbor=live_neighbor+1;
                16:begin expect_image(dut.neighbor_address);live_nreads=live_nreads+1;end
                17:if(dut.image_q[PIXEL_W])begin live_finds=live_finds+1;walk_reads=0;end
                18,20:begin
                    address=(dut.state==18)?dut.root_address:dut.z_q;
                    if(address<0 || address>=N || !active_reference[address])$fatal(1,"unowned union-find pointer");
                    if(dut.state==18)begin z_expected=z_reference[address];z_pending=1;end
                    else begin zgrand_expected=z_reference[address];zgrand_pending=1;end
                    walk_reads=walk_reads+1;if(walk_reads>N)$fatal(1,"union-find cycle/depth");
                    live_zreads=live_zreads+1;total_zreads=total_zreads+1;
                end
                21:begin z_reference[dut.root_address]=dut.zgrand_q;live_halves=live_halves+1;total_halves=total_halves+1;end
                22:begin
                    if(dut.root_address==dut.current || z_reference[dut.root_address]!=dut.root_address)$fatal(1,"LINK requires distinct root");
                    z_reference[dut.root_address]=dut.current;parent_reference[dut.root_address]=dut.current;
                    live_links=live_links+1;total_links=total_links+1;
                end
                25:expect_parent(dut.order_q,0);
                26:begin expect_parent(dut.parent_q,1);expect_image(dut.parent_q);end
                27:expect_image(dut.grand_q);
                28:begin
                    if(dut.parent_level==dut.image_q[PIXEL_W-1:0])parent_reference[dut.canonical_index]=dut.grand_q;
                    live_canon=live_canon+1;
                end
                30:begin expect_parent(dut.order_q,0);expect_area(dut.order_q);end
                31:expect_area(dut.parent_q);
                32:begin
                    if(dut.parent_q!=dut.canonical_index)begin
                        if(dut.area_q+dut.child_area>N)$fatal(1,"area count overflow");
                        area_reference[dut.parent_q]=dut.area_q+dut.child_area;
                    end
                    live_area=live_area+1;
                    if(live_area==N && (dut.parent_q!=dut.canonical_index || dut.area_q!=N))$fatal(1,"complete root area certificate");
                end
                33:begin expect_parent(dut.output_index,0);expect_image(dut.output_index);expect_area(dut.output_index);live_oreads=live_oreads+1;end
                34:expect_image(dut.parent_q);
            endcase
            if(m_valid&&s_ready)$fatal(1,"overlapped owners");
            if(m_valid && m_errors==0 && (live_activate!=N || live_canon!=N || live_area!=N))$fatal(1,"provisional tree escaped");
        end
        if(cycle>64000000)$fatal(1,"finite total watchdog");
    end
    task drive;input [SW-1:0] word;begin {s_pixel,s_sof,s_eol,s_tag}=word;s_valid=1;end endtask
    task beat;input integer value,sof,eol;input [TAG_W-1:0] token_tag;
        begin
            s_pixel=value;s_sof=sof;s_eol=eol;s_tag=token_tag;s_valid=1;
            if(!s_ready)$fatal(1,"capture II1 admission");@(posedge clk);#1;@(negedge clk);
        end
    endtask
    task wait_output;
        integer g;
        begin
            g=0;if(!m_valid)begin
                while(!m_valid)begin @(posedge clk);#1;g=g+1;if(g>BOUND)$fatal(1,"tail bound watchdog");end
                @(negedge clk);
            end
        end
    endtask
    task retire;begin m_ready=1;@(posedge clk);#1;@(negedge clk);m_ready=0;end endtask
    task check_work;
        integer exact_tail;
        begin
            latency=cycle-last_cycle;
            if(m_errors==0)begin
                exact_tail=3*G+(20+2*CONNECTIVITY)*N+Y+2*R+2*live_zreads+3;
                if(live_clear!=G || live_hist!=N || live_prefix!=G || live_sort!=N || live_activate!=N ||
                   live_coord!=N+Y || live_neighbor!=CONNECTIVITY*N || live_nreads!=R || live_finds!=R/2 ||
                   live_links!=N-1 || live_canon!=N || live_area!=N || live_oreads!=1 || live_zreads>R*N/2 ||
                   latency!=exact_tail || latency>BOUND)begin
                    $display("work latency=%0d/%0d H=%0d clear=%0d hist=%0d prefix=%0d sort=%0d act=%0d coord=%0d neighbor=%0d nr=%0d finds=%0d links=%0d canon=%0d area=%0d oread=%0d",latency,exact_tail,live_zreads,live_clear,live_hist,live_prefix,live_sort,live_activate,live_coord,live_neighbor,live_nreads,live_finds,live_links,live_canon,live_area,live_oreads);
                    $fatal(1,"exact structural work certificate");
                end
            end else if(latency!=1 || live_clear || live_hist || live_prefix || live_sort || live_activate || live_coord ||
                        live_neighbor || live_nreads || live_finds || live_zreads || live_links || live_canon || live_area || live_oreads)$fatal(1,"rejected full-frame zero-work certificate");
            if(latency>max_latency)max_latency=latency;
        end
    endtask
    task send_probe;input integer kind,start;input [TAG_W-1:0] token_tag;
        integer a,value;
        begin
            for(a=start;a<N;a=a+1)begin
                value=(kind==1)?((a<2)?G-1:0):(kind==3)?G-1:((a==N-1)?G-1:0);
                beat(value,(a==0)^((kind==2)&&(a==0)),a%WIDTH==WIDTH-1,(a==0)?token_tag:~token_tag);
            end
        end
    endtask
    task check_analytic;input integer index_in;input [TAG_W-1:0] token_tag;
        integer ep,el,ec,ea;
        begin
            ep=0;el=(index_in==N-1)?G-1:0;ec=(index_in==0 || index_in==N-1);ea=(index_in==0)?N:((index_in==N-1)?1:0);
            if(m_index!=index_in || m_parent!=ep || m_level!=el || m_canonical!=ec || m_area!=ea ||
               m_sof!=(index_in==0) || m_eol!=(index_in%WIDTH==WIDTH-1) || m_last!=(index_in==N-1) || m_errors!=0 || m_tag!==token_tag)$fatal(1,"complete analytic fresh tree/area/tag index=%0d",index_in);
        end
    endtask
    task full_fresh;input [TAG_W-1:0] token_tag;
        integer a;
        begin
            send_probe(0,0,token_tag);s_valid=0;wait_output();check_work();
            for(a=0;a<N;a=a+1)begin
                if(a!=0)wait_output();check_analytic(a,token_tag);
                repeat(2)begin @(posedge clk);#1;@(negedge clk);end
                retire();
            end
            if(live_oreads!=N || m_valid || !s_ready)$fatal(1,"fresh full retirement");
            repeat(2)begin @(posedge clk);#1;@(negedge clk);if(m_valid || !s_ready)$fatal(1,"fresh no-stale owner");end
            fresh=fresh+1;
        end
    endtask
    function included;input integer target;
        begin
            included=!(N==1 && (target==16 || target==17 || target==18 || target==19 || target==20 || target==21 || target==22 || target==38 || target==39 || target==42)) &&
                !(target==40 && HEIGHT==1) && !(target==41 && (WIDTH<3 || HEIGHT<2));
        end
    endfunction
    function target_seen;input integer target;
        begin
            if(target<37)target_seen=dut.state==target;
            else case(target)
                37:target_seen=m_valid && m_errors!=0;
                38:target_seen=m_valid && m_last;
                39:target_seen=dut.state==0 && dut.capture_index==1 && dut.errors!=0;
                40:target_seen=dut.state==14 && dut.coord_remainder>=WIDTH;
                41:target_seen=dut.state==21 && dut.zgrand_q!=dut.z_q;
                42:target_seen=dut.state==28 && dut.parent_level==dut.image_q[PIXEL_W-1:0] && dut.grand_q!=dut.parent_q;
                43:target_seen=dut.state==32 && dut.parent_q==dut.canonical_index;
                44:target_seen=dut.state==7 && dut.bin_index==G-1 && dut.prefix_total+dut.hist_q==N;
                45:target_seen=dut.state==10 && dut.scan_index==0 && dut.hist_q==1;
                default:target_seen=0;
            endcase
        end
    endfunction
    task abort_target;input integer target;
        integer kind,a,g;
        begin
            kind=(target==20 || target==21)?1:(target==37 || target==39)?2:(target==41 || target==42 || target==45)?3:0;
            if(target==0 || target==39)begin
                if(N>1)beat(0,target!=39,WIDTH==1,target);
            end else send_probe(kind,0,target);
            drive(source[0]);
            if(target==38)begin
                wait_output();for(a=0;a<N-1;a=a+1)begin check_analytic(a,target);retire();wait_output();end
            end
            g=0;
            while(!target_seen(target))begin @(negedge clk);g=g+1;if(g>BOUND)$fatal(1,"unreachable immediate reset target %0d",target);end
            states[dut.state]=1;reset_targets[target]=1;
            rst=1;#1;if(s_ready || m_valid || m_sof || m_eol || m_last)$fatal(1,"immediate reset public gates");
            @(posedge clk);#1;
            if(output_word!==0 || dut.state!=0 || dut.capture_index!=0)$fatal(1,"canonical reset public record");
            @(negedge clk);s_valid=0;rst=0;#1;resets=resets+1;full_fresh(target+97);
        end
    endtask
    task send_remaining;input integer frame_id,start;
        integer a;
        begin
            for(a=start;a<N;a=a+1)begin
                if(a!=0 && (a+frame_id)%7==0)begin s_valid=0;@(posedge clk);#1;@(negedge clk);end
                drive(source[frame_id*N+a]);if(!s_ready)$fatal(1,"main capture blocked");
                @(posedge clk);#1;@(negedge clk);
            end
        end
    endtask
    initial begin
        if(!$value$plusargs("MODE=%d",mode) || !$value$plusargs("GROUP=%d",group_id) || !$value$plusargs("COUNT=%d",expected_resets) || !$value$plusargs("FIXTURE=%s",fixture_path))$fatal(1,"missing frozen paths/mode");
        fd=$fopen(fixture_path,"r");if(!fd)$fatal(1,"fixture open");
        for(f=0;f<FRAMES;f=f+1)begin
            scan=$fscanf(fd,"%d %d\n",raw_error,raw_nodes);if(scan!=2)$fatal(1,"fixture header");
            expected_errors[f]=raw_error;expected_nodes[f]=raw_nodes;
            for(p=0;p<N;p=p+1)begin scan=$fscanf(fd,"%h\n",raw_source);if(scan!=1)$fatal(1,"fixture input");source[f*N+p]=raw_source;end
            for(p=0;p<N;p=p+1)begin scan=$fscanf(fd,"%h\n",raw_expected);if(scan!=1)$fatal(1,"fixture output");expected[f*N+p]=raw_expected;end
        end
        $fclose(fd);repeat(2)@(negedge clk);rst=0;#1;
        if(mode==1)begin
            selected_resets=0;
            for(id=0;id<46;id=id+1)if(included(id) && (group_id<0 || id%2==group_id))begin expected_targets[id]=1;selected_resets=selected_resets+1;abort_target(id);end
            if(resets!=selected_resets || fresh!=selected_resets || selected_resets!=expected_resets ||
               reset_targets!==expected_targets || (group_id<0 && resets!=RESETS) || (group_id>=0 && (N!=256 || group_id>1)))$fatal(1,"frozen reset/fresh population and exact selected IDs");
        end else if(mode==0)begin
            for(f=0;f<FRAMES;f=f+1)begin
                send_remaining(f,(f==0)?0:1);
                if(f+1<FRAMES)drive(source[(f+1)*N]);else s_valid=0;
                wait_output();check_work();nodes=0;
                if(m_errors!=expected_errors[f])$fatal(1,"frame error bits");
                for(p=0;p<N;p=p+1)begin
                    if(p!=0)wait_output();
                    if(output_word!==expected[f*N+p])begin
                        $display("frame=%0d pixel=%0d expected=%h actual=%h",f,p,expected[f*N+p],output_word);$fatal(1,"independent threshold CC/tree/area oracle");
                    end
                    nodes=nodes+m_canonical;outputs=outputs+1;
                    repeat(2+(f+p)%2)begin @(posedge clk);#1;@(negedge clk);end
                    retire();
                end
                if(nodes!=expected_nodes[f] || live_oreads!=((m_errors==0)?N:0))$fatal(1,"complete tree-node/replay population");
                total_nodes=total_nodes+nodes;
                if(m_valid || !s_ready)$fatal(1,"whole frame retirement");
                if(f+1<FRAMES)begin
                    if(!s_valid || source_word!==source[(f+1)*N])$fatal(1,"actual next frozen pixel lost");
                    @(posedge clk);#1;@(negedge clk);queued=queued+1;
                end
            end
            s_valid=0;repeat(2)begin @(posedge clk);#1;@(negedge clk);if(m_valid)$fatal(1,"extra stale output");end
            if(queued!=FRAMES-1 || outputs!=FRAMES*N)$fatal(1,"frozen main population");
        end else $fatal(1,"unplanned mode");
        if(mode==0 || group_id<0)for(id=0;id<37;id=id+1)if(included(id) && !states[id])$fatal(1,"missing reachable basic state %0d",id);
        if(output_holds==0 || (mode==0 && source_holds==0) || (N>1 && ii1==0))$fatal(1,"protocol coverage");
        $display("PASS MODE=%0d GROUP=%0d W=%0d H=%0d B=%0d K=%0d T=%0d frames=%0d outputs=%0d nodes=%0d queued=%0d resets=%0d fresh=%0d find_reads=%0d halves=%0d links=%0d image_checks=%0d hist_checks=%0d order_checks=%0d z_checks=%0d parent_checks=%0d area_checks=%0d source_holds=%0d output_holds=%0d ii1=%0d max_latency=%0d states=%h targets=%h cycles=%0d",
            mode,group_id,WIDTH,HEIGHT,PIXEL_W,CONNECTIVITY,TAG_W,(mode==0)?FRAMES:0,outputs,total_nodes,queued,resets,fresh,total_zreads,total_halves,total_links,image_checks,hist_checks,order_checks,z_checks,parent_checks,area_checks,source_holds,output_holds,ii1,max_latency,states,reset_targets,cycle);
        $finish;
    end
endmodule
