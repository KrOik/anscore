// Four physical slots, two writers and two readers. Payload memory is external.
// Publish only after write completion; release only after read completion.
module frame_slot_manager #(parameter SLOT_WORDS=256,parameter FIXED_PINGPONG=1)(
 input wire clk,rst_n,input wire [1:0] w_valid,w_destination,
 input wire [31:0] w_frame_id,w_length,output reg [1:0] w_ready,
 output reg [1:0] a_valid,a_error,output reg [63:0] a_base,
 input wire [1:0] a_ready,input wire [1:0] w_done,w_error,output reg [1:0] w_done_ready,
 output wire [1:0] d_valid,output wire [131:0] d_descriptor,input wire [1:0] d_ready,
 input wire [1:0] r_done,r_error,output wire [1:0] r_done_ready,
 output reg [31:0] published,released,aborted,invalid_requests,
 output reg [63:0] latency_last,latency_min,latency_max,latency_sum,
 output reg [31:0] elapsed_cycles,allocation_stalls,output reg [2:0] peak_occupied
);
 localparam FREE=0,WRITING=1,QUEUED=2,READING=3;
 reg [1:0] state[0:3],writer_slot[0:1],reader_slot[0:1];
 reg [1:0] writer_has,reader_has;
 reg [65:0] descriptor[0:3];
 reg alloc_turn,commit_turn;
 reg [1:0] next_bank;
 reg [31:0] allocation_time[0:3];
 reg [1:0] latency_pending;
 reg [63:0] latency_delta;
 reg [2:0] occupied;
 integer oc;
 always @*begin
  occupied=0;
  for(oc=0;oc<4;oc=oc+1)if(state[oc]!=FREE)occupied=occupied+1'b1;
 end
 reg free_found,alloc_found,commit_found;
 reg [1:0] free_slot,alloc_slot;
 reg alloc_writer,commit_writer;
 wire [1:0] q_ready,q_valid,q_pop;
 wire [131:0] q_data;
 reg [1:0] q_push;
 reg [65:0] publish_data;
 integer i,j,index;
 wire [15:0] selected_length=w_length[alloc_writer*16+:16];
 wire allocation_bad=selected_length==0||selected_length>SLOT_WORDS;
 always @*begin
  free_found=0;free_slot=0;
  for(i=0;i<4;i=i+1)if(!free_found&&state[i]==FREE)begin free_found=1;free_slot=i;end
  alloc_found=0;alloc_writer=0;alloc_slot=0;w_ready=0;index=0;
  for(j=0;j<2;j=j+1)begin
   index=(alloc_turn+j)&1;
   if(!alloc_found&&w_valid[index]&&!writer_has[index]&&!a_valid[index]&&
     ((FIXED_PINGPONG?state[index*2+next_bank[index]]==FREE:free_found)||
       w_length[index*16+:16]==0||w_length[index*16+:16]>SLOT_WORDS))begin
    alloc_found=1;alloc_writer=index;w_ready[index]=rst_n;
    alloc_slot=FIXED_PINGPONG?index*2+next_bank[index]:free_slot;
   end
  end
  commit_found=0;commit_writer=0;w_done_ready=0;q_push=0;publish_data=0;
  for(j=0;j<2;j=j+1)begin
   index=(commit_turn+j)&1;
   if(!commit_found&&w_done[index]&&writer_has[index]&&!a_valid[index]&&
      (w_error[index]||q_ready[descriptor[writer_slot[index]][48]]))begin
    commit_found=1;commit_writer=index;w_done_ready[index]=rst_n;
   end
  end
  if(commit_found&&!w_error[commit_writer]&&rst_n)begin
   publish_data=descriptor[writer_slot[commit_writer]];
   q_push[publish_data[48]]=1;
  end
 end
 genvar c;
 generate for(c=0;c<2;c=c+1)begin: queues
  // GW5A-25 nextpnr has no placeable RAM16SDP4 BEL. Force the synchronous
  // queue to BSRAM rather than relying on automatic small-memory inference.
  frame_descriptor_ring #(.DEPTH(4),.RAM_STYLE("block")) ring(clk,rst_n,publish_data,q_push[c],q_ready[c],
   q_data[c*66+:66],q_valid[c],q_pop[c],,,);
  assign d_valid[c]=q_valid[c]&&!reader_has[c];
  assign d_descriptor[c*66+:66]=q_data[c*66+:66];
  assign q_pop[c]=d_ready[c]&&!reader_has[c];
  assign r_done_ready[c]=rst_n&&reader_has[c];
 end endgenerate
 integer k;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   writer_has<=0;reader_has<=0;a_valid<=0;a_error<=0;a_base<=0;
   alloc_turn<=0;commit_turn<=0;next_bank<=0;published<=0;released<=0;aborted<=0;invalid_requests<=0;
   elapsed_cycles<=0;allocation_stalls<=0;peak_occupied<=0;
   latency_last<=0;latency_min<=64'hffffffffffffffff;latency_max<=0;latency_sum<=0;
   latency_pending<=0;latency_delta<=0;
   for(k=0;k<4;k=k+1)allocation_time[k]<=0;
   for(k=0;k<4;k=k+1)begin state[k]<=FREE;descriptor[k]<=0;end
   for(k=0;k<2;k=k+1)begin writer_slot[k]<=0;reader_slot[k]<=0;end
  end else begin
   latency_pending<=r_done&r_done_ready&~r_error;
   elapsed_cycles<=elapsed_cycles+1'b1;
   allocation_stalls<=allocation_stalls+{31'd0,w_valid[0]&&!w_ready[0]}+{31'd0,w_valid[1]&&!w_ready[1]};
   if(occupied>peak_occupied)peak_occupied<=occupied;
   for(k=0;k<2;k=k+1)begin
    // Separate timestamp subtraction from sum/min/max update. Physical
    // lifetime endpoints are unchanged; telemetry commits one clock later.
    if(latency_pending[k])begin
     latency_last[k*32+:32]<=latency_delta[k*32+:32];
     latency_sum[k*32+:32]<=latency_sum[k*32+:32]+latency_delta[k*32+:32];
     if(latency_delta[k*32+:32]<latency_min[k*32+:32])latency_min[k*32+:32]<=latency_delta[k*32+:32];
     if(latency_delta[k*32+:32]>latency_max[k*32+:32])latency_max[k*32+:32]<=latency_delta[k*32+:32];
    end
    if(a_valid[k]&&a_ready[k])a_valid[k]<=0;
    if(d_valid[k]&&d_ready[k])begin
     // Base addresses are generated here; division is by a power of two.
     reader_slot[k]<=q_data[k*66+16+:32]/(SLOT_WORDS*4);
     state[q_data[k*66+16+:32]/(SLOT_WORDS*4)]<=READING;reader_has[k]<=1;
    end
    if(r_done[k]&&r_done_ready[k])begin
     state[reader_slot[k]]<=FREE;reader_has[k]<=0;
     if(!r_error[k])begin
      latency_delta[k*32+:32]<=elapsed_cycles-allocation_time[reader_slot[k]];
     end
    end
   end
   released<=released+{31'd0,r_done[0]&&r_done_ready[0]}+{31'd0,r_done[1]&&r_done_ready[1]};
   aborted<=aborted+{31'd0,r_done[0]&&r_done_ready[0]&&r_error[0]}+
    {31'd0,r_done[1]&&r_done_ready[1]&&r_error[1]}+
    {31'd0,commit_found&&w_error[commit_writer]};
   if(alloc_found)begin
    alloc_turn<=~alloc_writer;a_valid[alloc_writer]<=1;a_error[alloc_writer]<=allocation_bad;
    a_base[alloc_writer*32+:32]<=allocation_bad?32'd0:alloc_slot*(SLOT_WORDS*4);
    if(allocation_bad)invalid_requests<=invalid_requests+1'b1;
    else begin
     allocation_time[alloc_slot]<=elapsed_cycles;
     next_bank[alloc_writer]<=~next_bank[alloc_writer];
     state[alloc_slot]<=WRITING;writer_has[alloc_writer]<=1;writer_slot[alloc_writer]<=alloc_slot;
     descriptor[alloc_slot]<={w_frame_id[alloc_writer*16+:16],alloc_writer,w_destination[alloc_writer],
       (32'd0+alloc_slot*(SLOT_WORDS*32'd4)),selected_length};
    end
   end
   if(commit_found)begin
    commit_turn<=~commit_writer;writer_has[commit_writer]<=0;
    if(w_error[commit_writer])state[writer_slot[commit_writer]]<=FREE;
    else begin state[writer_slot[commit_writer]]<=QUEUED;published<=published+1'b1;end
   end
  end
 end
 initial if(SLOT_WORDS<1||(SLOT_WORDS&(SLOT_WORDS-1))!=0||SLOT_WORDS>32768)$fatal(1,"invalid slot size");
endmodule
