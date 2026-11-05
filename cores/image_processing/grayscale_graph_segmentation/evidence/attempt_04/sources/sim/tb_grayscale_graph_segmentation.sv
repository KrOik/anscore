// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_grayscale_graph_segmentation;
    parameter integer WIDTH=16,HEIGHT=16,TAG_W=8;
    localparam integer N=WIDTH*HEIGHT;
    localparam integer IW=(N<2)?1:$clog2(N);
    localparam integer CW=(N<2)?1:$clog2(N+1);
    localparam integer PACK_W=8+2*IW+2*CW+TAG_W;
    localparam integer INPUT_PACK_W=27+CW+TAG_W;
    reg clk=0,rst=1;
    always #5 clk=~clk;
    reg s_valid=0,s_sof=0,s_eol=0,s_last=0;
    reg [7:0] s_pixel=0;
    reg [15:0] s_k=0;
    reg [CW-1:0] s_min_size=0;
    reg [TAG_W-1:0] s_tag=0;
    wire s_ready,m_valid,m_keep,m_sof,m_eol,m_last;
    reg m_ready=0;
    wire [IW-1:0] m_index,m_label;
    wire [CW-1:0] m_area,m_regions;
    wire [3:0] m_errors;
    wire [TAG_W-1:0] m_tag;
    grayscale_graph_segmentation #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.TAG_W(TAG_W)) dut (
        .clk(clk),.rst(rst),.s_valid(s_valid),.s_ready(s_ready),.s_pixel(s_pixel),
        .s_sof(s_sof),.s_eol(s_eol),.s_last(s_last),.s_k(s_k),.s_min_size(s_min_size),.s_tag(s_tag),
        .m_valid(m_valid),.m_ready(m_ready),.m_keep(m_keep),.m_index(m_index),.m_label(m_label),
        .m_area(m_area),.m_regions(m_regions),.m_sof(m_sof),.m_eol(m_eol),.m_last(m_last),
        .m_errors(m_errors),.m_tag(m_tag));

    integer pixels[0:N-1],markers[0:N-1][0:2],expected[0:N-1][0:9];
    integer frame_id,fk,fmin,nout,ferrors;
    reg [31:0] ftag;
    integer received=0,cycle=0,log_id=0,total_records=0,total_aborted=0;
    integer stall_mode=0,force_hold=0,monitor_active=0,old_owner=0;
    integer sent=0;
    integer edge_seen_count=0,previous_weight=0,previous_source=0,previous_direction=0,first_weight=0;
    integer sort_source,sort_target,sort_direction,sort_weight,z;
    reg edge_seen[0:2*N-1];
    reg held_output=0,held_input=0;
    reg [PACK_W-1:0] old_output;
    reg [INPUT_PACK_W-1:0] old_input;
    wire [PACK_W-1:0] packed_output={m_keep,m_index,m_label,m_area,m_regions,
        m_sof,m_eol,m_last,m_errors,m_tag};
    wire [INPUT_PACK_W-1:0] packed_input={s_pixel,s_sof,s_eol,s_last,s_k,s_min_size,s_tag};
    string profile,mode;

    always @(negedge clk) begin
        if(rst || force_hold) m_ready=0;
        else m_ready=(stall_mode==0 || ((cycle%13)!=3 && (cycle%13)!=4 && (cycle%13)!=5));
    end
    always @(posedge clk) begin
        cycle=cycle+1;
        if(cycle>20000000) $fatal(1,"fixed cycle watchdog");
        if(rst) begin
            if(s_ready || m_valid) $fatal(1,"reset transfer gate");
            held_output=0;held_input=0;
        end else begin
            if(held_output && (!m_valid || packed_output!==old_output))
                $fatal(1,"output changed while stalled");
            if(held_input && (!s_valid || packed_input!==old_input))
                $fatal(1,"test source changed a stalled offer");
            held_output=m_valid && !m_ready;
            held_input=s_valid && !s_ready;
            old_output=packed_output;old_input=packed_input;
            if(dut.dsu_m_valid && dut.dsu_m_ready && dut.dsu_m_error)
                $fatal(1,"unexpected backend ID error");
            if(dut.state==dut.EDGE_CAPTURE) begin
                sort_source=$unsigned(dut.edge_q[IW-1:0]);
                sort_direction=dut.edge_q[IW];
                sort_weight=$unsigned(dut.edge_q[IW+1 +: 8]);
                sort_target=sort_source+(sort_direction?WIDTH:1);
                if(dut.edge_cursor==0) begin
                    for(z=0;z<2*N;z=z+1) edge_seen[z]=0;
                    edge_seen_count=0;first_weight=sort_weight;
                end
                if(sort_source>=N || sort_target>=N ||
                   (!sort_direction && sort_source%WIDTH==WIDTH-1) ||
                   (sort_direction && sort_source/WIDTH==HEIGHT-1)) $fatal(1,"invalid graph edge");
                if(edge_seen[2*sort_source+sort_direction]) $fatal(1,"duplicate sorted edge");
                edge_seen[2*sort_source+sort_direction]=1;
                if(sort_weight != ((pixels[sort_source]>pixels[sort_target])?
                    pixels[sort_source]-pixels[sort_target]:pixels[sort_target]-pixels[sort_source]))
                    $fatal(1,"edge weight did not come from actual pixels");
                if(edge_seen_count>0 && (sort_weight<previous_weight ||
                   (sort_weight==previous_weight && sort_source<previous_source) ||
                   (sort_weight==previous_weight && sort_source==previous_source && sort_direction<=previous_direction)))
                    $fatal(1,"unstable graph edge order");
                previous_weight=sort_weight;previous_source=sort_source;previous_direction=sort_direction;
                edge_seen_count=edge_seen_count+1;
                if(dut.edge_cursor==dut.E-1) begin
                    if(edge_seen_count!=dut.E) $fatal(1,"incomplete graph");
                    if(old_owner) $display("ABORTSORT %s %0d %0d %0d %0d %0d",profile,log_id,
                        dut.postprocess,edge_seen_count,first_weight,sort_weight);
                    else $display("SORT %s %0d %0d %0d %0d %0d",profile,log_id,
                        dut.postprocess,edge_seen_count,first_weight,sort_weight);
                end
            end
            if(m_valid && m_ready) begin
                if(!monitor_active || received>=nout) $fatal(1,"unowned or excess output");
                if(m_index!==IW'(expected[received][0]) || m_label!==IW'(expected[received][1]) ||
                   m_area!==CW'(expected[received][2]) || m_regions!==CW'(expected[received][3]) ||
                   m_keep!==1'(expected[received][4]) || m_sof!==1'(expected[received][5]) ||
                   m_eol!==1'(expected[received][6]) || m_last!==1'(expected[received][7]) ||
                   m_errors!==4'(expected[received][8]) || m_tag!==TAG_W'(expected[received][9]))
                    $fatal(1,"tuple mismatch frame=%0d output=%0d got=%h",log_id,received,packed_output);
                if(old_owner) begin
                    $display("ABORTREC %s %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                        profile,log_id,$unsigned(m_index),$unsigned(m_label),$unsigned(m_area),$unsigned(m_regions),
                        m_keep,m_sof,m_eol,m_last,$unsigned(m_errors),$unsigned(m_tag));
                    total_aborted=total_aborted+1;
                end else begin
                    $display("REC %s %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                        profile,log_id,$unsigned(m_index),$unsigned(m_label),$unsigned(m_area),$unsigned(m_regions),
                        m_keep,m_sof,m_eol,m_last,$unsigned(m_errors),$unsigned(m_tag));
                    total_records=total_records+1;
                end
                received=received+1;
            end
        end
    end

    task read_case(input integer fd);
        integer result,i,j;
        integer marker0_tmp,marker1_tmp,marker2_tmp,expected_tmp;
        begin
            result=$fscanf(fd,"%d %d %d %d %d %d",frame_id,fk,fmin,ftag,nout,ferrors);
            if(result!=6 || nout<1 || nout>N) $fatal(1,"fixture header");
            for(i=0;i<N;i=i+1) begin
                result=$fscanf(fd,"%d %d %d %d",pixels[i],marker0_tmp,marker1_tmp,marker2_tmp);
                if(result!=4) $fatal(1,"fixture input");
                markers[i][0]=marker0_tmp;markers[i][1]=marker1_tmp;markers[i][2]=marker2_tmp;
            end
            for(i=0;i<nout;i=i+1) for(j=0;j<10;j=j+1) begin
                result=$fscanf(fd,"%d",expected_tmp);
                if(result!=1) $fatal(1,"fixture expected tuple");
                expected[i][j]=expected_tmp;
            end
            received=0;sent=0;monitor_active=1;
        end
    endtask
    task load_single(input string name);
        integer fd,count,result;
        begin
            fd=$fopen($sformatf("fixtures/%s/%s.txt",profile,name),"r");
            if(!fd) $fatal(1,"missing fixed reset fixture");
            result=$fscanf(fd,"%d",count);
            if(result!=1 || count!=1) $fatal(1,"reset fixture count");
            read_case(fd);$fclose(fd);
        end
    endtask
    task set_pixel(input integer i);
        begin
            s_pixel=8'(pixels[i]);s_sof=1'(markers[i][0]);s_eol=1'(markers[i][1]);s_last=1'(markers[i][2]);
            s_k=(i==0)?16'(fk):(16'(fk)^16'hffff);
            s_min_size=(i==0)?CW'(fmin):{CW{1'b0}};
            s_tag=(i==0)?TAG_W'(ftag):~TAG_W'(ftag);
        end
    endtask
    task send_pixel(input integer i);
        integer done;
        begin
            if(stall_mode && i%5==2) repeat(2) @(negedge clk);
            @(negedge clk);set_pixel(i);s_valid=1;done=0;
            while(!done) begin
                @(posedge clk);
                if(s_ready) begin done=1;sent=sent+1;end
                #1;
            end
            @(negedge clk);s_valid=0;
        end
    endtask
    task send_range(input integer first,input integer limit);
        integer i;
        begin for(i=first;i<limit;i=i+1) send_pixel(i);end
    endtask
    task finish_frame;
        integer guard;
        begin
            guard=0;
            while(received<nout) begin
                @(negedge clk);guard=guard+1;
                if(guard>2000000) $fatal(1,"fixed frame wait watchdog");
            end
            $display("FRAME %s %0d %0d %0d %0d",profile,log_id,nout,ferrors,$unsigned(ftag));
            monitor_active=0;
            // A retired LAST must leave no stale output during source idle.
            repeat(3) begin @(negedge clk);if(m_valid) $fatal(1,"old frame leaked");end
        end
    endtask
    function automatic integer predicate(input string name);
        begin
            if(name=="capture_prefix") predicate=(dut.state==dut.CAPTURE && dut.capture_index>0 && !m_valid);
            else if(name=="clear_wait") predicate=(dut.state==dut.CLEAR_WAIT);
            else if(name=="prefix_sum") predicate=(dut.state==dut.PREFIX_COMMIT);
            else if(name=="scatter_write") predicate=(dut.state==dut.GEN_COMMIT && dut.scatter_pass);
            else if(name=="fh_meta_a") predicate=(dut.state==dut.META_A_CAPTURE && !dut.postprocess);
            else if(name=="fh_test_b") predicate=(dut.state==dut.CHECK_B && !dut.postprocess);
            else if(name=="union_pending") predicate=(dut.state==dut.UNION_WAIT && !dut.dsu_m_valid);
            else if(name=="minimum_pass") predicate=(dut.state==dut.EDGE_READ && dut.postprocess);
            else if(name=="output_held" || name=="next_offer") predicate=(m_valid && !m_ready && received==0);
            else if(name=="output_prefix") predicate=(m_valid && !m_ready && received==1);
            else predicate=0;
        end
    endfunction
    task await_predicate(input string name);
        integer guard;
        begin
            guard=0;
            while(!predicate(name)) begin
                @(negedge clk);guard=guard+1;
                if(guard>2000000) $fatal(1,"fixed predicate absent: %s",name);
            end
        end
    endtask
    task reset_probe(input integer ordinal,input string name);
        integer edge_number,done;
        reg [31:0] fresh_tag;
        begin
            @(negedge clk);old_owner=1;log_id=ordinal;
            force_hold=(name=="output_prefix")?0:1;
            load_single("reset_old");
            if(name=="capture_prefix") send_range(0,1);
            else send_range(0,N);
            if(name=="output_prefix") begin
                while(received<1) @(negedge clk);
                force_hold=1;
            end
            await_predicate(name);
            if((name=="output_prefix" && received!=1) || (name!="output_prefix" && received!=0))
                $fatal(1,"unexpected aborted prefix");
            $display("PROBE %s %0d %s %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",profile,ordinal,name,
                sent,received,dut.state,dut.postprocess,dut.dsu_m_valid,m_valid,m_ready,
                dut.capture_index,dut.scatter_pass,dut.edge_cursor,dut.root_a,dut.root_b,
                $unsigned(dut.product),dut.dsu_m_op,dut.u_dsu.state);
            if(name=="next_offer") begin
                // A real future first pixel is offered while the old owner is held.
                fresh_tag={32{1'b1}}>>(32-TAG_W);
                @(negedge clk);
                s_pixel=7;s_sof=1;s_eol=(WIDTH==1);s_last=(N==1);
                s_k=64;s_min_size=1;s_tag=TAG_W'(fresh_tag);s_valid=1;
                repeat(3) begin
                    @(posedge clk);
                    if(s_ready || !m_valid || m_ready) $fatal(1,"future offer accepted by old owner");
                    #1;
                end
                $display("OFFER %s %0d %0d",profile,ordinal,$unsigned(s_tag));
                @(negedge clk);
            end
            // Assert reset at the very negedge that observed the predicate.
            // next_offer holds that same OUT_HOLD predicate across its offers.
            if(!predicate(name)) $fatal(1,"reset moved away from its named predicate");
            $display("RESETAT %s %0d %0d",profile,ordinal,dut.state);
            rst=1;monitor_active=0;
            if(name!="next_offer") begin
                s_valid=1;s_pixel=211;s_sof=0;s_eol=0;s_last=0;s_k=16'hbeef;s_min_size=0;s_tag=0;
            end
            for(edge_number=0;edge_number<3;edge_number=edge_number+1) begin
                @(posedge clk);
                if(s_ready || m_valid || !s_valid) $fatal(1,"reset-high offer transferred");
                $display("RESETEDGE %s %0d %0d",profile,ordinal,edge_number);
                #1;
            end
            load_single("reset_fresh");old_owner=0;
            @(negedge clk);rst=0;force_hold=0;
            if(name=="next_offer") begin
                done=0;
                while(!done) begin
                    @(posedge clk);
                    if(s_ready) begin
                        if(s_pixel!=pixels[0] || s_tag!=TAG_W'(ftag) || !s_sof)
                            $fatal(1,"future offer payload changed");
                        done=1;sent=1;
                    end
                    #1;
                end
                $display("NEXTHANDSHAKE %s %0d %0d",profile,ordinal,$unsigned(s_tag));
                @(negedge clk);s_valid=0;send_range(1,N);
            end else begin s_valid=0;send_range(0,N);end
            finish_frame;
        end
    endtask

    integer fd,count,result,f,i,probes;
    string probe_names[0:9];
    initial begin
        if(!$value$plusargs("PROFILE=%s",profile) || !$value$plusargs("MODE=%s",mode))
            $fatal(1,"fixed profile/mode required");
        result=$value$plusargs("STALL=%d",stall_mode);
        repeat(3) @(posedge clk);
        @(negedge clk);rst=0;
        if(mode=="main") begin
            fd=$fopen($sformatf("fixtures/%s/vectors.txt",profile),"r");
            if(!fd) $fatal(1,"missing frozen vectors");
            result=$fscanf(fd,"%d",count);
            if(result!=1) $fatal(1,"fixture count");
            for(f=0;f<count;f=f+1) begin
                @(negedge clk);read_case(fd);log_id=f;old_owner=0;force_hold=0;
                send_range(0,N);finish_frame;
            end
            $fclose(fd);
            $display("PASS MAIN profile=%s stall=%0d frames=%0d records=%0d",profile,stall_mode,count,total_records);
        end else if(mode=="reset") begin
            if(N==1) begin
                probes=3;probe_names[0]="clear_wait";probe_names[1]="output_held";probe_names[2]="next_offer";
            end else begin
                probes=10;
                probe_names[0]="capture_prefix";probe_names[1]="prefix_sum";probe_names[2]="scatter_write";
                probe_names[3]="fh_meta_a";probe_names[4]="fh_test_b";probe_names[5]="union_pending";
                probe_names[6]="minimum_pass";probe_names[7]="output_held";probe_names[8]="output_prefix";
                probe_names[9]="next_offer";
            end
            for(i=0;i<probes;i=i+1) reset_probe(i,probe_names[i]);
            $display("PASS RESET profile=%s probes=%0d fresh_records=%0d aborted_records=%0d reset_edges=%0d next_offer=1",
                profile,probes,total_records,total_aborted,3*probes);
        end else $fatal(1,"unknown fixed mode");
        $finish;
    end
endmodule
