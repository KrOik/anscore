// CRC8 framed UART control and host-loaded replay. No fixed golden ROM.
// Request: aa55 cmd addrLE payload96LE crc(cmd..payload), 18 bytes.
// Response:55aa cmd status addrLE raw192LE crc(cmd..raw), 31 bytes.
module sys_transport #(parameter PROFILE=0, BIT_CYCLES=434)(
 input wire clk,rst_n,uart_rx,output wire uart_tx,
 output reg [5:0] selected,output wire dut_rst_n,
 output wire [95:0] q_data,output wire q_valid,input wire q_ready,
 input wire [191:0] r_data,input wire r_valid,output wire r_ready,
 output wire active,done,error
);
localparam [7:0] PROFILE_ID=PROFILE;
function [7:0] crc_byte;
 input [7:0] initial_crc,value; integer j; reg [7:0] c;
 begin c=initial_crc^value; for(j=0;j<8;j=j+1) c=c[7]?(c<<1)^8'h07:(c<<1); crc_byte=c; end
endfunction
wire [7:0] rx_byte; wire rx_valid,framing_error;
sys_uart_rx #(.BIT_CYCLES(BIT_CYCLES)) rx(clk,rst_n,uart_rx,rx_byte,rx_valid,framing_error);
reg [7:0] tx_data; wire tx_ready; wire tx_valid;
sys_uart_tx #(.BIT_CYCLES(BIT_CYCLES)) tx(clk,rst_n,tx_data,tx_valid,tx_ready,uart_tx);
reg [4:0] rx_index;
reg [7:0] cmd,crc;
reg [15:0] address;
reg [95:0] payload;
reg [7:0] response_cmd,status,tx_crc;
reg [15:0] response_address;
reg [191:0] response;
reg [5:0] tx_index;
reg sending;
reg [2:0] work;
reg host_write,host_read,start;
reg [15:0] n_inputs,n_outputs;
reg [2:0] reset_count;
reg [31:0] protocol_errors;
wire [31:0] cycles;
reg stall_mode;
wire capture_ready;
wire allow_capture=!stall_mode||(cycles[2:0]!=3&&cycles[2:0]!=4);
assign r_ready=capture_ready&&allow_capture;
wire [191:0] read_data;
wire [15:0] issued,captured;
assign dut_rst_n=rst_n&&(reset_count==0);
sys_capture_replay replay(.clk(clk),.rst_n(rst_n),.host_write(host_write),.host_address(address[7:0]),.host_data(payload),
 .start(start),.input_length(n_inputs),.output_length(n_outputs),.s_data(q_data),.s_valid(q_valid),.s_ready(q_ready),
 .m_data(r_data),.m_valid(r_valid&&allow_capture),.m_ready(capture_ready),.host_read(host_read),.read_address(address[7:0]),.read_data(read_data),
 .active(active),.done(done),.error(error),.issued(issued),.captured(captured),.cycles(cycles));
reg was_active;
wire running; wire [31:0] metric_cycles,inputs,outputs,in_stalls,out_stalls,lat_min,lat_max,gap,metric_errors;
sys_stream_metrics metrics(.clk(clk),.rst_n(rst_n),.start(start),.stop(was_active&&!active),
 .in_valid(q_valid),.in_ready(q_ready),.out_valid(r_valid),.out_ready(r_ready),.running(running),
 .cycles(metric_cycles),.inputs(inputs),.outputs(outputs),.input_stalls(in_stalls),.output_stalls(out_stalls),
 .latency_min(lat_min),.latency_max(lat_max),.max_output_gap(gap),.errors(metric_errors));
// Completion may coincide with final handshake; delayed stop captures that edge.
always @(posedge clk or negedge rst_n) if(!rst_n) was_active<=0; else was_active<=active;
// Metric observer stop also needs active falling detection (below via separate signal).
always @* begin
 tx_data=0;
 case(tx_index)
  0:tx_data=8'h55; 1:tx_data=8'haa; 2:tx_data=response_cmd; 3:tx_data=status;
  4:tx_data=response_address[7:0]; 5:tx_data=response_address[15:8]; 30:tx_data=tx_crc;
  default: if(tx_index>=6&&tx_index<30) tx_data=response[(tx_index-6)*8+:8];
 endcase
end
assign tx_valid=sending;
task reply;
 input [7:0] code; input [191:0] value;
 begin response_cmd<=cmd; status<=code; response_address<=address; response<=value;
  tx_index<=0; tx_crc<=0; sending<=1; end
endtask
always @(posedge clk or negedge rst_n) begin
 if(!rst_n) begin
  selected<=0; rx_index<=0; cmd<=0; crc<=0; address<=0; payload<=0;
  response_cmd<=0; status<=0; response_address<=0; response<=0; tx_index<=0; tx_crc<=0; sending<=0;
  work<=0; host_write<=0; host_read<=0; start<=0; n_inputs<=0; n_outputs<=0; reset_count<=0; protocol_errors<=0; stall_mode<=0;
 end else begin
  host_write<=0; host_read<=0; start<=0;
  if(reset_count!=0) reset_count<=reset_count-1'b1;
  if(framing_error) begin protocol_errors<=protocol_errors+1; rx_index<=0; end
  if(sending&&tx_ready) begin
   if(tx_index>=2&&tx_index<30) tx_crc<=crc_byte(tx_crc,tx_data);
   if(tx_index==30) sending<=0; else tx_index<=tx_index+1'b1;
  end
  case(work)
   1: begin work<=0; reply(0,0); end
   2: work<=3;
   3: begin work<=0; reply(0,read_data); end
   4: if(reset_count==0) begin start<=1; work<=1; end
  endcase
  if(rx_valid&&!sending&&work==0) begin
   case(rx_index)
    0: if(rx_byte==8'haa) rx_index<=1;
    1: if(rx_byte==8'h55) begin rx_index<=2; crc<=0; end else rx_index<=(rx_byte==8'haa)?1:0;
    2: begin cmd<=rx_byte; crc<=crc_byte(crc,rx_byte); rx_index<=3; end
    3: begin address[7:0]<=rx_byte; crc<=crc_byte(crc,rx_byte); rx_index<=4; end
    4: begin address[15:8]<=rx_byte; crc<=crc_byte(crc,rx_byte); rx_index<=5; end
    17: begin
     rx_index<=0;
     if(rx_byte!=crc) begin protocol_errors<=protocol_errors+1; reply(1,0); end
     else case(cmd)
      0: reply(0,{128'd0,32'h53595032,16'd50,PROFILE_ID,8'd16});
      1: if(active||address>255) reply(2,0); else begin host_write<=1; work<=1; end
      2: if(active||payload[5:0]>((PROFILE==0)?15:((PROFILE==8)?0:7))) reply(2,0);
         else begin selected<=payload[5:0]; stall_mode<=payload[8]; n_inputs<=address; n_outputs<=payload[31:16]; reset_count<=4; work<=4; end
      3: reply(0,{80'd0,protocol_errors,cycles, captured,issued,13'd0,active,done,error});
      4: if(active||address>255) reply(2,0); else begin host_read<=1; work<=2; end
      5: if(address==0) reply(0,{lat_max,lat_min,out_stalls,in_stalls,outputs,inputs});
         else reply(0,{96'd0,metric_errors,gap,metric_cycles});
      default: reply(3,0);
     endcase
    end
    default: begin payload[(rx_index-5)*8+:8]<=rx_byte; crc<=crc_byte(crc,rx_byte); rx_index<=rx_index+1'b1; end
   endcase
  end
 end
end
endmodule
