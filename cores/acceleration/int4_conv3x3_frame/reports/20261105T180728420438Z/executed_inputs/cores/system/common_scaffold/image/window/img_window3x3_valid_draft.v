// Two synchronous row memories, no frame array. Small-frame group checked.
// Outputs valid 3x3 windows only: a W x H source becomes (W-2) x (H-2).
// Native shared-CE protocol. One input issue + one processing beat (II >= 2).
// External memory/BRAM mapping, protocol and numerical behavior need validation.
module img_window3x3_valid_draft #(
    parameter PIXEL_W=8,
    parameter MAX_WIDTH=1920,
    parameter ADDR_W=(MAX_WIDTH<2)?1:$clog2(MAX_WIDTH)
)(
    input wire clk,rst_n,clk_en,
    input wire cfg_valid,
    output wire cfg_ready,
    input wire [15:0] cfg_width,cfg_height,
    output reg rsp_valid,
    input wire rsp_ready,
    output reg [3:0] rsp_error,
    input wire [PIXEL_W-1:0] s_data,
    input wire s_valid,s_sof,s_eol,
    output wire s_ready,
    output reg [9*PIXEL_W-1:0] m_taps,
    output reg [PIXEL_W-1:0] m_center,
    output reg [15:0] m_x,m_y,
    output reg m_valid,m_sof,m_eol,m_eof,
    input wire m_ready
);
localparam S_IDLE=0,S_RECEIVE=1,S_PROCESS=2,S_DRAIN=3;
reg [1:0] state;
reg [15:0] width,height,x,y;
reg frame_error;
reg [PIXEL_W-1:0] input_pixel;
reg [PIXEL_W-1:0] top0,top1,mid0,mid1,bot0,bot1;
reg [PIXEL_W-1:0] line1_q,line2_q;
(* ram_style="block", syn_ramstyle="block_ram" *)
reg [PIXEL_W-1:0] line1[0:MAX_WIDTH-1];
(* ram_style="block", syn_ramstyle="block_ram" *)
reg [PIXEL_W-1:0] line2[0:MAX_WIDTH-1];
wire output_slot = !m_valid || m_ready;
wire input_fire = s_valid && s_ready;
wire process_fire = rst_n && clk_en && state==S_PROCESS && output_slot;
assign cfg_ready = rst_n && clk_en && state==S_IDLE && !rsp_valid;
assign s_ready = rst_n && clk_en && state==S_RECEIVE;

// No reset on memory or read data, for synchronous RAM inference.
// At y>=2 both older rows have been written in this frame. Stale reset data
// is never published as a valid window. Address x is held through PROCESS.
always @(posedge clk) begin
    if(rst_n && clk_en) begin
        if(input_fire) begin
            line1_q <= line1[x[ADDR_W-1:0]];
            line2_q <= line2[x[ADDR_W-1:0]];
        end
        if(process_fire) begin
            line1[x[ADDR_W-1:0]] <= input_pixel;
            line2[x[ADDR_W-1:0]] <= line1_q;
        end
    end
end
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        state<=S_IDLE;width<=0;height<=0;x<=0;y<=0;frame_error<=0;
        input_pixel<=0;top0<=0;top1<=0;mid0<=0;mid1<=0;bot0<=0;bot1<=0;
        rsp_valid<=0;rsp_error<=0;m_taps<=0;m_center<=0;m_x<=0;m_y<=0;
        m_valid<=0;m_sof<=0;m_eol<=0;m_eof<=0;
    end else if(clk_en) begin
        if(rsp_valid && rsp_ready) rsp_valid<=0;
        if(m_valid && m_ready) m_valid<=0;
        case(state)
          S_IDLE: if(cfg_valid && cfg_ready) begin
              frame_error<=0;x<=0;y<=0;
              if(cfg_width<3 || cfg_height<3 || cfg_width>MAX_WIDTH || MAX_WIDTH>65535 ||
                 MAX_WIDTH>(32'd1<<ADDR_W) || ADDR_W<1 || ADDR_W>16) begin
                  rsp_valid<=1;rsp_error<=4'd1;
              end else begin
                  width<=cfg_width;height<=cfg_height;state<=S_RECEIVE;
                  top0<=0;top1<=0;mid0<=0;mid1<=0;bot0<=0;bot1<=0;
              end
          end
          S_RECEIVE: if(input_fire) begin
              input_pixel<=s_data;
              if(s_sof !== ((x==0)&&(y==0)) || s_eol !== (x==width-1)) frame_error<=1;
              state<=S_PROCESS;
          end
          S_PROCESS: if(output_slot) begin
              // Old history values supply columns x-2 and x-1; read q is x.
              top0<=top1;top1<=line2_q;
              mid0<=mid1;mid1<=line1_q;
              bot0<=bot1;bot1<=input_pixel;
              if(x>=2 && y>=2) begin
                  m_taps <= {input_pixel,bot1,bot0,line1_q,mid1,mid0,line2_q,top1,top0};
                  m_center<=mid1;m_x<=x-1'b1;m_y<=y-1'b1;
                  m_sof<=(x==2 && y==2);m_eol<=(x==width-1);
                  m_eof<=(x==width-1 && y==height-1);m_valid<=1;
              end
              if(x==width-1) begin
                  x<=0;
                  if(y==height-1) state<=S_DRAIN;
                  else begin y<=y+1'b1;state<=S_RECEIVE;end
              end else begin x<=x+1'b1;state<=S_RECEIVE;end
          end
          S_DRAIN: if(m_valid && m_ready && m_eof) begin
              rsp_valid<=1;rsp_error<=frame_error ? 4'd2 : 4'd0;state<=S_IDLE;
          end
          default: begin state<=S_IDLE;rsp_valid<=1;rsp_error<=4'd3;end
        endcase
    end
end
endmodule
