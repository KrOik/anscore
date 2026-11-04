`timescale 1ns/1ps
module tb_qoi_decoder;
    parameter MAX_WIDTH=8,MAX_HEIGHT=8,MAX_BYTES=342,TAG_W=8,FRAMES=1,RESETS=42;
    localparam P=MAX_WIDTH*MAX_HEIGHT,XW=(MAX_WIDTH<2)?1:$clog2(MAX_WIDTH),
        YW=(MAX_HEIGHT<2)?1:$clog2(MAX_HEIGHT),FCW=$clog2(MAX_BYTES+1),
        SW=9+TAG_W,OW=111+XW+YW+FCW+TAG_W,BOUND=5+3*MAX_BYTES+3*P;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,s_valid=0,s_last=0,m_ready=0;reg [7:0] s_byte=0;reg [TAG_W-1:0] s_tag=0;
    wire s_ready,m_valid,m_sof,m_eol,m_last,m_colorspace;
    wire [31:0] m_rgba,m_width,m_height;wire [XW-1:0] m_x;wire [YW-1:0] m_y;
    wire [7:0] m_channels;wire [2:0] m_status;wire [FCW-1:0] m_bytes;wire [TAG_W-1:0] m_tag;
    qoi_decoder #(.MAX_WIDTH(MAX_WIDTH),.MAX_HEIGHT(MAX_HEIGHT),.MAX_BYTES(MAX_BYTES),.TAG_W(TAG_W)) dut(.*);
    wire [SW-1:0] source_word={s_byte,s_last,s_tag};
    wire [OW-1:0] output_word={m_rgba,m_x,m_y,m_sof,m_eol,m_last,m_width,m_height,m_channels,m_colorspace,m_status,m_bytes,m_tag};
    reg [SW-1:0] source[0:65535];reg [OW-1:0] expected[0:16383];
    integer lengths[0:255],sizes[0:255],offsets[0:255],out_offsets[0:255],latencies[0:255],fetches[0:255],commits[0:255],indices[0:255],masks[0:255];
    reg [SW-1:0] raw_source;reg [OW-1:0] raw_expected;
    integer raw_length,raw_size,raw_latency,raw_fetches,raw_commits,raw_indices,raw_mask;
    integer fd,scan,f,n,total_source=0,total_expected=0;reg [2047:0] fixture_path;
    integer cycle=0,last_cycle=0,owned_bytes=0,owned_pixels=0,last_capture=-99;
    reg [7:0] file_reference[0:MAX_BYTES-1];reg [31:0] pixel_reference[0:P-1],index_reference[0:63];
    reg [63:0] valid_reference=0;
    reg file_pending=0,index_pending=0,pixel_pending=0,index_choice_pending=0,index_was_valid=0;
    reg [7:0] file_expected;reg [31:0] index_expected,pixel_expected,index_choice;
    reg source_stalled=0,sink_stalled=0;reg [SW-1:0] held_source;reg [OW-1:0] held_output;
    integer live_fetches=0,live_commits=0,live_indices=0,live_oreads=0,live_mask=0;
    integer all_index_checks=0,all_hash_checks=0,all_file_checks=0,all_pixel_checks=0;
    integer main_fetches=0,main_commits=0,main_indices=0,main_outputs=0,main_pixels=0,queued=0;
    integer resets=0,fresh=0,source_hold=0,output_hold=0,ii1=0,max_latency=0;
    reg [17:0] states=0;reg [5:0] operations=0;
    integer slot,family;
    always @(posedge clk)begin
        cycle=cycle+1;
        if(rst)begin
            source_stalled=0;sink_stalled=0;file_pending=0;index_pending=0;pixel_pending=0;index_choice_pending=0;
            valid_reference=0;owned_bytes=0;owned_pixels=0;last_capture=-99;
            live_fetches=0;live_commits=0;live_indices=0;live_oreads=0;live_mask=0;
        end else begin
            states[dut.state]=1;
            if(source_stalled && (!s_valid || source_word!==held_source))$fatal(1,"source changed before actual acceptance");
            if(sink_stalled && (!m_valid || output_word!==held_output))$fatal(1,"complete held output changed");
            source_stalled=s_valid && !s_ready;held_source=source_word;
            sink_stalled=m_valid && !m_ready;held_output=output_word;
            if(source_stalled)source_hold=source_hold+1;if(sink_stalled)output_hold=output_hold+1;
            if(dut.index_valid!==valid_reference)$fatal(1,"index validity ownership");
            if(s_valid && s_ready)begin
                if(!dut.started)begin
                    owned_bytes=0;owned_pixels=0;valid_reference=0;
                    live_fetches=0;live_commits=0;live_indices=0;live_oreads=0;live_mask=0;
                end
                if(owned_bytes<MAX_BYTES)begin file_reference[owned_bytes]=s_byte;owned_bytes=owned_bytes+1;end
                if(last_capture==cycle-1)ii1=ii1+1;last_capture=cycle;
                if(s_last)last_cycle=cycle;
            end
            if(file_pending)begin if(dut.file_q!==file_expected)$fatal(1,"clocked byte RAM image");file_pending=0;all_file_checks=all_file_checks+1;end
            if(index_pending)begin
                if(index_was_valid && dut.index_q!==index_expected)$fatal(1,"clocked owned index RAM image");
                index_pending=0;all_index_checks=all_index_checks+1;
            end
            if(pixel_pending)begin if(dut.pixel_q!==pixel_expected)$fatal(1,"clocked pixel RAM image");pixel_pending=0;all_pixel_checks=all_pixel_checks+1;end
            if(dut.state==2 && dut.file_pointer<dut.file_count)begin
                if(dut.file_pointer>=owned_bytes)$fatal(1,"byte read outside current prefix");
                file_expected=file_reference[dut.file_pointer];file_pending=1;
            end
            if(dut.state==3)live_fetches=live_fetches+1;
            if(dut.state==6)begin
                if(dut.byte_value==254)family=4;else if(dut.byte_value==255)family=5;else family=dut.byte_value>>6;
                operations[family]=1;live_mask=live_mask|(1<<family);
            end
            if(dut.state==10)begin
                index_was_valid=valid_reference[dut.index_address];
                index_expected=index_reference[dut.index_address];index_choice=index_was_valid?index_expected:32'b0;
                index_pending=1;index_choice_pending=1;live_indices=live_indices+1;
            end
            if(dut.state==12)begin
                if(index_choice_pending)begin if(dut.previous_pixel!==index_choice)$fatal(1,"initial transparent/index-hit selection");index_choice_pending=0;end
                if(dut.decoded_count!=owned_pixels || dut.decoded_count>=P || dut.decoded_count>=dut.total_pixels)$fatal(1,"pixel RAM fresh sequential ownership");
                slot=(dut.previous_pixel[31:24]*3+dut.previous_pixel[23:16]*5+dut.previous_pixel[15:8]*7+dut.previous_pixel[7:0]*11)%64;
                if(dut.color_hash[5:0]!=slot)$fatal(1,"full arithmetic color hash reference");
                index_reference[slot]=dut.previous_pixel;valid_reference[slot]=1;
                pixel_reference[owned_pixels]=dut.previous_pixel;owned_pixels=owned_pixels+1;
                live_commits=live_commits+1;all_hash_checks=all_hash_checks+1;
            end
            if(dut.state==15)begin
                if(dut.output_index>=owned_pixels)$fatal(1,"pixel replay outside current decoded prefix");
                pixel_expected=pixel_reference[dut.output_index];pixel_pending=1;live_oreads=live_oreads+1;
            end
            if(m_valid && s_ready)$fatal(1,"overlapped file ownership");
            if(m_valid && m_status==0 && (dut.file_pointer!=dut.file_count || dut.decoded_count!=dut.total_pixels || live_fetches!=dut.file_count))$fatal(1,"pixels escaped before whole-file validation");
        end
        if(cycle>5000000)$fatal(1,"finite total watchdog");
    end
    task drive;input [SW-1:0] word;begin {s_byte,s_last,s_tag}=word;s_valid=1;end endtask
    task beat;input integer byte_in,last_in;input [TAG_W-1:0] tag_in;
        begin
            s_byte=byte_in;s_last=last_in;s_tag=tag_in;s_valid=1;
            if(!s_ready)$fatal(1,"analytic capture blocked");
            @(posedge clk);#1;@(negedge clk);
        end
    endtask
    task wait_output;
        integer guard;
        begin
            guard=0;
            if(!m_valid)begin
                while(!m_valid)begin @(posedge clk);#1;guard=guard+1;if(guard>BOUND)$fatal(1,"first-valid work bound");end
                @(negedge clk);
            end
        end
    endtask
    task retire;
        begin m_ready=1;@(posedge clk);#1;@(negedge clk);m_ready=0;end
    endtask
    reg [7:0] probe[0:2047];integer probe_length;
    task make_probe;input integer kind;
        integer a,left,run,w,h;
        begin
            w=(kind==4)?2:(kind==5)?MAX_WIDTH:(kind==7)?3:1;
            h=(kind==5)?MAX_HEIGHT:(kind==7)?2:1;
            probe[0]=(kind==6)?8'h78:8'h71;probe[1]=8'h6f;probe[2]=8'h69;probe[3]=8'h66;
            probe[4]=0;probe[5]=0;probe[6]=0;probe[7]=w;probe[8]=0;probe[9]=0;probe[10]=0;probe[11]=h;
            probe[12]=4;probe[13]=1;a=14;
            case(kind)
                1:begin probe[a]=254;probe[a+1]=17;probe[a+2]=34;probe[a+3]=51;a=a+4;end
                2:begin probe[a]=128;probe[a+1]=0;a=a+2;end
                3:begin probe[a]=0;a=a+1;end
                4:begin probe[a]=254;probe[a+1]=1;probe[a+2]=2;probe[a+3]=3;probe[a+4]=23;a=a+5;end
                5:begin
                    left=P;while(left!=0)begin run=(left>62)?62:left;probe[a]=192+run-1;a=a+1;left=left-run;end
                end
                7:begin
                    probe[a]=255;probe[a+1]=0;probe[a+2]=0;probe[a+3]=0;probe[a+4]=0;
                    probe[a+5]=255;probe[a+6]=64;probe[a+7]=0;probe[a+8]=0;probe[a+9]=0;
                    probe[a+10]=0;probe[a+11]=63;probe[a+12]=0;probe[a+13]=254;
                    probe[a+14]=1;probe[a+15]=2;probe[a+16]=3;a=a+17;
                end
                default:begin probe[a]=255;probe[a+1]=17;probe[a+2]=34;probe[a+3]=51;probe[a+4]=68;a=a+5;end
            endcase
            for(left=0;left<7;left=left+1)begin probe[a]=0;a=a+1;end
            probe[a]=1;probe_length=a+1;
        end
    endtask
    task send_probe;input [TAG_W-1:0] tag_in;integer a;
        begin for(a=0;a<probe_length;a=a+1)beat(probe[a],a+1==probe_length,(a==0)?tag_in:{TAG_W{1'b0}});end
    endtask
    task full_fresh;
        reg [OW-1:0] held;
        begin
            make_probe(0);send_probe({TAG_W{1'b1}});s_valid=0;wait_output();
            if(m_rgba!==32'h11223344 || m_x!=0 || m_y!=0 || !m_sof || !m_eol || !m_last ||
               m_width!=1 || m_height!=1 || m_channels!=4 || !m_colorspace || m_status!=0 || m_bytes!=27 || m_tag!=={TAG_W{1'b1}} ||
               cycle-last_cycle!=87 || live_fetches!=27 || live_commits!=1 || live_indices!=0 || live_oreads!=1 || live_mask!=32)$fatal(1,"complete fresh RGBA file/metadata/work");
            held=output_word;repeat(3)begin @(posedge clk);#1;@(negedge clk);if(!m_valid || output_word!==held)$fatal(1,"fresh output hold");end
            retire();s_valid=0;
            repeat(2)begin @(posedge clk);#1;@(negedge clk);if(m_valid || !s_ready)$fatal(1,"stale postfresh output");end
            fresh=fresh+1;
        end
    endtask
    function included;input integer id;
        begin included=(!(id==35 || id==36 || id==40) || P>=2) && (!(id>=37 && id<=39) || P>=62) && (id!=41 || P>=6);end
    endfunction
    function target_seen;input integer id;
        begin
            if(id<18)target_seen=dut.state==id;
            else case(id)
                18:target_seen=dut.state==0 && !dut.started;
                19:target_seen=dut.state==0 && dut.file_count==MAX_BYTES && !dut.overflow;
                20:target_seen=dut.state==0 && dut.overflow;
                21:target_seen=dut.state==4 && dut.header_position==13;
                22,23:target_seen=dut.state==7 && dut.literal_position==id-21;
                24,25,26:target_seen=dut.state==8 && dut.literal_position==id-23;
                27:target_seen=dut.state==13 && dut.tail_position==7;
                28:target_seen=m_valid && m_status==2;
                29:target_seen=dut.state==2 && dut.return_state==6;
                30:target_seen=dut.state==2 && dut.return_state==7;
                31:target_seen=dut.state==2 && dut.return_state==8;
                32:target_seen=dut.state==2 && dut.return_state==9;
                33:target_seen=dut.state==2 && dut.return_state==13;
                34:target_seen=dut.state==3 && dut.return_state==6;
                35:target_seen=dut.state==10 && dut.index_valid[dut.index_address];
                36:target_seen=dut.state==11 && dut.index_valid[dut.index_address];
                37:target_seen=dut.state==12 && dut.run_remaining==61;
                38:target_seen=dut.state==12 && dut.run_remaining==30;
                39:target_seen=dut.state==12 && dut.run_remaining==0 && dut.decoded_count==61;
                40:target_seen=m_valid && m_last;
                41:target_seen=dut.state==12 && dut.decoded_count==2;
                default:target_seen=0;
            endcase
        end
    endfunction
    task abort_target;input integer id;
        integer kind,a,guard;
        begin
            if(id==0)beat(113,0,1);
            else if(id==18)begin s_valid=0;end
            else if(id==19 || id==20)begin for(a=0;a<MAX_BYTES+(id==20);a=a+1)beat(a,0,1);end
            else begin
                kind=0;
                if(id==7 || id==22 || id==23 || id==30)kind=1;
                if(id==9 || id==32)kind=2;
                if(id==10 || id==11)kind=3;
                if(id==35 || id==36 || id==40)kind=4;
                if(id>=37 && id<=39)kind=5;
                if(id==28)kind=6;
                if(id==41)kind=7;
                make_probe(kind);send_probe(1);
            end
            s_valid=1;s_byte=113;s_last=0;s_tag={TAG_W{1'b1}};
            if(id==40)begin wait_output();retire();end
            guard=0;
            while(!target_seen(id))begin @(negedge clk);guard=guard+1;if(guard>BOUND)$fatal(1,"unreachable reset target %0d",id);end
            rst=1;#1;if(s_ready || m_valid)$fatal(1,"immediate reset gates");
            @(posedge clk);#1;
            if(output_word!==0 || dut.state!=0 || dut.started || dut.overflow || dut.index_valid!=0)$fatal(1,"canonical reset record/ownership");
            @(negedge clk);s_valid=0;rst=0;#1;resets=resets+1;full_fresh();
        end
    endtask
    task send_remaining;input integer frame_id,start;
        integer a;
        begin
            for(a=start;a<lengths[frame_id];a=a+1)begin
                if(a!=0 && (a+frame_id)%7==0)begin s_valid=0;@(posedge clk);#1;@(negedge clk);end
                drive(source[offsets[frame_id]+a]);if(!s_ready)$fatal(1,"capture II1 admission");
                @(posedge clk);#1;@(negedge clk);
            end
        end
    endtask
    integer id,k,latency;
    initial begin
        if(!$value$plusargs("FIXTURE=%s",fixture_path))$fatal(1,"fixture absent");fd=$fopen(fixture_path,"r");if(!fd)$fatal(1,"fixture open");
        // Scalar fscanf temporaries only; no dynamic memory lvalue loader.
        for(f=0;f<FRAMES;f=f+1)begin
            scan=$fscanf(fd,"%d %d %d %d %d %d %h\n",raw_length,raw_size,raw_latency,raw_fetches,raw_commits,raw_indices,raw_mask);
            if(scan!=7 || raw_length<1 || raw_size<1 || total_source+raw_length>65536 || total_expected+raw_size>16384)$fatal(1,"fixture header");
            lengths[f]=raw_length;sizes[f]=raw_size;offsets[f]=total_source;out_offsets[f]=total_expected;
            latencies[f]=raw_latency;fetches[f]=raw_fetches;commits[f]=raw_commits;indices[f]=raw_indices;masks[f]=raw_mask;
            for(n=0;n<raw_length;n=n+1)begin scan=$fscanf(fd,"%h\n",raw_source);if(scan!=1)$fatal(1,"fixture byte");source[total_source]=raw_source;total_source=total_source+1;end
            for(n=0;n<raw_size;n=n+1)begin scan=$fscanf(fd,"%h\n",raw_expected);if(scan!=1)$fatal(1,"fixture pixel");expected[total_expected]=raw_expected;total_expected=total_expected+1;end
        end
        $fclose(fd);repeat(2)@(negedge clk);rst=0;#1;
        for(id=0;id<42;id=id+1)if(included(id))abort_target(id);
        if(resets!=RESETS || fresh!=RESETS)$fatal(1,"frozen reset/fresh counts");
        for(f=0;f<FRAMES;f=f+1)begin
            send_remaining(f,(f==0)?0:1);
            if(f+1<FRAMES)drive(source[offsets[f+1]]);else s_valid=0;
            wait_output();latency=cycle-last_cycle;
            if(latency!=latencies[f] || live_fetches!=fetches[f] || live_commits!=commits[f] || live_indices!=indices[f] || live_mask!=masks[f] || live_oreads!=(m_status==0))begin
                $display("work frame=%0d latency=%0d/%0d fetch=%0d/%0d commit=%0d/%0d index=%0d/%0d mask=%h/%h oreads=%0d",f,latency,latencies[f],live_fetches,fetches[f],live_commits,commits[f],live_indices,indices[f],live_mask,masks[f],live_oreads);$fatal(1,"exact finite work");
            end
            main_fetches=main_fetches+live_fetches;main_commits=main_commits+live_commits;main_indices=main_indices+live_indices;
            if(latency>max_latency)max_latency=latency;
            for(k=0;k<sizes[f];k=k+1)begin
                if(k!=0)wait_output();
                if(output_word!==expected[out_offsets[f]+k])begin $display("frame=%0d pixel=%0d expected=%h actual=%h",f,k,expected[out_offsets[f]+k],output_word);$fatal(1,"original pixel/strict error oracle");end
                main_outputs=main_outputs+1;if(m_status==0)main_pixels=main_pixels+1;
                repeat(2+(k+f)%2)begin @(posedge clk);#1;@(negedge clk);end
                retire();
            end
            if(m_valid || !s_ready)$fatal(1,"complete file retirement");
            if(f+1<FRAMES)begin
                if(source_word!==source[offsets[f+1]] || !s_valid)$fatal(1,"actual next byte lost");
                @(posedge clk);#1;@(negedge clk);queued=queued+1;if(!dut.started)$fatal(1,"queued byte not actually accepted");
            end
        end
        s_valid=0;repeat(3)begin @(posedge clk);#1;@(negedge clk);if(m_valid)$fatal(1,"extra output");end
        if(queued!=FRAMES-1 || states!=18'h3ffff || operations!=6'h3f || source_hold==0 || output_hold==0 || ii1==0)$fatal(1,"coverage population");
        $display("PASS W=%0d H=%0d B=%0d T=%0d frames=%0d input_bytes=%0d outputs=%0d pixels=%0d queued=%0d resets=%0d fresh=%0d fetches=%0d commits=%0d index_reads=%0d file_checks=%0d index_checks=%0d pixel_checks=%0d hash_checks=%0d source_hold=%0d output_hold=%0d ii1=%0d max_latency=%0d states=%h operations=%h",
            MAX_WIDTH,MAX_HEIGHT,MAX_BYTES,TAG_W,FRAMES,total_source,main_outputs,main_pixels,queued,resets,fresh,main_fetches,main_commits,main_indices,all_file_checks,all_index_checks,all_pixel_checks,all_hash_checks,source_hold,output_hold,ii1,max_latency,states,operations);
        $finish;
    end
endmodule
