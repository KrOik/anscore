`timescale 1ns/1ps
module tb_minimum_area_rectangle;
    parameter COORD_W=8,MAX_POINTS=8,TAG_W=8,FRAMES=1,RESETS=58;
    localparam IW=(MAX_POINTS<2)?1:$clog2(MAX_POINTS),CW=(MAX_POINTS<2)?1:$clog2(MAX_POINTS+1);
    localparam MW=4*COORD_W+4,RW=2*MW,SW=2*COORD_W+2+TAG_W;
    localparam OW=8*MW+6*IW+CW+TAG_W+5;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,s_valid=0,s_keep=0,s_last=0,m_ready=0;
    reg signed [COORD_W-1:0] s_x=0,s_y=0;
    reg [TAG_W-1:0] s_tag=0;
    wire s_ready,m_valid,m_pair_valid;
    wire signed [MW-1:0] m_axis_x,m_axis_y,m_u_min,m_u_max,m_v_min,m_v_max;
    wire [MW-1:0] m_den,m_area_num;
    wire [IW-1:0] m_pair_i,m_pair_j,m_u_min_index,m_u_max_index,m_v_min_index,m_v_max_index;
    wire [1:0] m_dimension,m_status;wire [CW-1:0] m_count;wire [TAG_W-1:0] m_tag;
    minimum_area_rectangle #(.COORD_W(COORD_W),.MAX_POINTS(MAX_POINTS),.TAG_W(TAG_W)) dut(.*);
    wire [SW-1:0] source_word={s_x,s_y,s_keep,s_last,s_tag};
    wire [OW-1:0] output_word={m_axis_x,m_axis_y,m_u_min,m_u_max,m_v_min,m_v_max,m_den,m_area_num,
        m_pair_valid,m_pair_i,m_pair_j,m_u_min_index,m_u_max_index,m_v_min_index,m_v_max_index,
        m_dimension,m_status,m_count,m_tag};
    reg [SW-1:0] beats[0:16383];reg [OW-1:0] expected[0:255];
    integer lengths[0:255],offsets[0:255],exp_products[0:255],exp_reads[0:255],exp_pairs[0:255],exp_latency[0:255];
    reg [OW-1:0] raw_expected;reg [SW-1:0] raw_beat;
    integer raw_length,raw_products,raw_reads,raw_pairs,raw_latency;
    reg [2047:0] fixture_path;integer fd,scan,f,b,total_beats=0;
    integer cycle=0,last_cycle=0,live_products=0,live_steps=0,live_reads=0,live_pairs=0;
    integer main_products=0,main_steps=0,main_reads=0,main_pairs=0,main_beats=0,max_latency=0;
    integer resets=0,fresh=0,queued=0,source_hold=0,output_hold=0,full_products=0,all_steps=0,ii1=0;
    integer owned=0,last_capture=-99;
    reg [2*COORD_W-1:0] point_reference[0:MAX_POINTS-1];
    reg previous_read=0,previous_source_stall=0,previous_sink_stall=0;
    reg [2*COORD_W-1:0] read_reference;
    reg [SW-1:0] previous_source;reg [OW-1:0] previous_output;
    reg signed [RW-1:0] product_reference,wide_a,wide_b;
    integer product_steps=0;
    reg [14:0] states=0;reg [8:0] operations=0;
    always @(posedge clk)begin
        cycle=cycle+1;
        if(rst)begin
            previous_read=0;previous_source_stall=0;previous_sink_stall=0;owned=0;
            live_products=0;live_steps=0;live_reads=0;live_pairs=0;product_steps=0;last_capture=-99;
        end else begin
            states[dut.state]=1;
            if(previous_source_stall && (!s_valid || source_word!==previous_source))$fatal(1,"source changed before real acceptance");
            if(previous_sink_stall && (!m_valid || output_word!==previous_output))$fatal(1,"held complete result changed");
            previous_source_stall=s_valid && !s_ready;previous_source=source_word;
            previous_sink_stall=m_valid && !m_ready;previous_output=output_word;
            if(s_valid && !s_ready)source_hold=source_hold+1;
            if(m_valid && !m_ready)output_hold=output_hold+1;
            if(s_valid && s_ready)begin
                if(!dut.active)begin live_products=0;live_steps=0;live_reads=0;live_pairs=0;owned=0;end
                if(last_capture==cycle-1)ii1=ii1+1;
                last_capture=cycle;
                if(s_keep && owned<MAX_POINTS)begin point_reference[owned]={s_x,s_y};owned=owned+1;end
                if(s_last)last_cycle=cycle;
            end
            if(previous_read && dut.ram_q!==read_reference)$fatal(1,"synchronous RAM returned stale/nonowned point");
            previous_read=0;
            if(dut.state==1 || dut.state==3 || dut.state==5 || dut.state==7)begin
                if(dut.read_address>=owned)$fatal(1,"RAM read outside fresh prefix");
                read_reference=point_reference[dut.read_address];previous_read=1;live_reads=live_reads+1;
            end
            if(dut.state==6)live_pairs=live_pairs+1;
            if(dut.state==9)begin
                wide_a={{MW{dut.operand_a[MW-1]}},dut.operand_a};wide_b={{MW{dut.operand_b[MW-1]}},dut.operand_b};
                product_reference=wide_a*wide_b;product_steps=0;live_products=live_products+1;operations[dut.op]=1;
            end
            if(dut.state==10)begin product_steps=product_steps+1;live_steps=live_steps+1;all_steps=all_steps+1;end
            if(dut.state==11)begin
                if(product_steps!=MW || dut.mul_result!==product_reference)$fatal(1,"complete signed product or fixed step mismatch");
                if(dut.op<=6 && dut.mul_result[RW-1:MW]!=={MW{dut.mul_result[MW-1]}})$fatal(1,"proved MW result overflow");
                full_products=full_products+1;
            end
        end
    end
    task drive_word;input [SW-1:0] word;begin {s_x,s_y,s_keep,s_last,s_tag}=word;s_valid=1;end endtask
    task beat;input integer x,y,keep,last,tag_value;
        begin
            s_x=x;s_y=y;s_keep=keep;s_last=last;s_tag=tag_value;s_valid=1;
            if(!s_ready)$fatal(1,"analytic capture unexpectedly blocked");
            @(posedge clk);#1;@(negedge clk);
        end
    endtask
    task wait_result;
        integer watchdog;
        begin
            watchdog=0;
            if(!m_valid)begin
                while(!m_valid)begin
                    @(posedge clk);#1;watchdog=watchdog+1;
                    if(watchdog>2+(MAX_POINTS*(MAX_POINTS-1)/2)*(6+2*MAX_POINTS+(4*MAX_POINTS+5)*(MW+2)))$fatal(1,"result work bound");
                end
                @(negedge clk);
            end
        end
    endtask
    task retire_held;
        reg [OW-1:0] held;
        begin
            held=output_word;
            repeat(3)begin @(posedge clk);#1;@(negedge clk);if(!m_valid || output_word!==held)$fatal(1,"analytic held record");end
            m_ready=1;@(posedge clk);#1;@(negedge clk);m_ready=0;
            if(m_valid || !s_ready)$fatal(1,"retirement boundary");
        end
    endtask
    task complete_fresh;
        integer latency;
        begin
            if(MAX_POINTS==1)beat(-1,1,1,1,1);
            else begin beat(-1,-1,1,0,1);beat(1,-1,1,0,0);beat(-1,1,1,1,0);end
            s_valid=0;wait_result();latency=cycle-last_cycle;
            if(m_status!=0 || m_tag!=1 || m_pair_i!=0 || m_u_min_index!=0 || m_v_min_index!=0)$fatal(1,"fresh status/tag/indices");
            if(MAX_POINTS==1)begin
                if(m_count!=1 || m_dimension!=0 || m_pair_valid || m_pair_j!=0 || m_u_max_index!=0 || m_v_max_index!=0 ||
                   m_axis_x!=1 || m_axis_y!=0 || m_den!=1 || m_area_num!=0 || m_u_min!=-1 || m_u_max!=-1 || m_v_min!=1 || m_v_max!=1 ||
                   latency!=2 || live_products!=0 || live_steps!=0 || live_reads!=1 || live_pairs!=0)$fatal(1,"full singleton fresh");
            end else begin
                if(m_count!=3 || m_dimension!=2 || !m_pair_valid || m_pair_j!=1 || m_u_max_index!=1 || m_v_max_index!=2 ||
                   m_axis_x!=2 || m_axis_y!=0 || m_den!=4 || m_area_num!=16 || m_u_min!=-2 || m_u_max!=2 || m_v_min!=-2 || m_v_max!=2 ||
                   latency!=38+49*(MW+2) || live_products!=49 || live_steps!=49*MW || live_reads!=16 || live_pairs!=3)$fatal(1,"full analytic triangle fresh");
            end
            retire_held();s_valid=0;
            repeat(2)begin @(posedge clk);#1;@(negedge clk);if(m_valid)$fatal(1,"stale postfresh result");end
            fresh=fresh+1;
        end
    endtask
    task abort_target;input integer target_state,target_op,target_step,capture_keep;
        integer watchdog;
        begin
            if(target_state==0)beat(-1,1,capture_keep,0,1);
            else if(MAX_POINTS==1)beat(-1,1,1,1,1);
            else begin beat(-1,-1,1,0,0);beat(1,-1,1,0,0);beat(-1,1,1,1,0);end
            // A complete next analytic first token is held; reset explicitly cancels it.
            s_x=-1;s_y=(MAX_POINTS==1)?1:-1;s_keep=1;s_last=(MAX_POINTS==1);s_tag=1;s_valid=1;
            watchdog=0;
            while(!(dut.state==target_state && (target_op<0 || dut.op==target_op) && (target_step<0 || dut.mul_step==target_step)))begin
                @(negedge clk);watchdog=watchdog+1;
                if(watchdog>60000)$fatal(1,"unreached immediate reset target state=%0d op=%0d step=%0d",target_state,target_op,target_step);
            end
            // No intervening active edge after the observed target.
            rst=1;#1;if(s_ready || m_valid)$fatal(1,"reset gate");
            @(posedge clk);#1;if(output_word!==0 || dut.state!=0 || dut.active || dut.overflow)$fatal(1,"reset canonical complete record");
            @(negedge clk);s_valid=0;rst=0;#1;resets=resets+1;complete_fresh();
        end
    endtask
    task send_remaining;input integer frame_index,start_index;
        integer n;
        begin
            for(n=start_index;n<lengths[frame_index];n=n+1)begin
                if(n!=0 && (n+frame_index)%7==0)begin s_valid=0;@(posedge clk);#1;@(negedge clk);end
                drive_word(beats[offsets[frame_index]+n]);
                if(!s_ready)$fatal(1,"fixture capture blocked");
                @(posedge clk);#1;@(negedge clk);
            end
        end
    endtask
    integer target,operation,latency;
    initial begin
        if(!$value$plusargs("FIXTURE=%s",fixture_path))$fatal(1,"fixture missing");
        fd=$fopen(fixture_path,"r");if(!fd)$fatal(1,"fixture open");
        // All fscanf destinations are scalar temporaries, never dynamic memory lvalues.
        for(f=0;f<FRAMES;f=f+1)begin
            scan=$fscanf(fd,"%d %h %d %d %d %d\n",raw_length,raw_expected,raw_products,raw_reads,raw_pairs,raw_latency);
            if(scan!=6 || raw_length<1 || total_beats+raw_length>16384)$fatal(1,"fixture header");
            lengths[f]=raw_length;offsets[f]=total_beats;expected[f]=raw_expected;
            exp_products[f]=raw_products;exp_reads[f]=raw_reads;exp_pairs[f]=raw_pairs;exp_latency[f]=raw_latency;
            for(b=0;b<raw_length;b=b+1)begin
                scan=$fscanf(fd,"%h\n",raw_beat);if(scan!=1)$fatal(1,"fixture token");
                beats[total_beats]=raw_beat;total_beats=total_beats+1;
            end
        end
        $fclose(fd);
        repeat(2)@(negedge clk);rst=0;#1;
        abort_target(0,-1,-1,0);abort_target(0,-1,-1,1);
        abort_target(1,-1,-1,0);abort_target(2,-1,-1,0);
        if(MAX_POINTS>1)begin
            for(target=3;target<=8;target=target+1)abort_target(target,-1,-1,0);
            for(operation=0;operation<=8;operation=operation+1)begin
                abort_target(9,operation,-1,0);
                abort_target(10,operation,0,0);abort_target(10,operation,MW/2,0);abort_target(10,operation,MW-1,0);
                abort_target(11,operation,-1,0);
            end
            abort_target(12,-1,-1,0);abort_target(13,-1,-1,0);
        end
        abort_target(14,-1,-1,0);
        if(resets!=RESETS || fresh!=RESETS)$fatal(1,"reset matrix count");
        for(f=0;f<FRAMES;f=f+1)begin
            send_remaining(f,(f==0)?0:1);
            if(f+1<FRAMES)drive_word(beats[offsets[f+1]]);else s_valid=0;
            wait_result();latency=cycle-last_cycle;
            if(output_word!==expected[f])begin
                $display("frame=%0d expected=%h actual=%h",f,expected[f],output_word);$fatal(1,"independent hull oracle fields");
            end
            if(live_products!=exp_products[f] || live_steps!=exp_products[f]*MW || live_reads!=exp_reads[f] ||
               live_pairs!=exp_pairs[f] || latency!=exp_latency[f])begin
                $display("work frame=%0d products=%0d/%0d reads=%0d/%0d pairs=%0d/%0d latency=%0d/%0d",f,
                    live_products,exp_products[f],live_reads,exp_reads[f],live_pairs,exp_pairs[f],latency,exp_latency[f]);$fatal(1,"exact work/tail");
            end
            main_products=main_products+live_products;main_steps=main_steps+live_steps;main_reads=main_reads+live_reads;main_pairs=main_pairs+live_pairs;
            main_beats=main_beats+lengths[f];if(latency>max_latency)max_latency=latency;
            retire_held();
            if(f+1<FRAMES)begin
                if(source_word!==beats[offsets[f+1]] || !s_valid)$fatal(1,"actual queued source lost");
                @(posedge clk);#1;@(negedge clk);queued=queued+1;
                if(!dut.active)$fatal(1,"actual queued first token was not accepted");
            end
        end
        s_valid=0;repeat(3)begin @(posedge clk);#1;@(negedge clk);if(m_valid)$fatal(1,"extra result");end
        if(queued!=FRAMES-1 || source_hold==0 || output_hold==0 || ii1==0)$fatal(1,"protocol coverage");
        if(MAX_POINTS>1 && (states!=15'h7fff || operations!=9'h1ff))$fatal(1,"state/operation coverage");
        $display("PASS W=%0d M=%0d T=%0d frames=%0d beats=%0d queued=%0d resets=%0d fresh=%0d products=%0d steps=%0d reads=%0d pairs=%0d full_products=%0d all_steps=%0d source_hold=%0d output_hold=%0d ii1=%0d max_latency=%0d states=%h operations=%h",
            COORD_W,MAX_POINTS,TAG_W,FRAMES,main_beats,queued,resets,fresh,main_products,main_steps,main_reads,main_pairs,
            full_products,all_steps,source_hold,output_hold,ii1,max_latency,states,operations);
        $finish;
    end
endmodule
