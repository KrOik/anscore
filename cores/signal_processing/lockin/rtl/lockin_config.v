// One operation per atomically applied version. A held result keeps the
// configuration frozen; a queued commit applies after its acknowledgement.
module lockin_config(
 input wire clk,rst_n,write_valid,output wire write_ready,
 input wire [3:0] write_index,input wire [31:0] write_data,
 input wire [3:0] write_strb,input wire commit_valid,output wire commit_ready,
 input wire idle,input wire cmd_ready,output wire cmd_valid,
 output wire [511:0] active,output wire [31:0] version,output wire pending
);
 reg [31:0] launched_version;
 wire apply_safe=idle&&version==launched_version;
 sys_atomic_config #(.WORDS(16)) config_bank(clk,rst_n,write_valid,write_ready,
  write_index,write_data,write_strb,commit_valid,commit_ready,apply_safe,
  active,version,pending);
 assign cmd_valid=rst_n&&version!=launched_version;
 always @(posedge clk or negedge rst_n)
  if(!rst_n)launched_version<=0;
  else if(cmd_valid&&cmd_ready)launched_version<=version;
endmodule
