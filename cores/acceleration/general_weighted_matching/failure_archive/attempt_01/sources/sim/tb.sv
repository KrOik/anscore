// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb;
    parameter integer N=8,W=16,T=8;
    localparam integer IW=(N>1?$clog2(N):1),CW=$clog2(N+1);
    localparam integer SB=W-1+((N/2>1)?$clog2(N/2):0),SW=(SB>0?SB:1);
    localparam integer BOUND=(4*N+5)*((1<<N)-1)+2*N+4;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,s_valid=0,m_ready=0;
    wire s_ready,m_valid,m_keep,m_last,m_matched;
    reg [31:0] s_from=0,s_to=0;
    reg signed [W-1:0] s_weight=0;
    reg s_present=0,s_keep=0,s_last=0;
    reg [T-1:0] s_tag=0;
    wire [1:0] m_error;
    wire [T-1:0] m_tag;
    wire [IW-1:0] m_node,m_partner;
    wire [CW-1:0] m_cardinality;
    wire [SW-1:0] m_total_weight;
    general_weighted_matching #(.NUM_NODES(N),.WEIGHT_W(W),.TAG_W(T)) dut(.*);
    localparam integer OW=2+2+T+2*IW+1+CW+SW;
    wire [OW-1:0] payload={m_keep,m_last,m_error,m_tag,m_node,m_partner,
                              m_matched,m_cardinality,m_total_weight};
    reg previous_stall=0;reg [OW-1:0] previous_payload;
    reg source_stall=0;reg [2*32+W+3+T-1:0] previous_source;
    wire [2*32+W+3+T-1:0] source_payload={s_from,s_to,s_weight,s_present,s_keep,s_last,s_tag};
    integer cycles=0,accepted=0,retired=0,held=0,source_holds=0;
    integer frames=0,resets=0,reset_offers=0,next_offers=0;
    always @(posedge clk)begin
        cycles=cycles+1;
        if(!rst && previous_stall && (!m_valid || payload!==previous_payload))$fatal(1,"unstable output");
        if(!rst && source_stall && (!s_valid || source_payload!==previous_source))$fatal(1,"unstable source offer");
        previous_stall<=!rst && m_valid && !m_ready;previous_payload<=payload;
        source_stall<=!rst && s_valid && !s_ready;previous_source<=source_payload;
        if(!rst && s_valid && s_ready)accepted=accepted+1;
        if(!rst && m_valid && m_ready)retired=retired+1;
        if(!rst && m_valid && !m_ready)held=held+1;
        if(!rst && s_valid && !s_ready)source_holds=source_holds+1;
        if(rst && s_valid)begin
            reset_offers=reset_offers+1;
            if(s_ready || m_valid)$fatal(1,"reset transfer");
        end
    end
    integer profile,mode,fd,rc,count,case_id,ntokens,ex_error,ex_card;
    reg [31:0] ex_tag;
    reg [63:0] ex_total;
    integer mates[0:N-1];
    reg [31:0] u[0:255],v[0:255],tags[0:255];
    reg signed [31:0] weight[0:255];
    integer present[0:255],keep[0:255],last[0:255];
    string filename;
    task read_case(input integer file_id);
        integer i;
        begin
            rc=$fscanf(file_id,"%d %d %d %d %d %d",case_id,ntokens,ex_error,ex_tag,ex_total,ex_card);
            if(rc!=6 || ntokens<1 || ntokens>256)$fatal(1,"fixture header");
            for(i=0;i<N;i=i+1)begin rc=$fscanf(file_id,"%d",mates[i]);if(rc!=1)$fatal(1,"mate fixture");end
            for(i=0;i<ntokens;i=i+1)begin
                rc=$fscanf(file_id,"%d %d %d %d %d %d %d",u[i],v[i],weight[i],present[i],keep[i],last[i],tags[i]);
                if(rc!=7)$fatal(1,"token fixture");
            end
        end
    endtask
    task load_single(input string suffix);
        integer f,c;
        begin
            f=$fopen($sformatf("fixtures/p%0d.%s",profile,suffix),"r");
            if(!f)$fatal(1,"missing single fixture");rc=$fscanf(f,"%d",c);
            if(rc!=1 || c!=1)$fatal(1,"single fixture count");read_case(f);$fclose(f);
        end
    endtask
    task set_token(input integer i);
        begin
            s_from=u[i];s_to=v[i];s_weight=weight[i];s_present=present[i];
            s_keep=keep[i];s_last=last[i];s_tag=tags[i];s_valid=1;
        end
    endtask
    task offer_next(input reg [31:0] next_tag);
        begin
            s_from=32'hffffffff;s_to=32'h80000000;s_weight=-1;
            s_present=1;s_keep=0;s_last=0;s_tag=next_tag;s_valid=1;
        end
    endtask
    integer tail_cycle;
    task send_tokens(input integer limit,input integer preoffered);
        integer i,guard;
        begin
            for(i=0;i<limit;i=i+1)begin
                if(!(i==0 && preoffered))begin
                    s_valid=0;
                    if(i%3==1)repeat(2)@(negedge clk);
                    @(negedge clk);set_token(i);
                end else begin
                    if(source_payload!=={u[0],v[0],W'(weight[0]),1'(present[0]),1'(keep[0]),1'(last[0]),T'(tags[0])})$fatal(1,"prefetched first token changed");
                end
                guard=0;
                begin : wait_accept
                    forever begin
                        @(posedge clk);guard=guard+1;
                        if(s_ready)begin if(last[i])tail_cycle=cycles;disable wait_accept;end
                        if(guard>N*N+8)$fatal(1,"input readiness bound");
                    end
                end
                @(negedge clk);s_valid=0;
            end
        end
    endtask
    task take_row(input integer row,input integer phase,input integer is_prefix);
        integer guard;
        begin
            guard=0;m_ready=0;
            while(!m_valid)begin
                @(negedge clk);guard=guard+1;
                if(guard>BOUND+8)$fatal(1,"first valid timeout");
            end
            if(row==0 && cycles-tail_cycle>BOUND)$fatal(1,"first valid bound");
            if(m_error!==2'(ex_error) || m_keep!==(ex_error==0) || m_last!==(ex_error!=0 || row==N-1) || m_tag!==T'(ex_tag))$fatal(1,"record framing/tag");
            if(m_total_weight!==SW'(ex_total) || m_cardinality!==CW'(ex_card))$fatal(1,"objective");
            if(ex_error)begin
                if(m_node!==0 || m_partner!==0 || m_matched!==0)$fatal(1,"error payload");
            end else begin
                if(m_node!==IW'(row) || m_matched!==(mates[row]>=0) || m_partner!==IW'(mates[row]>=0?mates[row]:0))$fatal(1,"mate row");
            end
            repeat(3)@(negedge clk);
            m_ready=1;@(posedge clk);
            if(is_prefix)$display("PREFIX phase=%0d frame=%0d row=%0d keep=%0d last=%0d error=%0d tag=%0d node=%0d matched=%0d partner=%0d cardinality=%0d total=%0d",phase,case_id,row,m_keep,m_last,m_error,m_tag,m_node,m_matched,m_partner,m_cardinality,m_total_weight);
            else $display("REC phase=%0d frame=%0d row=%0d keep=%0d last=%0d error=%0d tag=%0d node=%0d matched=%0d partner=%0d cardinality=%0d total=%0d",phase,case_id,row,m_keep,m_last,m_error,m_tag,m_node,m_matched,m_partner,m_cardinality,m_total_weight);
            @(negedge clk);m_ready=0;
        end
    endtask
    task complete_frame(input integer phase);
        integer i;
        begin for(i=0;i<(ex_error?1:N);i=i+1)take_row(i,phase,0);frames=frames+1;end
    endtask
    function automatic integer condition(input integer probe);
        begin
            case(probe)
                0:condition=dut.state==0 && dut.init_address==N*N/2;
                1:condition=dut.state==1;
                3,4,5:condition=dut.state==probe && dut.mask>=2;
                6:condition=dut.state==6 && dut.partner_scan<N && dut.mask[dut.partner_scan];
                8:condition=dut.state==8 && dut.edge_positive;
                10:condition=dut.state==10 && dut.mask==(profile==4?1024:2);
                12:condition=dut.state==12 && dut.mask!=0;
                13:condition=dut.state==13 && dut.trace_choice!=0;
                14:condition=m_valid && dut.state==14 && m_node==0 && !m_ready;
                15:condition=m_valid && dut.state==15 && !m_ready;
                16:condition=m_valid && dut.state==14 && m_node==N-1 && !m_ready;
                default:condition=dut.state==probe;
            endcase
        end
    endfunction
    task reset_high(input integer offers);
        integer i;
        begin
            rst=1;m_ready=1;
            if(offers)offer_next(32'hffffffff);else s_valid=0;
            for(i=0;i<3;i=i+1)begin @(posedge clk);#1;if(s_ready || m_valid)$fatal(1,"reset high");@(negedge clk);end
            rst=0;s_valid=0;m_ready=0;
        end
    endtask
    integer i,j,probe_file,probe_count,probe,guard,start_accepted,prefix;
    initial begin
        if(!$value$plusargs("PROFILE=%d",profile) || !$value$plusargs("MODE=%d",mode))$fatal(1,"arguments");
        @(negedge clk);reset_high(0);
        if(mode==0)begin
            fd=$fopen($sformatf("fixtures/p%0d.txt",profile),"r");if(!fd)$fatal(1,"main fixture");
            rc=$fscanf(fd,"%d",count);if(rc!=1)$fatal(1,"main count");
            for(i=0;i<count;i=i+1)begin
                read_case(fd);send_tokens(ntokens,i>0);
                if(i+1<count)begin offer_next(32'(((8'ha5+(case_id+1)*97)^(64'd1<<(T-1)))&((64'd1<<T)-1)));next_offers=next_offers+1;end
                complete_frame(-1);
            end
            $fclose(fd);
        end else if(mode==1)begin
            probe_file=$fopen($sformatf("fixtures/p%0d.probes",profile),"r");if(!probe_file)$fatal(1,"probe fixture");
            rc=$fscanf(probe_file,"%d",probe_count);if(rc!=1)$fatal(1,"probe count");
            for(i=0;i<probe_count;i=i+1)begin
                rc=$fscanf(probe_file,"%d",probe);if(rc!=1)$fatal(1,"probe id");
                reset_high(0);start_accepted=accepted;prefix=0;
                if(probe!=0)begin
                    load_single(probe==15?"bad":"fresh");send_tokens(probe==1?1:ntokens,0);
                    if(probe!=1)offer_next(32'h12345678);
                    if(probe==16)begin
                        for(j=0;j<N-1;j=j+1)take_row(j,probe,1);
                        prefix=N-1;
                    end
                end
                guard=0;
                while(!condition(probe))begin
                    @(negedge clk);guard=guard+1;
                    if(guard>BOUND+N*N+8)$fatal(1,"actual reset predicate timeout probe=%0d state=%0d",probe,dut.state);
                end
                $display("OBS probe=%0d state=%0d mask=%0d scan=%0d address=%0d choice=%0d edge_positive=%0d prefix=%0d accepted=%0d",probe,dut.state,dut.mask,dut.partner_scan,dut.init_address,dut.trace_choice,dut.edge_positive,prefix,accepted-start_accepted);
                // Already at a falling edge: no intervening active edge.
                reset_high(1);resets=resets+1;
                load_single("fresh");send_tokens(ntokens,0);complete_frame(probe);
            end
            $fclose(probe_file);
        end else $fatal(1,"mode");
        $display("PASS profile=%0d mode=%0d N=%0d W=%0d T=%0d frames=%0d accepted=%0d retired=%0d resets=%0d reset_offers=%0d next=%0d held=%0d source_holds=%0d cycles=%0d",profile,mode,N,W,T,frames,accepted,retired,resets,reset_offers,next_offers,held,source_holds,cycles);
        $finish;
    end
    initial begin repeat(50000000)@(posedge clk);$fatal(1,"absolute finite watchdog");end
endmodule
