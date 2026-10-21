// Integer backward warp. Ordered block origins match img_block_motion results.
module motion_compensation #(
 parameter WIDTH=16,HEIGHT=12,BITS=8,BLOCK_W=8,BLOCK_H=8
)(
 input wire clk,rst_n,ce,
 input wire [BITS-1:0] s_pixel,input wire s_valid,s_sof,s_eol,output wire s_ready,
 input wire vector_valid,output wire vector_ready,
 input wire [15:0] vector_x,vector_y,vector_width,vector_height,
 input wire signed [15:0] vector_dx,vector_dy,input wire vector_invalid,
 input wire start_valid,output wire start_ready,input wire [BITS-1:0] fill_pixel,
 input wire release_valid,output wire release_ready,
 output reg m_valid,input wire m_ready,output reg [BITS-1:0] m_pixel,
 output wire [15:0] m_x,m_y,output wire m_sof,m_eol,m_last,
 output reg m_invalid,output reg [1:0] m_reason,
 output wire done_valid,
 output reg error,output reg [3:0] error_code,
 output reg [16:0] reference_count,vector_count
);
 localparam [63:0] TOTAL=64'd1*WIDTH*HEIGHT;
 localparam N=(TOTAL>=1&&TOTAL<=65536)?TOTAL:1;
 localparam COLS=BLOCK_W>0?(WIDTH+BLOCK_W-1)/BLOCK_W:1;
 localparam ROWS=BLOCK_H>0?(HEIGHT+BLOCK_H-1)/BLOCK_H:1;
 localparam GRID=(COLS*ROWS>=1&&COLS*ROWS<=65536)?COLS*ROWS:1;
 localparam LOAD=0,VREAD=1,RREAD=2,PRESENT=3,HOLD=4,FINISH=5;
 reg [2:0] state;
 reg [BITS-1:0] frame[0:N-1],pixel_q,fill_snapshot;
 reg [32:0] vectors[0:GRID-1],vq;
 reg [15:0] capture_x,capture_y,expect_x,expect_y,x,y;
 reg pending_invalid;reg [1:0] pending_reason;
 wire [15:0] actual_w=WIDTH-expect_x<BLOCK_W?WIDTH-expect_x:BLOCK_W;
 wire [15:0] actual_h=HEIGHT-expect_y<BLOCK_H?HEIGHT-expect_y:BLOCK_H;
 wire geometry_ok=vector_x==expect_x&&vector_y==expect_y&&vector_width==actual_w&&vector_height==actual_h;
 wire signed [31:0] rx=$signed({1'b0,x})+$signed(vq[15:0]);
 wire signed [31:0] ry=$signed({1'b0,y})+$signed(vq[31:16]);
 wire outside=rx<0||ry<0||rx>=WIDTH||ry>=HEIGHT;
 wire [31:0] address=ry*WIDTH+rx;
 wire [31:0] vector_address=(y/BLOCK_H)*COLS+x/BLOCK_W;
 assign s_ready=rst_n&&ce&&state==LOAD&&!start_valid;
 assign vector_ready=rst_n&&ce&&state==LOAD&&!start_valid;
 assign start_ready=rst_n&&ce&&state==LOAD;
 assign release_ready=rst_n&&ce&&state==FINISH;
 assign done_valid=state==FINISH;
 assign m_x=x;assign m_y=y;
 assign m_sof=m_valid&&x==0&&y==0;
 assign m_eol=m_valid&&x==WIDTH-1;
 assign m_last=m_valid&&x==WIDTH-1&&y==HEIGHT-1;
 initial begin
  if(WIDTH<1||HEIGHT<1||WIDTH>65535||HEIGHT>65535||TOTAL>65536||BITS<8||BITS>12||BLOCK_W<1||BLOCK_H<1||BLOCK_W>64||BLOCK_H>64)$fatal(1,"invalid motion compensation parameters");
 end
 // Memory writes and reads are synchronous; memory contents need no reset.
 always @(posedge clk)if(rst_n&&ce)begin
  if(state==LOAD&&!start_valid)begin
   if(s_valid&&reference_count<N&&s_sof==(reference_count==0)&&s_eol==(capture_x==WIDTH-1))frame[reference_count]<=s_pixel;
   if(vector_valid&&vector_count<GRID&&geometry_ok)vectors[vector_count]<={vector_invalid,vector_dy,vector_dx};
  end
  if(state==VREAD)vq<=vectors[vector_address];
  if(state==RREAD&&!outside&&!vq[32])pixel_q<=frame[address];
 end
 always @(posedge clk)begin
  if(!rst_n)begin
   state<=LOAD;reference_count<=0;vector_count<=0;capture_x<=0;capture_y<=0;expect_x<=0;expect_y<=0;x<=0;y<=0;
   m_valid<=0;m_pixel<=0;m_invalid<=0;m_reason<=0;pending_invalid<=0;pending_reason<=0;error<=0;error_code<=0;fill_snapshot<=0;
  end else if(ce)begin
   error<=0;
   case(state)
    LOAD:begin
     if(start_valid)begin
      if(reference_count!=N)begin error<=1;error_code<=1;end
      else if(vector_count!=GRID)begin error<=1;error_code<=2;end
      else begin fill_snapshot<=fill_pixel;x<=0;y<=0;state<=VREAD;end
     end else begin
      if(s_valid)begin
       if(reference_count==N)begin error<=1;error_code<=4;end
       else if(s_sof!=(reference_count==0)||s_eol!=(capture_x==WIDTH-1))begin error<=1;error_code<=5;end
       else begin
        reference_count<=reference_count+1'b1;
        if(capture_x==WIDTH-1)begin capture_x<=0;capture_y<=capture_y+1'b1;end else capture_x<=capture_x+1'b1;
       end
      end
      if(vector_valid)begin
       if(vector_count==GRID)begin error<=1;error_code<=4;end
       else if(!geometry_ok)begin error<=1;error_code<=3;end
       else begin
        vector_count<=vector_count+1'b1;
        if(expect_x+BLOCK_W>=WIDTH)begin expect_x<=0;expect_y<=expect_y+BLOCK_H;end else expect_x<=expect_x+BLOCK_W;
       end
      end
     end
    end
    VREAD:state<=RREAD;
    RREAD:begin pending_invalid<=outside||vq[32];pending_reason<={outside,vq[32]};state<=PRESENT;end
    PRESENT:begin m_pixel<=pending_invalid?fill_snapshot:pixel_q;m_invalid<=pending_invalid;m_reason<=pending_reason;m_valid<=1;state<=HOLD;end
    HOLD:if(m_ready)begin
     m_valid<=0;
     if(x==WIDTH-1&&y==HEIGHT-1)state<=FINISH;
     else begin if(x==WIDTH-1)begin x<=0;y<=y+1'b1;end else x<=x+1'b1;state<=VREAD;end
    end
    FINISH:if(release_valid)begin
     reference_count<=0;vector_count<=0;capture_x<=0;capture_y<=0;expect_x<=0;expect_y<=0;error_code<=0;state<=LOAD;
    end
    default:begin m_valid<=0;state<=FINISH;error<=1;error_code<=6;end
   endcase
  end
 end
endmodule
