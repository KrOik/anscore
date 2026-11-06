`timescale 1ns/1ps
module tb_int4_transpose3x3_stride2 #(
 parameter MC=1,MO=1,MW=1,MH=1,TW=1,RGB=0
);
 reg clk=0;always #5 clk=~clk;
 reg rst=1,c_valid=0,c_rsp_ready=0,cmd_valid=0,s_valid=0,m_ready=0,rsp_ready=0;
 reg [1:0] c_op=0;reg [15:0] c_row=0,c_word=0;
 reg [31:0] c_weights=0;reg signed [31:0] c_bias=0;
 reg [15:0] c_scale=0;reg [4:0] c_shift=0;reg signed [7:0] c_zero=0;
 reg [15:0] cmd_width=0,cmd_height=0,cmd_ci=0,cmd_co=0;
 reg [7:0] cmd_zero=0;reg [TW-1:0] cmd_tag=0;
 reg [23:0] s_data=0;reg s_sof=0,s_eol=0,s_last=0;
 wire c_ready,c_rsp_valid,cmd_ready,s_ready,m_valid,rsp_valid;
 wire [1:0] c_error;wire [2:0] rsp_error;
 wire signed [31:0] m_data;wire [15:0] m_x,m_y,m_channel;
 wire [TW-1:0] m_tag,rsp_tag;wire [2:0] m_clip,m_inexact;
 wire m_sof,m_eol,m_last;wire [31:0] rsp_inputs,rsp_outputs;wire [2:0] internal_state;
 generate if(RGB) begin:rgb_dut
  wire [23:0] data;
  rgb_transpose_decoder #(.MAX_WIDTH(MW),.MAX_HEIGHT(MH),.TAG_W(TW)) dut(
   .clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),.c_op(c_op),.c_row(c_row),.c_word(c_word),
   .c_weights(c_weights),.c_bias(c_bias),.c_scale(c_scale),.c_shift(c_shift),.c_zero(c_zero),
   .c_rsp_valid(c_rsp_valid),.c_rsp_ready(c_rsp_ready),.c_error(c_error),
   .cmd_valid(cmd_valid),.cmd_ready(cmd_ready),.cmd_width(cmd_width),.cmd_height(cmd_height),
   .cmd_x_zero(cmd_zero),.cmd_tag(cmd_tag),.s_valid(s_valid),.s_ready(s_ready),.s_rgb(s_data),
   .s_sof(s_sof),.s_eol(s_eol),.s_last(s_last),.m_valid(m_valid),.m_ready(m_ready),.m_rgb(data),
   .m_clip(m_clip),.m_inexact(m_inexact),.m_x(m_x),.m_y(m_y),.m_sof(m_sof),.m_eol(m_eol),.m_last(m_last),
   .m_tag(m_tag),.rsp_valid(rsp_valid),.rsp_ready(rsp_ready),.rsp_error(rsp_error),
   .rsp_pixels(rsp_outputs),.rsp_tag(rsp_tag));
  assign m_data={8'd0,data};assign m_channel=0;assign rsp_inputs=0;
  assign internal_state=dut.core.state;
 end else begin:scalar_dut
  wire signed [7:0] data;wire clip,inexact;
  int4_transpose3x3_stride2 #(.MAX_IN_CHANNELS(MC),.MAX_OUT_CHANNELS(MO),.MAX_WIDTH(MW),.MAX_HEIGHT(MH),.TAG_W(TW)) dut(
   .clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),.c_op(c_op),.c_row(c_row),.c_word(c_word),
   .c_weights(c_weights),.c_bias(c_bias),.c_scale(c_scale),.c_shift(c_shift),.c_zero(c_zero),
   .c_rsp_valid(c_rsp_valid),.c_rsp_ready(c_rsp_ready),.c_error(c_error),
   .cmd_valid(cmd_valid),.cmd_ready(cmd_ready),.cmd_width(cmd_width),.cmd_height(cmd_height),
   .cmd_in_channels(cmd_ci),.cmd_out_channels(cmd_co),.cmd_x_zero(cmd_zero),.cmd_tag(cmd_tag),
   .s_valid(s_valid),.s_ready(s_ready),.s_data(s_data[7:0]),.s_sof(s_sof),.s_eol(s_eol),.s_last(s_last),
   .m_valid(m_valid),.m_ready(m_ready),.m_data(data),.m_x(m_x),.m_y(m_y),.m_channel(m_channel),.m_tag(m_tag),
   .m_clip(clip),.m_inexact(inexact),.m_sof(m_sof),.m_eol(m_eol),.m_last(m_last),
   .rsp_valid(rsp_valid),.rsp_ready(rsp_ready),.rsp_error(rsp_error),.rsp_tag(rsp_tag),
   .rsp_inputs(rsp_inputs),.rsp_outputs(rsp_outputs));
  assign m_data={{24{data[7]}},data};assign m_clip={2'd0,clip};assign m_inexact={2'd0,inexact};
  assign internal_state=dut.state;
 end endgenerate
 integer fd,rc,ncases,case_index,case_number,w,h,ci,co,xzero,tag_value,error_value,fault_index,fault_mask,clear_model,ncfg,nin,nout;
 integer cfg_op[0:1023],cfg_row[0:1023],cfg_word[0:1023],cfg_bias[0:1023],cfg_scale[0:1023],cfg_shift[0:1023],cfg_zero[0:1023];
 reg [31:0] cfg_bits[0:1023];reg [23:0] input_values[0:16383];
 integer expected_data[0:16383],expected_clip[0:16383],expected_inexact[0:16383];
 reg signed [63:0] number;
 string vector_file,tail;
 integer i,j,sent,out_index,cycle,frames=0,reset_probes=0,future_probes=0,stall_cycles=0,ex,ey,ec,row_units;
 reg checking=0,source_owned=0;
 reg held_m=0,held_s=0,held_rsp=0,held_cfg=0;
 reg [159:0] saved_m,saved_rsp;
 reg [26:0] saved_s;reg [1:0] saved_cfg;
 wire [159:0] bundle_m={m_data,m_x,m_y,m_channel,m_tag,m_clip,m_inexact,m_sof,m_eol,m_last};
 wire [159:0] bundle_rsp={rsp_error,rsp_tag,rsp_inputs,rsp_outputs};
 always @(posedge clk) begin
  if(rst) begin held_m=0;held_s=0;held_rsp=0;held_cfg=0;end
  else begin
   if(held_m && (!m_valid || bundle_m!==saved_m)) $fatal(1,"held output changed");
   if(held_s && (!s_valid || {s_data,s_sof,s_eol,s_last}!==saved_s)) $fatal(1,"source driver withdrew held input");
   if(held_rsp && (!rsp_valid || bundle_rsp!==saved_rsp)) $fatal(1,"held completion changed");
   if(held_cfg && (!c_rsp_valid || c_error!==saved_cfg)) $fatal(1,"held config changed");
   held_m=m_valid && !m_ready;held_s=s_valid && !s_ready;held_rsp=rsp_valid && !rsp_ready;held_cfg=c_rsp_valid && !c_rsp_ready;
   saved_m=bundle_m;saved_s={s_data,s_sof,s_eol,s_last};saved_rsp=bundle_rsp;saved_cfg=c_error;
   if(m_valid && !m_ready) stall_cycles=stall_cycles+1;
   if(s_valid && s_ready) begin sent=sent+1;source_owned=0;end
   if(m_valid && m_ready) begin
    if(checking) begin
     if(out_index>=nout) $fatal(1,"extra output case%0d",case_number);
     ex=(out_index/(RGB?1:co))%(2*w+1);ey=out_index/((2*w+1)*(RGB?1:co));ec=RGB?0:out_index%co;
     if(m_data!==expected_data[out_index] || m_clip!==expected_clip[out_index] || m_inexact!==expected_inexact[out_index])
      $fatal(1,"numeric case%0d index%0d got%0d/%0d/%0d expected%0d/%0d/%0d",case_number,out_index,m_data,m_clip,m_inexact,expected_data[out_index],expected_clip[out_index],expected_inexact[out_index]);
     if(m_x!==ex || m_y!==ey || m_channel!==ec || m_tag!==TW'(tag_value)) $fatal(1,"coordinate/tag mismatch");
     row_units=(2*w+1)*(RGB?1:co);
     if(m_sof!==(out_index==0) || m_eol!==((out_index+1)%row_units==0) || m_last!==(out_index==nout-1)) $fatal(1,"output marker mismatch");
    end
    out_index=out_index+1;
   end
  end
 end
 task read_number;
  begin rc=$fscanf(fd,"%d",number);if(rc!=1) $fatal(1,"required integer missing at case%0d",case_index);end
 endtask
 task tick;
  begin @(negedge clk);end
 endtask
 task reset_all;
  begin
   rst=1;c_valid=0;c_rsp_ready=0;cmd_valid=0;s_valid=0;m_ready=0;rsp_ready=0;source_owned=0;checking=0;
   repeat(3) tick();rst=0;tick();
  end
 endtask
 task config_transfer(input integer op,row,word,input reg [31:0] bits,input integer bias,scale,shift,zero,expected_error);
  integer guard;
  begin
   c_op=op;c_row=row;c_word=word;c_weights=bits;c_bias=bias;c_scale=scale;c_shift=shift;c_zero=zero;c_valid=1;
   guard=0;while(!c_ready) begin tick();guard=guard+1;if(guard>1000)$fatal(1,"config ready timeout");end
   tick();c_valid=0;guard=0;
   while(!c_rsp_valid) begin tick();guard=guard+1;if(guard>1000)$fatal(1,"config response timeout");end
   if(c_error!==expected_error) $fatal(1,"config error mismatch");
   repeat(2) begin tick();if(!c_rsp_valid || c_error!==expected_error)$fatal(1,"config not held");end
   c_rsp_ready=1;tick();c_rsp_ready=0;tick();
  end
 endtask
 task configure;
  integer k;
  begin
   if(clear_model) config_transfer(2,0,0,0,0,0,0,0,0);
   for(k=0;k<ncfg;k=k+1) config_transfer(cfg_op[k],cfg_row[k],cfg_word[k],cfg_bits[k],cfg_bias[k],cfg_scale[k],cfg_shift[k],cfg_zero[k],0);
  end
 endtask
 task start_frame;
  integer guard;
  begin
   sent=0;out_index=0;source_owned=0;s_valid=0;m_ready=0;rsp_ready=0;
   cmd_width=w;cmd_height=h;cmd_ci=ci;cmd_co=co;cmd_zero=xzero;cmd_tag=tag_value;cmd_valid=1;
   guard=0;while(!cmd_ready) begin tick();guard=guard+1;if(guard>1000)$fatal(1,"command blocked");end
   tick();cmd_valid=0;
  end
 endtask
 task pump(input integer target);
  integer target_found,source_row_units;
  begin
   cycle=0;target_found=0;source_row_units=w*(RGB?1:ci);
   while(!rsp_valid && !target_found) begin
    if((target==2 && internal_state==2) || (target==4 && internal_state==4) || (target==8 && m_valid)) target_found=1;
    else begin
     m_ready=target==8?0:((cycle%11)!=2 && (cycle%11)!=3 && (cycle%11)!=4);
     if(!source_owned) begin
      if(sent<nin && cycle%5!=1) begin
       s_valid=1;s_data=input_values[sent];s_sof=(sent==0);s_eol=((sent+1)%source_row_units==0);
       s_last=(sent==w*h*(RGB?1:ci)-1);
       if(sent==fault_index) begin s_sof=s_sof^fault_mask[0];s_eol=s_eol^fault_mask[1];s_last=s_last^fault_mask[2];end
       source_owned=1;
      end else s_valid=0;
     end
     tick();cycle=cycle+1;if(cycle>2000000)$fatal(1,"frame cycle budget case%0d",case_number);
    end
   end
   if(target>=0 && target!=6 && !target_found) $fatal(1,"reset target not reached");
   if(target<0 || target==6) begin s_valid=0;source_owned=0;m_ready=0;end
  end
 endtask
 task finish_frame(input integer future);
  integer guard;reg [TW-1:0] next_tag;
  begin
   if(rsp_error!==error_value || rsp_tag!==TW'(tag_value)) $fatal(1,"completion mismatch case%0d",case_number);
   if(rsp_outputs!==out_index || (!RGB && rsp_inputs!==sent)) $fatal(1,"public counter mismatch");
   if(error_value==0 && (out_index!=nout || sent!=nin)) $fatal(1,"incomplete good frame");
   if(error_value==3 && sent!=nin) $fatal(1,"bad sample count");
   if(error_value==1 && (sent!=0 || out_index!=0)) $fatal(1,"invalid command had data");
   next_tag=TW'(tag_value)^TW'(1);
   if(future) begin cmd_width=0;cmd_tag=next_tag;cmd_valid=1;end
   repeat(4) begin tick();if(!rsp_valid || cmd_ready || c_ready)$fatal(1,"completion fence released early");end
   rsp_ready=1;tick();rsp_ready=0;frames=frames+1;
   if(future) begin
    guard=0;while(!cmd_ready) begin tick();guard=guard+1;if(guard>1000)$fatal(1,"future command not accepted");end
    tick();cmd_valid=0;guard=0;
    while(!rsp_valid) begin tick();guard=guard+1;if(guard>1000)$fatal(1,"future response absent");end
    if(rsp_error!==3'd1 || rsp_tag!==next_tag || rsp_outputs!==0 || (!RGB && rsp_inputs!==0)) $fatal(1,"future response mismatch");
    repeat(3) tick();rsp_ready=1;tick();rsp_ready=0;future_probes=future_probes+1;
   end
   checking=0;tick();
  end
 endtask
 initial begin
  if(!$value$plusargs("VECTORS=%s",vector_file)) $fatal(1,"missing VECTORS");
  fd=$fopen(vector_file,"r");if(!fd)$fatal(1,"vector file missing");
  read_number();if(number!=1163462213)$fatal(1,"bad vector magic");read_number();ncases=number;
  reset_all();
  for(case_index=0;case_index<ncases;case_index=case_index+1) begin
   read_number();case_number=number;read_number();w=number;read_number();h=number;read_number();ci=number;read_number();co=number;
   read_number();xzero=number;read_number();tag_value=number;read_number();error_value=number;
   read_number();fault_index=number;read_number();fault_mask=number;read_number();clear_model=number;
   read_number();ncfg=number;read_number();nin=number;read_number();nout=number;
   if(ncfg<0 || ncfg>1024 || nin<0 || nin>16384 || nout<0 || nout>16384)$fatal(1,"vector bounds");
   for(i=0;i<ncfg;i=i+1) begin
    read_number();cfg_op[i]=number;read_number();cfg_row[i]=number;read_number();cfg_word[i]=number;read_number();cfg_bits[i]=number;
    read_number();cfg_bias[i]=number;read_number();cfg_scale[i]=number;read_number();cfg_shift[i]=number;read_number();cfg_zero[i]=number;
   end
   for(i=0;i<nin;i=i+1) begin read_number();input_values[i]=number;end
   for(i=0;i<nout;i=i+1) begin read_number();expected_data[i]=number;read_number();expected_clip[i]=number;read_number();expected_inexact[i]=number;end
   configure();
   if(case_index==1) begin
    config_transfer(3,0,0,0,0,0,0,0,2);config_transfer(0,65535,0,0,0,0,0,0,1);
    config_transfer(1,65535,0,0,0,0,0,0,1);config_transfer(0,0,65535,0,0,0,0,0,1);
   end
   checking=1;start_frame();pump(-1);finish_frame(case_index==1);
   if(case_index==1) begin
    for(j=0;j<4;j=j+1) begin
     configure();checking=0;start_frame();pump(j==0?2:j==1?4:j==2?8:6);
     reset_all();reset_probes=reset_probes+1;
     configure();checking=1;start_frame();pump(-1);finish_frame(0);
    end
   end
  end
  rc=$fscanf(fd,"%s",tail);if(rc==1)$fatal(1,"trailing vector token");$fclose(fd);
  if(reset_probes!=4 || future_probes!=1 || stall_cycles==0)$fatal(1,"coverage count mismatch");
  $display("PASS profile MC%0d MO%0d MW%0d RGB%0d cases=%0d frames=%0d resets=%0d future=%0d stalls=%0d",MC,MO,MW,RGB,ncases,frames,reset_probes,future_probes,stall_cycles);
  $finish;
 end
endmodule
