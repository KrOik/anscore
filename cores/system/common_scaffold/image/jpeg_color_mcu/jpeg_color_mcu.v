// RGB8 -> exact full-range BT.601 sample blocks, runtime JPEG 444/420 MCU order.
module jpeg_color_mcu #(parameter WIDTH=16,HEIGHT=16)(
 input wire clk,rst_n,ce,start_valid,output wire start_ready,input wire cfg_sampling_420,
 input wire[23:0] s_rgb,input wire s_valid,s_sof,s_eol,output wire s_ready,
 output wire[7:0] m_data,output wire m_valid,input wire m_ready,
 output wire[1:0] m_component,output wire m_block_first,m_block_last,m_frame_last,m_mcu_last,
 output wire[31:0] m_mcu_index,output wire done_valid,input wire done_ready,
 output reg[3:0] error_code,output wire busy
);
 localparam[63:0] TOTAL=64'd1*WIDTH*HEIGHT;
 localparam N=TOTAL>=1&&TOTAL<=65536?TOTAL:1,AW=N<2?1:$clog2(N);
 localparam IDLE=0,CAPTURE=1,EVALUATE=2,ADDRESS=3,READ=4,CONVERT=5,OUTPUT=6,DONE=7;
 reg[2:0] state;reg sampling420;
 reg[23:0] pixels[0:N-1],pixel_q;
 reg[AW-1:0] capture_addr,read_addr;
 reg[15:0] capture_x,capture_y,mcu_x,mcu_y;
 reg[2:0] block;reg[5:0] sample;
 reg[1:0] subsample;reg[9:0] chroma_sum;
 reg[7:0] output_data;reg[31:0] mcu_index;
 integer source_x,source_y,base_x,base_y,mcu_width,mcu_height,component;
 wire last_mcu=mcu_x==mcu_width-1&&mcu_y==mcu_height-1;
 wire last_block=block==(sampling420?5:2);
 wire chroma=sampling420&&block>=4;
 wire[7:0] converted=component==0?rgb_y(pixel_q):component==1?rgb_cb(pixel_q):rgb_cr(pixel_q);
 function signed[31:0] constant_product;
 input[7:0] p;input integer coefficient;integer i;reg[31:0] sum;
 begin sum=0;for(i=0;i<16;i=i+1)if((coefficient>>i)&1)sum=sum+({24'b0,p}<<i);constant_product=sum;end
 endfunction
 function[7:0] clamp8;input signed[31:0] v;
 begin clamp8=v<0?0:(v>255?255:v);end endfunction
 function[7:0] rgb_y;input[23:0] p;reg signed[31:0] v;begin
 v=constant_product(p[23:16],19595)+constant_product(p[15:8],38470)+constant_product(p[7:0],7471)+32768;
 rgb_y=clamp8(v>>>16);end endfunction
 function[7:0] rgb_cb;input[23:0] p;reg signed[31:0] v;begin
 v= -constant_product(p[23:16],11059)-constant_product(p[15:8],21709)+constant_product(p[7:0],32768)+8421376;
 rgb_cb=clamp8(v>>>16);end endfunction
 function[7:0] rgb_cr;input[23:0] p;reg signed[31:0] v;begin
 v=constant_product(p[23:16],32768)-constant_product(p[15:8],27439)-constant_product(p[7:0],5329)+8421376;
 rgb_cr=clamp8(v>>>16);end endfunction
 function[AW-1:0] row_address;input integer row;integer i;reg[31:0] sum;
 begin sum=0;for(i=0;i<17;i=i+1)if((WIDTH>>i)&1)sum=sum+(row<<i);row_address=sum;end endfunction
 assign start_ready=rst_n&&ce&&state==IDLE;assign s_ready=rst_n&&ce&&state==CAPTURE;
 assign m_valid=rst_n&&state==OUTPUT;assign m_data=output_data;
 assign m_component=component;assign m_block_first=m_valid&&sample==0;
 assign m_block_last=m_valid&&sample==63;
 assign m_mcu_last=m_block_last&&last_block;assign m_frame_last=m_mcu_last&&last_mcu;
 assign m_mcu_index=mcu_index;assign done_valid=rst_n&&state==DONE;assign busy=state!=IDLE;
 initial if(WIDTH<1||HEIGHT<1||WIDTH>65536||HEIGHT>65536||TOTAL>65536)$fatal(1,"invalid JPEG color MCU geometry");
 always @* begin
 mcu_width=sampling420?(WIDTH+15)/16:(WIDTH+7)/8;
 mcu_height=sampling420?(HEIGHT+15)/16:(HEIGHT+7)/8;
 component=sampling420?(block<4?0:(block==4?1:2)):block;
 base_x=sampling420?($unsigned(mcu_x)<<4):($unsigned(mcu_x)<<3);
 base_y=sampling420?($unsigned(mcu_y)<<4):($unsigned(mcu_y)<<3);
 if(sampling420&&block<4)begin source_x=base_x+((block==1||block==3)?8:0)+(sample&7);source_y=base_y+(block>=2?8:0)+(sample>>3);end
 else if(chroma)begin source_x=base_x+((sample&7)<<1)+subsample[0];source_y=base_y+((sample>>3)<<1)+subsample[1];end
 else begin source_x=base_x+(sample&7);source_y=base_y+(sample>>3);end
 if(source_x>=WIDTH)source_x=WIDTH-1;if(source_y>=HEIGHT)source_y=HEIGHT-1;
 end
 always @(posedge clk)if(ce&&rst_n)begin
 if(state==CAPTURE&&s_valid)pixels[capture_addr]<=s_rgb;
 if(state==READ)pixel_q<=pixels[read_addr];
 end
 always @(posedge clk)begin
 if(!rst_n)begin state<=IDLE;sampling420<=0;capture_addr<=0;read_addr<=0;capture_x<=0;capture_y<=0;mcu_x<=0;mcu_y<=0;block<=0;sample<=0;subsample<=0;chroma_sum<=0;output_data<=0;mcu_index<=0;error_code<=0;end
 else if(ce)case(state)
 IDLE:if(start_valid)begin sampling420<=cfg_sampling_420;capture_addr<=0;capture_x<=0;capture_y<=0;error_code<=0;state<=CAPTURE;end
 CAPTURE:if(s_valid)begin
 if(s_sof!=(capture_addr==0)||s_eol!=(capture_x==WIDTH-1))error_code[0]<=1;
 if(capture_addr==N-1)state<=EVALUATE;else begin capture_addr<=capture_addr+1'b1;if(capture_x==WIDTH-1)begin capture_x<=0;capture_y<=capture_y+1'b1;end else capture_x<=capture_x+1'b1;end end
 EVALUATE:if(error_code!=0)state<=DONE;else begin mcu_x<=0;mcu_y<=0;mcu_index<=0;block<=0;sample<=0;subsample<=0;chroma_sum<=0;state<=ADDRESS;end
 ADDRESS:begin read_addr<=row_address(source_y)+source_x;state<=READ;end
 READ:state<=CONVERT;
 CONVERT:if(chroma)begin
 if(subsample==3)begin output_data<=(chroma_sum+{2'b0,converted}+10'd2)>>2;state<=OUTPUT;end
 else begin chroma_sum<=chroma_sum+{2'b0,converted};subsample<=subsample+1'b1;state<=ADDRESS;end
 end else begin output_data<=converted;state<=OUTPUT;end
 OUTPUT:if(m_ready)begin
 subsample<=0;chroma_sum<=0;
 if(sample==63)begin sample<=0;if(last_block)begin block<=0;if(last_mcu)state<=DONE;else begin mcu_index<=mcu_index+1'b1;if(mcu_x==mcu_width-1)begin mcu_x<=0;mcu_y<=mcu_y+1'b1;end else mcu_x<=mcu_x+1'b1;state<=ADDRESS;end end else begin block<=block+1'b1;state<=ADDRESS;end end
 else begin sample<=sample+1'b1;state<=ADDRESS;end end
 DONE:if(done_ready)state<=IDLE;
 endcase end
endmodule
