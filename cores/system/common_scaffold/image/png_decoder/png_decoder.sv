// Original PNG/DEFLATE decoder. Noninterlaced 8-bit gray/RGB. Serialized bounded implementation.
module png_decoder #(
 parameter integer MAX_WIDTH=16,MAX_HEIGHT=12,MAX_COMPRESSED_BYTES=4096
)(input clk,rst_n,ce,input start_valid,output start_ready,input abort,
 input[7:0]s_data,input s_valid,s_last,output s_ready,
 output reg[23:0]m_rgb,output m_valid,input m_ready,output m_sof,m_eol,m_last,
 output done_valid,input done_ready,output reg frame_error,output reg[7:0]error_code,
 output reg[15:0]image_width,image_height,output reg[7:0]image_color_type);
 localparam IDLE=0,SIG=1,CLEN=2,CTYPE=3,CDATA=4,CCRC=5,ZCHECK=6,BLOCK=7,BLOCK_KIND=8,
 BITS=9,BYTE_REQ=10,BYTE_USE=11,ST_ALIGN=12,ST_LEN=13,ST_NLEN=14,ST_CHECK=15,ST_GET=16,ST_BYTE=17,ST_NEXT=18,
 FIXED=19,BUILD_CLEAR=20,BUILD_COUNT_REQ=21,BUILD_COUNT_USE=22,BUILD_FIRST=23,BUILD_CODE_REQ=24,BUILD_CODE_USE=25,
 DYN_HEAD=26,DYN_HEAD_USE=27,DYN_ZERO=28,DYN_CL_GET=29,DYN_CL_USE=30,DYN_LENGTH=31,DYN_SYMBOL=32,DYN_REPEAT=33,DYN_WRITE=34,
 DEC_START=35,DEC_BIT=36,DEC_REQ=37,DEC_USE=38,TOKEN=39,LENGTH_USE=40,DIST_SYMBOL=41,DIST_USE=42,COPY_REQ=43,COPY_USE=44,COPY_NEXT=45,
 EMIT=46,FREAD=47,FAPPLY=48,HOLD=49,FINISH_BLOCK=50,END_DEFLATE=51,ADLER_GET=52,ADLER_USE=53,DONE=54,DIST_EXTRA=55;
 localparam COMP_AW=$clog2(MAX_COMPRESSED_BYTES+1);
 reg[5:0]state,bit_return,decode_return,build_return,emit_return;
 reg[31:0]chunk_length,chunk_index,chunk_type,crc_calc,crc_received;
 reg[3:0]byte_index;reg ihdr_seen,idat_seen,idat_closed,plte_seen;
 reg[31:0]width32,height32;reg[7:0]depth,compression,filter_method,interlace,zcmf,zflg;
 (* ram_style="block" *)reg[7:0]compressed[0:MAX_COMPRESSED_BYTES-1];
 reg[COMP_AW-1:0]compressed_count,compressed_pos;
 reg[7:0]compressed_q;
 reg[31:0]bit_buffer,bits_value;reg[5:0]bit_count,need_bits;
 reg final_block;reg[15:0]stored_len;
 (* ram_style="block" *)reg[7:0]history[0:32767];
 reg[14:0]history_pos;reg[7:0]history_q,out_byte;
 reg[31:0]raw_count;reg[15:0]adler_a,adler_b;reg[31:0]adler_received;
 reg[8:0]copy_remaining;reg[15:0]copy_distance,length_base;reg[4:0]extra_bits;
 (* ram_style="block" *)reg[3:0]lengths[0:351];
 (* ram_style="block" *)reg[14:0]codes[0:351];
 reg[3:0]length_q;reg[14:0]code_q;
 reg[9:0]counts[0:15];reg[15:0]nextcode[0:15];
 reg[8:0]tree_first,tree_last,scan_index,build_index;
 reg[8:0]build_symbols;reg[3:0]build_max;reg[4:0]build_level,decode_length;reg[15:0]build_code,decode_code;
 reg[1:0]decode_tree;reg[8:0]decoded_symbol;
 reg[8:0]hlit,hdist,total_lengths,length_index;reg[4:0]hclen,cl_index;
 reg[3:0]previous_length,repeat_value;reg[8:0]repeat_count;
 (* ram_style="block" *)reg[7:0]row_memory[0:MAX_WIDTH*3-1];
 reg[7:0]row_q,left_value[0:2],upper_left[0:2];
 reg[9:0]row_column;reg[1:0]channel,bpp;reg expecting_filter;reg[2:0]scan_filter;
 reg[15:0]pixel_x,pixel_y;reg[23:0]assembly;
 integer i;
 wire accepting=s_valid&&s_ready;
 wire[31:0]next_type={chunk_type[23:0],s_data};
 wire[7:0]up=pixel_y==0?8'd0:row_q;
 wire[7:0]a=left_value[channel],c=upper_left[channel];
 function letter;input[7:0]v;begin letter=(v>=65&&v<=90)||(v>=97&&v<=122);end endfunction
 function[31:0]crc_byte;input[31:0]old;input[7:0]v;reg[31:0]q;integer j;begin q=old^v;for(j=0;j<8;j=j+1)q=q[0]?(q>>1)^32'hedb88320:q>>1;crc_byte=q;end endfunction
 function[7:0]signature;input[3:0]n;begin case(n)0:signature=137;1:signature=80;2:signature=78;3:signature=71;4:signature=13;5:signature=10;6:signature=26;default:signature=10;endcase end endfunction
 function[4:0]cl_order;input[4:0]n;begin case(n)0:cl_order=16;1:cl_order=17;2:cl_order=18;3:cl_order=0;4:cl_order=8;5:cl_order=7;6:cl_order=9;7:cl_order=6;8:cl_order=10;9:cl_order=5;10:cl_order=11;11:cl_order=4;12:cl_order=12;13:cl_order=3;14:cl_order=13;15:cl_order=2;16:cl_order=14;17:cl_order=1;default:cl_order=15;endcase end endfunction
 function[7:0]paeth;input[7:0]aa,bb,cc;integer p,da,db,dc;begin p=aa+bb-cc;da=p-aa;if(da<0)da=-da;db=p-bb;if(db<0)db=-db;dc=p-cc;if(dc<0)dc=-dc;if(da<=db&&da<=dc)paeth=aa;else if(db<=dc)paeth=bb;else paeth=cc;end endfunction
 reg[7:0]predictor;always @*case(scan_filter)0:predictor=0;1:predictor=a;2:predictor=up;3:predictor=({1'b0,a}+{1'b0,up})>>1;default:predictor=paeth(a,up,c);endcase
 wire[7:0]reconstructed=out_byte+predictor;
 wire[16:0]adler_next_a={1'b0,adler_a}+out_byte;
 wire[16:0]adler_reduced_a=adler_next_a>=65521?adler_next_a-65521:adler_next_a;
 wire[16:0]adler_next_b={1'b0,adler_b}+adler_reduced_a;
 wire[8:0]length_address=length_index<hlit?length_index:9'd288+length_index-hlit;
 wire length_write_enable=state==FIXED||state==DYN_ZERO||state==DYN_CL_USE||(state==DYN_WRITE&&length_index<total_lengths&&length_index+repeat_count<=total_lengths);
 wire[8:0]length_write_address=state==DYN_CL_USE?9'd320+cl_order(cl_index):state==DYN_WRITE?length_address:build_index;
 wire[3:0]fixed_length=build_index<144?8:build_index<256?9:build_index<280?7:build_index<288?8:5;
 wire[3:0]length_write_data=state==FIXED?fixed_length:state==DYN_CL_USE?bits_value[3:0]:state==DYN_WRITE?repeat_value:0;
 assign start_ready=rst_n&&ce&&!abort&&state==IDLE;
 assign s_ready=rst_n&&ce&&!abort&&(state==SIG||state==CLEN||state==CTYPE||state==CDATA||state==CCRC);
 assign m_valid=rst_n&&!abort&&state==HOLD;
 assign m_sof=pixel_x==0&&pixel_y==0;assign m_eol=pixel_x==image_width-1;assign m_last=pixel_x==image_width-1&&pixel_y==image_height-1;
 assign done_valid=rst_n&&state==DONE;
 task fail;input[7:0]reason;begin state<=DONE;frame_error<=1;error_code<=reason;end endtask
 task getbits;input[5:0]n;input[5:0]ret;begin need_bits<=n;bit_return<=ret;state<=BITS;end endtask
 task decode;input[1:0]tree;input[5:0]ret;begin decode_tree<=tree;decode_return<=ret;state<=DEC_START;end endtask
 task build;input[8:0]first,last;input[5:0]ret;begin tree_first<=first;tree_last<=last;build_level<=0;build_return<=ret;state<=BUILD_CLEAR;end endtask
 initial if(MAX_WIDTH<1||MAX_HEIGHT<1||MAX_WIDTH>256||MAX_HEIGHT>256||MAX_COMPRESSED_BYTES<16||MAX_COMPRESSED_BYTES>8192)$fatal(1,"png_decoder parameters");
 always @(posedge clk)if(ce)begin
 if(accepting&&state==CDATA&&chunk_type==32'h49444154&&compressed_count<MAX_COMPRESSED_BYTES)compressed[compressed_count]<=s_data;
 if(state==BYTE_REQ)compressed_q<=compressed[compressed_pos];
 if(state==COPY_REQ)history_q<=history[(history_pos-copy_distance)&15'h7fff];
 if(state==EMIT)history[history_pos]<=out_byte;
 if(state==FREAD)row_q<=row_memory[row_column];
 if(state==FAPPLY)row_memory[row_column]<=reconstructed;
 if(state==BUILD_COUNT_REQ||state==BUILD_CODE_REQ||state==DEC_REQ)length_q<=lengths[state==DEC_REQ?scan_index:build_index];
 if(state==DEC_REQ)code_q<=codes[scan_index];
 if(!abort&&rst_n)begin
 if(length_write_enable)lengths[length_write_address]<=length_write_data;
 if(state==BUILD_CODE_USE&&length_q!=0)codes[build_index]<=nextcode[length_q];end
 end
 always @(posedge clk)begin
 if(!rst_n)begin
 state<=IDLE;frame_error<=0;error_code<=0;image_width<=0;image_height<=0;image_color_type<=0;m_rgb<=0;
 compressed_count<=0;compressed_pos<=0;chunk_length<=0;chunk_index<=0;chunk_type<=0;crc_calc<=0;crc_received<=0;byte_index<=0;
 ihdr_seen<=0;idat_seen<=0;idat_closed<=0;plte_seen<=0;width32<=0;height32<=0;depth<=0;compression<=0;filter_method<=0;interlace<=0;zcmf<=0;zflg<=0;
 bit_buffer<=0;bits_value<=0;bit_count<=0;need_bits<=0;bit_return<=0;decode_return<=0;build_return<=0;emit_return<=0;
 final_block<=0;stored_len<=0;history_pos<=0;out_byte<=0;raw_count<=0;adler_a<=1;adler_b<=0;adler_received<=0;
 copy_remaining<=0;copy_distance<=0;length_base<=0;extra_bits<=0;tree_first<=0;tree_last<=0;scan_index<=0;build_index<=0;build_level<=0;build_symbols<=0;build_max<=0;decode_length<=0;build_code<=0;decode_code<=0;decode_tree<=0;decoded_symbol<=0;
 hlit<=0;hdist<=0;total_lengths<=0;length_index<=0;hclen<=0;cl_index<=0;previous_length<=0;repeat_value<=0;repeat_count<=0;
 row_column<=0;channel<=0;bpp<=0;expecting_filter<=1;scan_filter<=0;pixel_x<=0;pixel_y<=0;assembly<=0;
 for(i=0;i<3;i=i+1)begin left_value[i]<=0;upper_left[i]<=0;end
 end else if(ce)begin
 if(abort&&state!=IDLE&&state!=DONE)fail(8'hf0);
 else if(accepting&&s_last&&!(state==CCRC&&byte_index==3&&chunk_type==32'h49454e44))fail(8'h11);
 else case(state)
 IDLE:if(start_valid&&start_ready)begin
 frame_error<=0;error_code<=0;byte_index<=0;state<=SIG;compressed_count<=0;ihdr_seen<=0;idat_seen<=0;idat_closed<=0;plte_seen<=0;image_width<=0;image_height<=0;image_color_type<=0;
 history_pos<=0;raw_count<=0;adler_a<=1;adler_b<=0;expecting_filter<=1;row_column<=0;channel<=0;pixel_x<=0;pixel_y<=0;assembly<=0;
 for(i=0;i<3;i=i+1)begin left_value[i]<=0;upper_left[i]<=0;end end
 SIG:if(accepting)begin if(s_data!=signature(byte_index))fail(8'h10);else if(byte_index==7)begin state<=CLEN;byte_index<=0;chunk_length<=0;end else byte_index<=byte_index+1;end
 CLEN:if(accepting)begin if(byte_index==0&&s_data[7])fail(8'h12);else begin chunk_length<={chunk_length[23:0],s_data};if(byte_index==3)begin byte_index<=0;chunk_type<=0;crc_calc<=32'hffffffff;state<=CTYPE;end else byte_index<=byte_index+1;end end
 CTYPE:if(accepting)begin
 chunk_type<=next_type;crc_calc<=crc_byte(crc_calc,s_data);
 if(byte_index==3)begin byte_index<=0;chunk_index<=0;
 if(!letter(next_type[31:24])||!letter(next_type[23:16])||!letter(next_type[15:8])||!letter(next_type[7:0])||next_type[13])fail(8'h12);
 else if(!ihdr_seen&&next_type!=32'h49484452)fail(8'h12);
 else if(next_type==32'h49484452&&(ihdr_seen||chunk_length!=13))fail(8'h12);
 else if(next_type==32'h49444154&&idat_closed)fail(8'h12);
 else if(next_type==32'h49454e44&&(chunk_length!=0||!idat_seen))fail(8'h12);
 else if(next_type==32'h504c5445&&(plte_seen||idat_seen||image_color_type!=2||chunk_length==0||chunk_length>768||chunk_length%3!=0))fail(8'h12);
 else if(next_type!=32'h504c5445&&next_type!=32'h49484452&&next_type!=32'h49444154&&next_type!=32'h49454e44&&!next_type[29])fail(8'h13);
 else begin if(idat_seen&&next_type!=32'h49444154)idat_closed<=1;if(next_type==32'h49444154)idat_seen<=1;if(next_type==32'h504c5445)plte_seen<=1;state<=chunk_length==0?CCRC:CDATA;crc_received<=0;end
 end else byte_index<=byte_index+1;end
 CDATA:if(accepting)begin
 crc_calc<=crc_byte(crc_calc,s_data);
 if(chunk_type==32'h49484452)case(chunk_index)
 0,1,2,3:width32<={width32[23:0],s_data};4,5,6,7:height32<={height32[23:0],s_data};8:depth<=s_data;9:image_color_type<=s_data;10:compression<=s_data;11:filter_method<=s_data;12:interlace<=s_data;endcase
 if(chunk_type==32'h49444154)begin
 if(compressed_count>=MAX_COMPRESSED_BYTES)fail(8'h14);
 else begin if(compressed_count==0)zcmf<=s_data;if(compressed_count==1)zflg<=s_data;compressed_count<=compressed_count+1;end end
 if(chunk_index==chunk_length-1)begin state<=CCRC;byte_index<=0;crc_received<=0;end else chunk_index<=chunk_index+1;
 if(chunk_type==32'h49444154&&compressed_count>=MAX_COMPRESSED_BYTES)fail(8'h14);
 end
 CCRC:if(accepting)begin
 crc_received<={crc_received[23:0],s_data};
 if(byte_index==3)begin
 if({crc_received[23:0],s_data}!=~crc_calc)fail(8'h15);
 else if(chunk_type==32'h49484452)begin
 if(width32==0||height32==0||width32>MAX_WIDTH||height32>MAX_HEIGHT)fail(8'h16);
 else if(depth!=8||(image_color_type!=0&&image_color_type!=2)||compression!=0||filter_method!=0||interlace!=0)fail(8'h17);
 else begin image_width<=width32;image_height<=height32;bpp<=image_color_type==2?3:1;ihdr_seen<=1;chunk_length<=0;byte_index<=0;state<=CLEN;end end
 else if(chunk_type==32'h49454e44)begin if(!s_last)fail(8'h11);else state<=ZCHECK;end
 else begin chunk_length<=0;byte_index<=0;state<=CLEN;end
 end else byte_index<=byte_index+1;end
 ZCHECK:begin
 if(compressed_count<6||(zcmf&15)!=8||(zcmf>>4)>7||({zcmf,zflg}%31)!=0||zflg[5])fail(8'h20);
 else begin compressed_pos<=2;bit_count<=0;bit_buffer<=0;state<=BLOCK;end end
 BITS:begin
 if(bit_count>=need_bits)begin bits_value<=bit_buffer&((32'd1<<need_bits)-1);bit_buffer<=bit_buffer>>need_bits;bit_count<=bit_count-need_bits;state<=bit_return;end
 else if(compressed_pos>=compressed_count)fail(8'h21);else state<=BYTE_REQ;end
 BYTE_REQ:state<=BYTE_USE;
 BYTE_USE:begin bit_buffer<=bit_buffer|({24'd0,compressed_q}<<bit_count);bit_count<=bit_count+8;compressed_pos<=compressed_pos+1;state<=BITS;end
 BLOCK:getbits(3,BLOCK_KIND);
 BLOCK_KIND:begin final_block<=bits_value[0];case(bits_value[2:1])0:state<=ST_ALIGN;1:begin build_index<=0;hlit<=0;state<=FIXED;end 2:state<=DYN_HEAD;default:fail(8'h22);endcase end
 ST_ALIGN:begin bit_buffer<=0;bit_count<=0;getbits(16,ST_LEN);end
 ST_LEN:begin stored_len<=bits_value;getbits(16,ST_NLEN);end
 ST_NLEN:begin if((stored_len^bits_value[15:0])!=16'hffff)fail(8'h23);else if(stored_len==0)state<=FINISH_BLOCK;else state<=ST_GET;end
 ST_GET:getbits(8,ST_BYTE);
 ST_BYTE:begin out_byte<=bits_value;emit_return<=ST_NEXT;state<=EMIT;end
 ST_NEXT:begin if(stored_len==1)state<=FINISH_BLOCK;else begin stored_len<=stored_len-1;state<=ST_GET;end end
 FIXED:begin
 
 if(build_index==319)build(0,287,DIST_SYMBOL);else build_index<=build_index+1;end
 // Build the distance tree after either fixed or dynamic literal/length tree.
 BUILD_CLEAR:begin counts[build_level]<=0;if(build_level==0)begin build_symbols<=0;build_max<=0;end if(build_level==15)begin build_index<=tree_first;state<=BUILD_COUNT_REQ;end else build_level<=build_level+1;end
 BUILD_COUNT_REQ:state<=BUILD_COUNT_USE;
 BUILD_COUNT_USE:begin if(length_q!=0)begin counts[length_q]<=counts[length_q]+1;build_symbols<=build_symbols+1;if(length_q>build_max)build_max<=length_q;end
 if(build_index==tree_last)begin build_level<=1;build_code<=0;state<=BUILD_FIRST;end else begin build_index<=build_index+1;state<=BUILD_COUNT_REQ;end end
 BUILD_FIRST:begin
 if(build_code+counts[build_level]>(32'd1<<build_level))fail(8'h24);
 else if(build_level==15&&build_code+counts[15]<32768&&!((tree_first==288&&build_symbols==0)||(tree_first!=320&&build_symbols==1&&build_max==1)))fail(8'h24);
 else begin nextcode[build_level]<=build_code;
 if(build_level==15)begin build_index<=tree_first;state<=BUILD_CODE_REQ;end
 else begin build_code<=(build_code+counts[build_level])<<1;build_level<=build_level+1;end end end
 BUILD_CODE_REQ:state<=BUILD_CODE_USE;
 BUILD_CODE_USE:begin
 if(length_q!=0)begin nextcode[length_q]<=nextcode[length_q]+1;end
 if(build_index==tree_last)state<=build_return;else begin build_index<=build_index+1;state<=BUILD_CODE_REQ;end end
 DYN_HEAD:getbits(14,DYN_HEAD_USE);
 DYN_HEAD_USE:begin hlit<=257+bits_value[4:0];hdist<=1+bits_value[9:5];total_lengths<=258+bits_value[4:0]+bits_value[9:5];hclen<=4+bits_value[13:10];cl_index<=0;build_index<=0;state<=DYN_ZERO;
 if(bits_value[4:0]>29||bits_value[9:5]>29)fail(8'h25);end
 DYN_ZERO:begin if(build_index==338)begin state<=DYN_CL_GET;cl_index<=0;end else build_index<=build_index+1;end
 DYN_CL_GET:getbits(3,DYN_CL_USE);
 DYN_CL_USE:begin if(cl_index==hclen-1)begin length_index<=0;previous_length<=0;build(320,338,DYN_LENGTH);end else begin cl_index<=cl_index+1;state<=DYN_CL_GET;end end
 DYN_LENGTH:decode(2,DYN_SYMBOL);
 DYN_SYMBOL:begin
 if(decoded_symbol<=15)begin repeat_value<=decoded_symbol;repeat_count<=1;previous_length<=decoded_symbol;state<=DYN_WRITE;end
 else if(decoded_symbol==16)begin if(length_index==0)fail(8'h25);else begin repeat_value<=previous_length;getbits(2,DYN_REPEAT);end end
 else if(decoded_symbol==17)begin repeat_value<=0;previous_length<=0;getbits(3,DYN_REPEAT);end
 else if(decoded_symbol==18)begin repeat_value<=0;previous_length<=0;getbits(7,DYN_REPEAT);end else fail(8'h25);end
 DYN_REPEAT:begin repeat_count<=bits_value+(decoded_symbol==18?11:3);state<=DYN_WRITE;end
 DYN_WRITE:begin
 if(length_index>=total_lengths||length_index+repeat_count>total_lengths)fail(8'h25);
 else begin length_index<=length_index+1;
 if(repeat_count==1)begin if(length_index==total_lengths-1)build(0,hlit-1,DIST_SYMBOL);else state<=DYN_LENGTH;end
 else repeat_count<=repeat_count-1;end end
 DEC_START:begin
 decode_code<=0;decode_length<=0;
 if(decode_tree==0)begin tree_first<=0;tree_last<=287;end else if(decode_tree==1)begin tree_first<=288;tree_last<=319;end else begin tree_first<=320;tree_last<=338;end
 getbits(1,DEC_BIT);end
 DEC_BIT:begin decode_code<=(decode_code<<1)|bits_value[0];decode_length<=decode_length+1;scan_index<=tree_first;state<=DEC_REQ;end
 DEC_REQ:state<=DEC_USE;
 DEC_USE:begin
 if(length_q==decode_length&&length_q!=0&&code_q==decode_code)begin decoded_symbol<=scan_index-tree_first;state<=decode_return;end
 else if(scan_index==tree_last)begin if(decode_length>=15)fail(8'h26);else getbits(1,DEC_BIT);end
 else begin scan_index<=scan_index+1;state<=DEC_REQ;end end
 TOKEN:begin
 if(decoded_symbol<256)begin out_byte<=decoded_symbol;emit_return<=ST_CHECK;state<=EMIT;end
 else if(decoded_symbol==256)state<=FINISH_BLOCK;
 else if(decoded_symbol>285)fail(8'h27);
 else if(decoded_symbol==285)begin length_base<=258;getbits(0,LENGTH_USE);end
 else if(decoded_symbol<=264)begin length_base<=decoded_symbol-254;getbits(0,LENGTH_USE);end
 else begin
 extra_bits<=(decoded_symbol-261)>>2;
 length_base<=(1<<(((decoded_symbol-261)>>2)+2))+3+((decoded_symbol-265-4*(((decoded_symbol-261)>>2)-1))<<((decoded_symbol-261)>>2));
 getbits((decoded_symbol-261)>>2,LENGTH_USE);end end
 LENGTH_USE:begin copy_remaining<=length_base+bits_value;decode(1,DIST_USE);end
 DIST_SYMBOL:begin
 if(tree_first==0)build(288,hlit==0?319:288+hdist-1,ST_CHECK);
 else state<=ST_CHECK;
 end
 ST_CHECK:decode(0,TOKEN);
 DIST_USE:begin
 if(decoded_symbol>29)fail(8'h28);
 else if(decoded_symbol<=3)begin copy_distance<=decoded_symbol+1;state<=COPY_REQ;
 if(decoded_symbol+1>raw_count)fail(8'h29);end
 else begin extra_bits<=(decoded_symbol>>1)-1;length_base<=((2+decoded_symbol[0])<<((decoded_symbol>>1)-1))+1;getbits((decoded_symbol>>1)-1,DIST_EXTRA);end end
 DIST_EXTRA:begin copy_distance<=length_base+bits_value;
 if(length_base+bits_value>32768||length_base+bits_value>(32'd1<<((zcmf>>4)+8))||length_base+bits_value>raw_count)fail(8'h29);else state<=COPY_REQ;end
 COPY_REQ:state<=COPY_USE;
 COPY_USE:begin out_byte<=history_q;emit_return<=COPY_NEXT;state<=EMIT;end
 COPY_NEXT:begin if(copy_remaining==1)state<=ST_CHECK;else begin copy_remaining<=copy_remaining-1;state<=COPY_REQ;end end
 EMIT:begin
 if(raw_count>=(image_width*bpp+1)*image_height)fail(8'h30);
 else begin history_pos<=history_pos+1;raw_count<=raw_count+1;adler_a<=adler_reduced_a;adler_b<=adler_next_b>=65521?adler_next_b-65521:adler_next_b;
 if(expecting_filter)begin if(out_byte>4)fail(8'h31);else begin scan_filter<=out_byte;expecting_filter<=0;state<=emit_return;end end
 else state<=FREAD;end end
 FREAD:state<=FAPPLY;
 FAPPLY:begin
 left_value[channel]<=reconstructed;upper_left[channel]<=up;assembly<={assembly[15:0],reconstructed};
 if(channel==bpp-1)begin m_rgb<=bpp==1?{reconstructed,reconstructed,reconstructed}:{assembly[15:0],reconstructed};channel<=0;state<=HOLD;end
 else begin channel<=channel+1;row_column<=row_column+1;state<=emit_return;end end
 HOLD:if(m_ready)begin
 if(pixel_x==image_width-1)begin pixel_x<=0;pixel_y<=pixel_y+1;row_column<=0;expecting_filter<=1;for(i=0;i<3;i=i+1)begin left_value[i]<=0;upper_left[i]<=0;end end
 else begin pixel_x<=pixel_x+1;row_column<=row_column+1;end state<=emit_return;end
 FINISH_BLOCK:begin if(final_block)state<=END_DEFLATE;else state<=BLOCK;end
 END_DEFLATE:begin
 if(raw_count!=(image_width*bpp+1)*image_height||pixel_y!=image_height||!expecting_filter||compressed_pos+4!=compressed_count)fail(8'h32);
 else begin bit_count<=0;bit_buffer<=0;byte_index<=0;adler_received<=0;state<=ADLER_GET;end end
 ADLER_GET:getbits(8,ADLER_USE);
 ADLER_USE:begin adler_received<={adler_received[23:0],bits_value[7:0]};if(byte_index==3)begin if({adler_received[23:0],bits_value[7:0]}!={adler_b,adler_a})fail(8'h33);else state<=DONE;end else begin byte_index<=byte_index+1;state<=ADLER_GET;end end
 DONE:if(done_ready)state<=IDLE;
 default:fail(8'hff);
 endcase end end
endmodule
