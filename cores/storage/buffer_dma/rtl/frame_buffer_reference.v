// Single-clock two-producer/two-consumer BSRAM frame buffer.
// Metadata request precedes payload. Full-word packets only; see word_dma.md.
module frame_buffer_reference #(parameter SLOT_WORDS=256, FIXED_PINGPONG=1)(
 input wire clk,rst_n,
 input wire [1:0] w_valid,w_destination,input wire [31:0] w_frame_id,w_length,
 output wire [1:0] w_ready,
 input wire [1:0] s_valid,input wire [63:0] s_data,input wire [7:0] s_keep,
 input wire [1:0] s_last,output wire [1:0] s_ready,
 output wire [1:0] complete_valid,complete_error,input wire [1:0] complete_ready,
 output wire [1:0] m_valid,input wire [1:0] m_ready,
 output wire [63:0] m_data,output wire [7:0] m_keep,output wire [1:0] m_last,
 output wire [131:0] m_descriptor,
 output wire [31:0] published,released,aborted,invalid_requests,
 output wire [127:0] requests,completions,memory_stalls,
 output wire [127:0] stream_bytes,stream_frames,stream_stalls,stream_crc32,
 output wire [127:0] last_frame_cycles,last_frame_crc32,
 output wire [63:0] latency_last,latency_min,latency_max,latency_sum,
 output wire [31:0] elapsed_cycles,allocation_stalls,output wire [2:0] peak_occupied,
 input wire csr_valid,csr_write,input wire [7:0] csr_addr,
 input wire [31:0] csr_data,input wire [3:0] csr_strobe,
 output wire csr_ready,csr_resp_valid,csr_resp_error,
 output wire [31:0] csr_resp_data,input wire csr_resp_ready
);
 // Word0 is at the low end: fixed schema documented in csr_map.md.
 wire [1631:0] live_metrics={29'd0,peak_occupied,allocation_stalls,elapsed_cycles,
  latency_sum,latency_max,latency_min,latency_last,
  last_frame_crc32,last_frame_cycles,stream_crc32,stream_stalls,stream_frames,stream_bytes,
  memory_stalls,completions,requests,invalid_requests,aborted,released,published};
 csr_metrics_snapshot #(.WORDS(51)) telemetry(clk,rst_n,live_metrics,
  csr_valid,csr_write,csr_addr,csr_data,csr_strobe,csr_ready,
  csr_resp_valid,csr_resp_error,csr_resp_data,csr_resp_ready);
 wire [1:0] av,ae,ar,wd,we,wdr,dv,dr,rd,re,rdr,mwr;
 wire [63:0] ab;wire [131:0] dd;
 wire [1:0] alloc_valid;
 frame_slot_manager #(.SLOT_WORDS(SLOT_WORDS),.FIXED_PINGPONG(FIXED_PINGPONG)) slots(
 clk,rst_n,alloc_valid,w_destination,w_frame_id,w_length,mwr,
 av,ae,ab,ar,wd,we,wdr,dv,dd,dr,rd,re,rdr,published,released,aborted,invalid_requests,
 latency_last,latency_min,latency_max,latency_sum,elapsed_cycles,allocation_stalls,peak_occupied);
 wire [3:0] qv,qr,qw,pv,pr,pe;
 wire [127:0] qa,qd,pd;wire [15:0] qs;
 wire bv,bw,br,bpv,bpe,bpr;wire [31:0] ba,bd,bpd;wire [3:0] bs;
 mem_port_arbiter4 arb(clk,rst_n,qv,qw,qa,qd,qs,qr,pv,pd,pe,pr,
 bv,bw,ba,bd,bs,br,bpv,bpd,bpe,bpr,requests,completions,memory_stalls);
 mem_port_bram #(.DEPTH(4*SLOT_WORDS)) ram(clk,rst_n,bv,bw,ba,bd,bs,br,bpv,bpd,bpe,bpr,,,);
 genvar c;
 generate for(c=0;c<4;c=c+1)begin: monitors
  if(c<2)begin: input_stream
   frame_stream_monitor monitor(clk,rst_n,s_valid[c],s_ready[c],s_data[c*32+:32],
    s_keep[c*4+:4],s_last[c],stream_bytes[c*32+:32],stream_frames[c*32+:32],
    stream_stalls[c*32+:32],last_frame_cycles[c*32+:32],stream_crc32[c*32+:32],last_frame_crc32[c*32+:32]);
  end else begin: output_stream
   frame_stream_monitor monitor(clk,rst_n,m_valid[c-2],m_ready[c-2],m_data[(c-2)*32+:32],
    m_keep[(c-2)*4+:4],m_last[c-2],stream_bytes[c*32+:32],stream_frames[c*32+:32],
    stream_stalls[c*32+:32],last_frame_cycles[c*32+:32],stream_crc32[c*32+:32],last_frame_crc32[c*32+:32]);
  end
 end endgenerate
 generate for(c=0;c<2;c=c+1)begin: channels
  // Idle -> allocation response -> DMA -> completion report. Holding the
  // report blocks another allocation, keeping one completion per request.
  reg [1:0] state;
  reg [15:0] length;
  reg report_error;
  wire dma_start_ready,dma_done,dma_error;
  wire dma_finish=dma_done&&wdr[c];
  assign alloc_valid[c]=w_valid[c]&&state==0;
  assign w_ready[c]=mwr[c]&&state==0;
  assign ar[c]=state==1&&(ae[c]||dma_start_ready);
  assign wd[c]=dma_done;
  assign we[c]=dma_error;
  assign complete_valid[c]=rst_n&&state==3;
  assign complete_error[c]=report_error;
  always @(posedge clk or negedge rst_n)begin
   if(!rst_n)begin state<=0;length<=0;report_error<=0;end
   else case(state)
    0:if(w_valid[c]&&w_ready[c])begin length<=w_length[c*16+:16];state<=1;end
    1:if(av[c]&&ar[c])begin
     if(ae[c])begin report_error<=1;state<=3;end else state<=2;
    end
    2:if(dma_finish)begin report_error<=dma_error;state<=3;end
    3:if(complete_ready[c])state<=0;
   endcase
  end
  frame_word_dma #(.WRITE(1)) writer(
   clk,rst_n,av[c]&&!ae[c]&&state==1,dma_start_ready,ab[c*32+:32],length,
   s_valid[c],s_ready[c],s_data[c*32+:32],s_keep[c*4+:4],s_last[c],
   ,1'b0,,,,qv[c],qr[c],qw[c],qa[c*32+:32],qd[c*32+:32],qs[c*4+:4],
   pv[c],pr[c],pd[c*32+:32],pe[c],dma_done,wdr[c],dma_error,,,);
  reg [65:0] descriptor;
  assign m_descriptor[c*66+:66]=descriptor;
  always @(posedge clk or negedge rst_n)begin
   if(!rst_n)descriptor<=0;
   else if(dv[c]&&dr[c])descriptor<=dd[c*66+:66];
  end
  frame_word_dma #(.WRITE(0)) reader(
   clk,rst_n,dv[c],dr[c],dd[c*66+16+:32],dd[c*66+:16],
   1'b0,,32'd0,4'd0,1'b0,m_valid[c],m_ready[c],m_data[c*32+:32],m_keep[c*4+:4],m_last[c],
   qv[c+2],qr[c+2],qw[c+2],qa[(c+2)*32+:32],qd[(c+2)*32+:32],qs[(c+2)*4+:4],
   pv[c+2],pr[c+2],pd[(c+2)*32+:32],pe[c+2],rd[c],rdr[c],re[c],,,);
 end endgenerate
endmodule
