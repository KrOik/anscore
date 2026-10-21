// Synchronous descriptor queue. Capacity includes the registered output slot.
// Descriptor: {frame_id16,source1,destination1,base_byte_address32,word_count16}.
module frame_descriptor_ring #(parameter DEPTH=8,parameter RAM_STYLE="auto")(
 input wire clk,rst_n,input wire [65:0] s_descriptor,input wire s_valid,
 output wire s_ready,output reg [65:0] m_descriptor,output reg m_valid,
 input wire m_ready,output reg [$clog2(DEPTH):0] occupancy,
 output reg [$clog2(DEPTH):0] high_water,output reg [31:0] blocked_cycles
);
 localparam AW=$clog2(DEPTH);
 (* ram_style=RAM_STYLE *) reg [65:0] memory[0:DEPTH-1];
 reg [AW-1:0] wp,rp;
 reg [AW:0] unread;
 wire pop=m_valid&&m_ready;
 assign s_ready=rst_n&&(occupancy<DEPTH||pop);
 wire push=s_valid&&s_ready;
 wire fetch=unread!=0&&(!m_valid||m_ready);
 wire [AW:0] next_occupancy=occupancy+push-pop;
 always @(posedge clk)begin
  if(push)memory[wp]<=s_descriptor;
  if(fetch)m_descriptor<=memory[rp];
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   wp<=0;rp<=0;unread<=0;occupancy<=0;high_water<=0;blocked_cycles<=0;m_valid<=0;
  end else begin
   occupancy<=next_occupancy;
   if(next_occupancy>high_water)high_water<=next_occupancy;
   if(s_valid&&!s_ready)blocked_cycles<=blocked_cycles+1'b1;
   if(push)wp<=wp+1'b1;
   if(fetch)begin rp<=rp+1'b1;m_valid<=1;end
   else if(pop)m_valid<=0;
   case({push,fetch})
    2'b10:unread<=unread+1'b1;
    2'b01:unread<=unread-1'b1;
    default:begin end
   endcase
  end
 end
 initial if(DEPTH<2||(DEPTH&(DEPTH-1))!=0||DEPTH>256)$fatal(1,"invalid descriptor ring depth");
endmodule
