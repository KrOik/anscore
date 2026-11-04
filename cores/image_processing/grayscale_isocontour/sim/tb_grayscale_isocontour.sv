`timescale 1ns/1ps
module tb_grayscale_isocontour;
    parameter integer W=16,H=16,G=8,T=8,NUM_INPUTS=1,NUM_OUTPUTS=1,NUM_BLOCKS=1,CYCLE_LIMIT=1000000;
    localparam N=W*H,XW=(W<2)?1:$clog2(W),YW=(H<2)?1:$clog2(H),
        SW=(2*(W-1)*(H-1)<1)?1:$clog2(2*(W-1)*(H-1)+1),
        OW=2*(1+XW+YW+2*(G+1))+SW+T+6;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,s_valid=0,s_sof=0,s_eol=0,s_error=0,m_ready=0;
    reg [G-1:0] s_pixel=0,s_level=0;reg [T-1:0] s_tag=0;
    wire s_ready,m_valid,m_axis0,m_axis1,m_is_summary,m_first,m_last;
    wire [XW-1:0] m_x0,m_x1;wire [YW-1:0] m_y0,m_y1;
    wire [G:0] m_num0,m_den0,m_num1,m_den1;
    wire [SW-1:0] m_index;wire [2:0] m_errors;wire [T-1:0] m_tag;
    grayscale_isocontour #(.WIDTH(W),.HEIGHT(H),.PIXEL_W(G),.TAG_W(T)) dut(.*);
    wire [OW-1:0] out_word={m_axis0,m_x0,m_y0,m_num0,m_den0,m_axis1,m_x1,m_y1,m_num1,m_den1,
                            m_index,m_is_summary,m_first,m_last,m_errors,m_tag};
    wire [2*G+T+2:0] in_word={s_pixel,s_sof,s_eol,s_error,s_level,s_tag};
    longint signed ins[0:NUM_INPUTS-1][0:5],gold[0:NUM_OUTPUTS-1][0:15];
    integer meta[0:NUM_BLOCKS-1][0:8],ib[0:NUM_BLOCKS],ob[0:NUM_BLOCKS],first_block[0:NUM_INPUTS-1];
    integer fd,r,i,j,b,q,ni=0,no=0,main_frames,reset_number,block_number,main_input_end,main_output_end;
    longint signed value,tag_limit;
    integer src=0,src_end=0,exp_pos=0,exp_end=0,fallback=-1,phase=0,current_block=0,target=-1;
    integer cycles=0,frames=0,fresh_count=0,resets=0,queued=0,starts=0,out_age=0,prior_retire=-100;
    integer source_holds=0,output_holds=0,bank_reads=0,multiplies=0,decisions=0,latencies=0,max_tail=0;
    integer records=0,owner_records=0,read_work=0,mul_work=0,frame_stalls=0,last_accept=0;
    integer pos,f,old_slot,write_address,read_address,sign_bits,saddle_index,latency;
    reg source_block=0,output_block=0,probe_done=0,do_read,do_write,do_latch,do_mul,do_save;
    reg [2*G+T+2:0] prior_input;reg [OW-1:0] prior_output;
    reg [N-1:0] owned=0;reg [G-1:0] shadow[0:N-1],before_q,want_q,want_write;
    longint signed want_deviation,want_product,want_first,before_product,ma,mb,det;
    reg [14:0] state_mask=0;reg [15:0] sign_mask=0;reg [5:0] saddle_mask=0;reg [34:0] reset_mask=0;
    string fixture;
    function automatic longint signed field(input integer index);
        case(index)
            0:field=m_axis0;1:field=m_x0;2:field=m_y0;3:field=m_num0;4:field=m_den0;
            5:field=m_axis1;6:field=m_x1;7:field=m_y1;8:field=m_num1;9:field=m_den1;
            10:field=m_index;11:field=m_is_summary;12:field=m_first;13:field=m_last;
            14:field=m_errors;15:field=m_tag;default:field=-999;
        endcase
    endfunction
    function automatic integer hit(input integer id);
        case(id)
            0:hit=dut.state==0 && dut.address==0;
            1:hit=dut.state==0 && dut.address!=0 && dut.errors!=0;
            2:hit=dut.state==1 && dut.errors==0;
            3:hit=dut.state==2;
            4,5,6,7:hit=dut.state==3 && dut.load_slot==id-4;
            8,9,10,11:hit=dut.state==4 && dut.load_slot==id-8;
            12:hit=dut.state==5 && dut.crossings==0;
            13:hit=dut.state==5 && dut.crossings!=0 && dut.crossings!=15;
            14:hit=dut.state==5 && dut.crossings==15;
            15:hit=dut.state==6;16:hit=dut.state==7;17:hit=dut.state==8;
            18:hit=dut.state==9 && $signed(dut.determinant)>0;
            19:hit=dut.state==9 && $signed(dut.determinant)<0;
            20:hit=dut.state==9 && dut.determinant==0 && $signed(dut.deviation[0])>0;
            21:hit=dut.state==9 && dut.determinant==0 && $signed(dut.deviation[0])<0;
            22:hit=dut.state==10 && !dut.pair_two;
            23:hit=dut.state==11 && !dut.pair_two && out_age>=3;
            24:hit=dut.state==11 && dut.pair_two && !dut.pair_second && out_age>=3;
            25:hit=dut.state==10 && dut.pair_two && dut.pair_second;
            26:hit=dut.state==11 && dut.pair_two && dut.pair_second && out_age>=3;
            27:hit=dut.state==12 && dut.x==W-2 && dut.y<H-2;
            28:hit=dut.state==12 && dut.x==W-2 && dut.y==H-2;
            29:hit=dut.state==13 && dut.errors==0 && dut.segment_count>0;
            30:hit=dut.state==14 && dut.errors==0 && dut.segment_count>0 && out_age>=3;
            31:hit=dut.state==14 && dut.errors==0 && dut.segment_count==0 && out_age>=3;
            32:hit=dut.state==1 && dut.errors==7;
            33:hit=dut.state==13 && dut.errors==7;
            34:hit=dut.state==14 && dut.errors==7 && out_age>=3;
            default:hit=0;
        endcase
    endfunction
    task automatic tick;
        begin
            @(negedge clk);
            pos=(src<src_end)?src:fallback;
            s_valid=!rst && pos>=0;
            if(pos>=0)begin
                s_pixel=ins[pos][0];s_sof=ins[pos][1];s_eol=ins[pos][2];s_error=ins[pos][3];
                s_level=ins[pos][4];s_tag=ins[pos][5];
                // Fixed source gaps only inside a capturable frame, never the
                // first queued token or an already blocked token.
                if(!source_block && dut.state==0 && dut.address!=0 && cycles%7==0)s_valid=0;
            end
            m_ready=!rst && out_age>=3;
            #1;
            if(!rst && phase==1 && hit(target))begin
                state_mask[dut.state]=1;reset_mask[target]=1;resets=resets+1;probe_done=1;
                $display("OBS id=%0d state=%0d slot=%0d x=%0d y=%0d index=%0d errors=%0d cycle=%0d",target,dut.state,dut.load_slot,dut.x,dut.y,dut.segment_count,dut.errors,cycles);
                rst=1;
                #1;if(s_ready || m_valid || m_first || m_last || m_is_summary)$fatal(1,"immediate reset gate");
            end
            @(posedge clk);
            cycles=cycles+1;if(cycles>CYCLE_LIMIT)$fatal(1,"frozen cycle limit");
            do_read=0;do_write=0;do_latch=0;do_mul=0;do_save=0;
            before_q=dut.image_q;before_product=$signed(dut.product_q);
            if(rst)begin
                owned=0;source_block=0;output_block=0;out_age=0;frame_stalls=0;read_work=0;mul_work=0;
            end else begin
                state_mask[dut.state]=1;
                if(source_block)begin
                    if(!s_valid || in_word!==prior_input)$fatal(1,"complete input changed while blocked");
                    source_holds=source_holds+1;
                end
                if(output_block)begin
                    if(!m_valid || out_word!==prior_output)$fatal(1,"complete output changed while held");
                    output_holds=output_holds+1;
                end
                source_block=s_valid && !s_ready;prior_input=in_word;
                output_block=m_valid && !m_ready;prior_output=out_word;
                if(s_valid && s_ready)begin
                    if(src>=src_end)$fatal(1,"fresh fallback accepted before owner cancellation");
                    if(dut.state!=0 || dut.address!=src-ib[current_block])begin
                        // A main job contains consecutive full frames.
                        if(phase!=0 || dut.address!=src%N)$fatal(1,"capture cursor/ownership");
                    end
                    if(first_block[src]>=0)begin
                        current_block=first_block[src];owned=0;read_work=0;mul_work=0;frame_stalls=0;
                        if(phase==0)begin
                            if(starts>0)begin
                                if(cycles!=prior_retire+1)$fatal(1,"queued first pixel accepted on wrong edge");
                                queued=queued+1;
                            end
                            starts=starts+1;
                        end
                    end
                    write_address=dut.address;want_write=s_pixel;do_write=1;
                    if(write_address<0 || write_address>=N)$fatal(1,"capture address bound");
                    owned[write_address]=1;shadow[write_address]=s_pixel;
                    if(dut.address==N-1)last_accept=cycles;
                    src=src+1;
                end
                if(m_valid)begin
                    if(exp_pos>=exp_end)$fatal(1,"unexpected output");
                    for(f=0;f<16;f=f+1)if(field(f)!==gold[exp_pos][f])
                        $fatal(1,"gold mismatch phase=%0d block=%0d row=%0d field=%0d got=%0d want=%0d",phase,current_block,exp_pos,f,field(f),gold[exp_pos][f]);
                    if(m_ready)begin
                        if(out_age!=3)$fatal(1,"each record requires exactly three holds");
                        exp_pos=exp_pos+1;out_age=0;
                        if(phase==1)owner_records=owner_records+1;else records=records+1;
                        if(m_last)begin
                            if(phase==1)$fatal(1,"reset target missed before owner summary retirement");
                            latency=cycles-last_accept-frame_stalls;
                            if(latency!=meta[current_block][3])$fatal(1,"exact tail got=%0d want=%0d",latency,meta[current_block][3]);
                            if(read_work!=4*meta[current_block][4] || mul_work!=2*meta[current_block][5])$fatal(1,"exact structural work");
                            latencies=latencies+1;if(latency>max_tail)max_tail=latency;
                            if(phase==0)begin frames=frames+1;prior_retire=cycles;end
                            else fresh_count=fresh_count+1;
                        end
                    end else begin out_age=out_age+1;frame_stalls=frame_stalls+1;end
                end else out_age=0;
                if(dut.state==3)begin
                    if(!(&owned))$fatal(1,"read before entire owned raster captured");
                    if(dut.x>=W-1 || dut.y>=H-1 || dut.address!=dut.y*W+dut.x)$fatal(1,"cell base cursor");
                    read_address=dut.read_address;
                    if(read_address<0 || read_address>=N || !owned[read_address])$fatal(1,"read ownership/address");
                    want_q=shadow[read_address];do_read=1;bank_reads=bank_reads+1;read_work=read_work+1;
                end
                if(dut.state==4)begin
                    old_slot=dut.load_slot;want_deviation=2*dut.image_q-2*dut.level-1;do_latch=1;
                end
                if(dut.state==5)begin
                    sign_bits=0;for(i=0;i<4;i=i+1)if($signed(dut.deviation[i])>0)sign_bits=sign_bits|(1<<i);
                    sign_mask[sign_bits]=1;
                end
                if(dut.state==6 || dut.state==8)begin
                    ma=$signed(dut.mul_a);mb=$signed(dut.mul_b);want_product=ma*mb;
                    do_mul=1;multiplies=multiplies+1;mul_work=mul_work+1;
                end
                if(dut.state==7)begin want_first=$signed(dut.product_q);do_save=1;end
                if(dut.state==9)begin
                    ma=$signed(dut.deviation[0]);mb=$signed(dut.deviation[2]);det=ma*mb;
                    ma=$signed(dut.deviation[1]);mb=$signed(dut.deviation[3]);det=det-ma*mb;
                    if($signed(dut.determinant)!==det)$fatal(1,"full signed saddle determinant");
                    saddle_index=(det>0)?0:((det<0)?2:4);
                    if($signed(dut.deviation[0])<0)saddle_index=saddle_index+1;
                    saddle_mask[saddle_index]=1;decisions=decisions+1;
                end
            end
            #1;
            if(do_write && dut.image_memory[write_address]!==want_write)$fatal(1,"accepted pixel not stored");
            if(do_read)begin if(dut.image_q!==want_q)$fatal(1,"clocked read-q");end
            else if(dut.image_q!==before_q)$fatal(1,"read-q changed outside read phase or reset");
            if(do_latch && $signed(dut.deviation[old_slot])!==want_deviation)$fatal(1,"signed half-level deviation");
            if(do_mul && $signed(dut.product_q)!==want_product)$fatal(1,"shared natural-width product");
            if(do_save && $signed(dut.first_product)!==want_first)$fatal(1,"saved first product");
            if(rst)begin
                if(s_ready || m_valid || m_first || m_last || m_is_summary || dut.state!=0 ||
                   dut.address!=0 || dut.x!=0 || dut.y!=0 || dut.load_slot!=0 ||
                   dut.deviation[0]!=0 || dut.deviation[1]!=0 || dut.deviation[2]!=0 || dut.deviation[3]!=0 ||
                   dut.product_q!=0 || dut.first_product!=0 || dut.edge0!=0 || dut.edge1!=0 || dut.edge2!=0 || dut.edge3!=0 ||
                   dut.pair_two || dut.pair_second || dut.segment_count!=0 || dut.level!=0 || dut.tag!=0 || dut.errors!=0 ||
                   m_axis0 || m_x0!=0 || m_y0!=0 || m_num0!=0 || m_den0!=0 || m_axis1 || m_x1!=0 || m_y1!=0 || m_num1!=0 || m_den1!=0)
                    $fatal(1,"active reset control/public cancellation");
            end else state_mask[dut.state]=1;
            #1;
        end
    endtask
    initial begin
        tag_limit=(64'd1<<T)-1;
        if(!$value$plusargs("FIXTURE=%s",fixture))$fatal(1,"fixture argument");
        fd=$fopen(fixture,"r");if(!fd)$fatal(1,"fixture open");
        r=$fscanf(fd,"%d %d %d",main_frames,reset_number,block_number);
        if(r!=3 || block_number!=NUM_BLOCKS || block_number!=main_frames+2*reset_number)$fatal(1,"fixture header");
        for(b=0;b<block_number;b=b+1)begin
            ib[b]=ni;ob[b]=no;
            for(j=0;j<9;j=j+1)begin
                r=$fscanf(fd,"%d",value);if(r!=1 || value< -1 || (j!=8 && value>2147483647))$fatal(1,"metadata parse/range");
                // T32 tags require the full unsigned domain, stored below separately in gold.
                if(j==8)begin if(value<0 || value>tag_limit)$fatal(1,"metadata tag");meta[b][j]=0;end
                else meta[b][j]=value;
            end
            if(meta[b][0]!=(b<main_frames?0:((b-main_frames)%2?2:1)) ||
               meta[b][2]!=meta[b][6]+1 || meta[b][3]!=3+11*meta[b][4]+2*meta[b][6]+4*meta[b][5])$fatal(1,"metadata contract");
            for(i=0;i<N;i=i+1)begin
                if(ni>=NUM_INPUTS)$fatal(1,"input allocation");first_block[ni]=(i==0)?b:-1;
                for(j=0;j<6;j=j+1)begin
                    r=$fscanf(fd,"%d",value);
                    if(r!=1 || value<0 || ((j==0 || j==4) && value>((64'd1<<G)-1)) ||
                       (j>=1 && j<=3 && value>1) || (j==5 && value>tag_limit))$fatal(1,"full-width input parse/range");
                    ins[ni][j]=value;
                end
                ni=ni+1;
            end
            for(i=0;i<meta[b][2];i=i+1)begin
                if(no>=NUM_OUTPUTS)$fatal(1,"output allocation");
                for(j=0;j<16;j=j+1)begin
                    r=$fscanf(fd,"%d",value);
                    if(r!=1 || value<0 || ((j==0 || j==5 || (j>=11 && j<=13)) && value>1) ||
                       ((j==1 || j==6) && value>=W) || ((j==2 || j==7) && value>=H) ||
                       ((j==3 || j==4 || j==8 || j==9) && value>((64'd1<<(G+1))-1)) ||
                       (j==10 && value>2*(W-1)*(H-1)) || (j==14 && value>7) || (j==15 && value>tag_limit))
                        $fatal(1,"full-width output parse/range");
                    gold[no][j]=value;
                end
                no=no+1;
            end
        end
        ib[block_number]=ni;ob[block_number]=no;$fclose(fd);
        if(ni!=NUM_INPUTS || no!=NUM_OUTPUTS)$fatal(1,"exact frozen allocation");
        main_input_end=ib[main_frames];main_output_end=ob[main_frames];
        phase=0;src=0;src_end=main_input_end;exp_pos=0;exp_end=main_output_end;fallback=-1;
        tick();rst=0;while(exp_pos<exp_end)tick();
        if(src!=src_end || frames!=main_frames || queued!=((main_frames>0)?main_frames-1:0))$fatal(1,"main completion");
        for(q=0;q<reset_number;q=q+1)begin
            b=main_frames+2*q;current_block=b;target=meta[b][1];phase=1;probe_done=0;out_age=0;
            if(target<0 || target>34 || meta[b+1][1]!=target)$fatal(1,"reset ID pair");
            src=ib[b];src_end=ib[b+1];exp_pos=ob[b];exp_end=ob[b+1];fallback=ib[b+1];
            while(!probe_done)tick();
            rst=0;phase=2;current_block=b+1;src=ib[b+1];src_end=ib[b+2];
            exp_pos=ob[b+1];exp_end=ob[b+2];fallback=-1;
            while(exp_pos<exp_end)tick();
            if(src!=src_end)$fatal(1,"fresh raster incomplete");
        end
        if(resets!=reset_number || fresh_count!=reset_number || latencies!=main_frames+reset_number)$fatal(1,"recovery/tail completion");
        $display("PASS W=%0d H=%0d G=%0d T=%0d frames=%0d queued=%0d resets=%0d fresh=%0d records=%0d owner_records=%0d source_holds=%0d output_holds=%0d reads=%0d multiplies=%0d decisions=%0d latencies=%0d max_tail=%0d states=%h signs=%h saddles=%h resetmask=%h cycles=%0d",W,H,G,T,frames,queued,resets,fresh_count,records,owner_records,source_holds,output_holds,bank_reads,multiplies,decisions,latencies,max_tail,state_mask,sign_mask,saddle_mask,reset_mask,cycles);
        $finish;
    end
endmodule
