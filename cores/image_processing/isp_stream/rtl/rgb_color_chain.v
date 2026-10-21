// Frame-serialized configuration, canonical AWB -> CCM -> synchronous gamma.
module rgb_color_chain(
 input wire clk,rst_n,cmd_valid,output wire cmd_ready,
 input wire [47:0] cmd_gains,input wire [191:0] cmd_matrix,input wire cmd_gamma_enable,
 input wire lut_valid,output wire lut_ready,input wire [1:0] lut_channel,
 input wire [7:0] lut_address,lut_value,
 input wire s_valid,output wire s_ready,input wire [23:0] s_data,
 input wire s_sof,s_eol,s_eof,input wire [15:0] s_frame_id,
 output wire m_valid,input wire m_ready,output wire [23:0] m_data,
 output wire m_sof,m_eol,m_eof,output wire [15:0] m_frame_id,
 output wire rsp_valid,input wire rsp_ready,output reg [3:0] rsp_error,
 output wire drained
);
 localparam IDLE=0,LOAD=1,COMMIT=2,RUN=3,DONE=4;
 reg [2:0] state;
 reg [47:0] gains;
 reg [191:0] matrix;
 reg gamma_enable,input_finished,first_pixel,gamma_commit_needed,lut_dirty;
 reg [3:0] index;
 wire ar,cr,gr,ap,cp,gp,ce,ge;
 wire [2:0] complete;
 wire gamma_active_enable;
 wire [23:0] ad,cd,gd;
 wire av,asof,aeol,acready,cv,csof,ceol,cgready,gv,gsof,geol,gready,cr_input;
 assign cmd_ready=rst_n&&state==IDLE&&ar&&cr&&gr&&!lut_valid;
 assign lut_ready=rst_n&&state==IDLE&&gr;
 assign rsp_valid=rst_n&&state==DONE;
 // Metadata FIFO covers the sum of elastic stages, with explicit admission.
 (* ram_style="logic" *) reg [18:0] metadata[0:15];
 reg [3:0] wp,rp;reg [4:0] count;
 assign drained=count==0;
 wire pop=m_valid&&m_ready;
 wire space=count<16||pop;
 wire admitted=state==RUN&&!input_finished&&space;
 wire push=s_valid&&s_ready;
 wire [18:0] head=metadata[rp];
 assign s_ready=rst_n&&admitted&&acready;
 assign m_valid=gv&&count!=0;
 assign gready=m_ready&&count!=0;
 assign m_data=gd;assign m_sof=gsof;assign m_eol=geol;
 assign m_eof=head[2];assign m_frame_id=head[18:3];
 img_isp_awb_gain awb(clk,rst_n,1'b1,s_data,s_valid&&admitted,acready,s_sof,s_eol,
  ad,av,cr_input,asof,aeol,state==COMMIT,state==COMMIT,
  gains[15:0],gains[31:16],gains[47:32],ar,ap);
 img_isp_ccm ccm(clk,rst_n,1'b1,ad,av,cr_input,asof,aeol,
  cd,cv,cgready,csof,ceol,state==LOAD,state==COMMIT,index,matrix[index*16+:16],cr,cp,ce);
 img_isp_gamma_lut gamma(clk,rst_n,1'b1,cd,cv,cgready,csof,ceol,
  gd,gv,gready,gsof,geol,lut_valid&&state==IDLE,lut_channel,lut_address,lut_value,
  state==COMMIT&&gamma_commit_needed,gamma_enable,gr,gp,ge,complete,gamma_active_enable);
 always @(posedge clk)if(push)metadata[wp]<={s_frame_id,s_eof,s_eol,s_sof};
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin state<=IDLE;gains<=0;matrix<=0;gamma_enable<=0;index<=0;
   input_finished<=0;first_pixel<=1;wp<=0;rp<=0;count<=0;rsp_error<=0;gamma_commit_needed<=0;lut_dirty<=0;end
  else begin
   if(lut_valid&&lut_ready)lut_dirty<=1;
   if(state==COMMIT&&gamma_commit_needed)lut_dirty<=0;
   if(push)wp<=wp+1'b1;
   if(pop)rp<=rp+1'b1;
   case({push,pop})2'b10:count<=count+1'b1;2'b01:count<=count-1'b1;endcase
   if(push)begin
    if(s_sof!=first_pixel||(s_eof&&!s_eol))rsp_error<=4'd9;
    first_pixel<=0;if(s_eof)input_finished<=1;
   end
   if(pop&&{gsof,geol}!={head[0],head[1]})rsp_error<=4'd10;
   case(state)
    IDLE:if(cmd_valid&&cmd_ready)begin
     rsp_error<=0;
     if(ce||ge||(cmd_gamma_enable&&complete!=7&&(!gamma_active_enable||lut_dirty)))begin rsp_error<=8;state<=DONE;end
     else begin gains<=cmd_gains;matrix<=cmd_matrix;gamma_enable<=cmd_gamma_enable;
      gamma_commit_needed<=(cmd_gamma_enable!=gamma_active_enable)||(cmd_gamma_enable&&complete==7);
      input_finished<=0;first_pixel<=1;index<=0;state<=LOAD;end
    end
    LOAD:begin if(index==11)state<=COMMIT;else index<=index+1'b1;end
    COMMIT:state<=RUN;
    RUN:if(pop&&m_eof)state<=DONE;
    DONE:if(rsp_ready)state<=IDLE;
   endcase
  end
 end
endmodule
