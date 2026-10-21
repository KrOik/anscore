// IP-02 reference subsystem, transport-neutral (no board pins or host yet).
// Typical ownership: masters0/1 writers, masters2/3 readers.
module bsram_reference #(parameter DEPTH=256)(
 input wire clk,rst_n,input wire[3:0] s_valid,s_write,
 input wire[127:0] s_addr,s_data,input wire[15:0] s_strobe,output wire[3:0] s_ready,
 output wire[3:0] r_valid,output wire[127:0] r_data,output wire[3:0] r_error,
 input wire[3:0] r_ready,output wire[127:0] requests,completions,stalls,
 output wire[31:0] reads,writes,errors
);
 wire mv,mw,mr,pv,pe,pr;wire[31:0] ma,md,pd;wire[3:0] ms;
 mem_port_arbiter4 arb(clk,rst_n,s_valid,s_write,s_addr,s_data,s_strobe,s_ready,
 r_valid,r_data,r_error,r_ready,mv,mw,ma,md,ms,mr,pv,pd,pe,pr,requests,completions,stalls);
 mem_port_bram #(.DEPTH(DEPTH)) ram(clk,rst_n,mv,mw,ma,md,ms,mr,pv,pd,pe,pr,reads,writes,errors);
endmodule
