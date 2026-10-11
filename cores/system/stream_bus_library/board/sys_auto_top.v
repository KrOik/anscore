// JTAG-loaded stimulus RAM + measured replay + binary UART raw readback.
// Separate physical acceptance path when dock RX is not electrically visible.
// Reuses native IPs; ROM contains ONLY host-generated inputs and descriptors.
module sys_auto_top #(parameter PROFILE=0,BIT_CYCLES=434,START_DELAY=25000000)(
 input wire clk,uart_rx,output wire uart_tx,output wire [1:0] led);
localparam [7:0] PROFILE_ID=PROFILE;
reg [15:0] por=0; always @(posedge clk) if(!(&por)) por<=por+1'b1;
wire rst_n=&por;
reg [4:0] state; reg [7:0] case_id; reg [15:0] load_address,read_address,n_inputs,n_outputs,offset;
reg [25:0] startup;
reg pin; reg [31:0] rx_edges;
wire [5:0] selected={1'b0,case_id[5:1]};
// Registered release cuts control-decode -> asynchronous-clear -> data paths.
reg dut_release;
always @(posedge clk or negedge rst_n)
 if(!rst_n) dut_release<=0; else dut_release<=(state>=3);
wire dut_rst_n=dut_release;
wire [95:0] vector; wire [47:0] descriptor; wire [7:0] case_count;
wire [15:0] vector_address=offset+load_address;
generate
if(PROFILE==0) begin:v0 sys_auto_vectors_0 rom(clk,vector_address,case_id,vector,descriptor,case_count); end
else if(PROFILE==1) begin:v1 sys_auto_vectors_1 rom(clk,vector_address,case_id,vector,descriptor,case_count); end
else if(PROFILE==2) begin:v2 sys_auto_vectors_2 rom(clk,vector_address,case_id,vector,descriptor,case_count); end
else if(PROFILE==3) begin:v3 sys_auto_vectors_3 rom(clk,vector_address,case_id,vector,descriptor,case_count); end
else if(PROFILE==4) begin:v4 sys_auto_vectors_4 rom(clk,vector_address,case_id,vector,descriptor,case_count); end
else if(PROFILE==5) begin:v5 sys_auto_vectors_5 rom(clk,vector_address,case_id,vector,descriptor,case_count); end
else if(PROFILE==6) begin:v6 sys_auto_vectors_6 rom(clk,vector_address,case_id,vector,descriptor,case_count); end
else if(PROFILE==7) begin:v7 sys_auto_vectors_7 rom(clk,vector_address,case_id,vector,descriptor,case_count); end
else if(PROFILE==8) begin:v8 sys_auto_vectors_8 rom(clk,vector_address,case_id,vector,descriptor,case_count); end
endgenerate
wire [95:0] q_data; wire [191:0] r_data,read_data; wire q_valid,q_ready,r_valid,r_ready;
wire active,done,error; wire [15:0] issued,captured; wire [31:0] cycles;
wire allow_capture=!case_id[0]||(cycles[2:0]!=3&&cycles[2:0]!=4); wire capture_ready;
assign r_ready=capture_ready&&allow_capture;
wire start=(state==4);
sys_capture_replay replay(clk,rst_n,state==2,load_address[7:0],vector,start,n_inputs,n_outputs,q_data,q_valid,q_ready,
 r_data,r_valid&&allow_capture,capture_ready,state==8,read_address[7:0],read_data,active,done,error,issued,captured,cycles);
generate
if(PROFILE==0) begin:g0 sys_native_adapters dut(clk,dut_rst_n,selected,q_data,q_valid,q_ready,r_data,r_valid,r_ready); end
else if(PROFILE==1) begin:g1 sys_legacy_0 dut(clk,dut_rst_n,selected,q_data,q_valid,q_ready,r_data,r_valid,r_ready); end
else if(PROFILE==2) begin:g2 sys_legacy_1 dut(clk,dut_rst_n,selected,q_data,q_valid,q_ready,r_data,r_valid,r_ready); end
else if(PROFILE==3) begin:g3 sys_legacy_2 dut(clk,dut_rst_n,selected,q_data,q_valid,q_ready,r_data,r_valid,r_ready); end
else if(PROFILE==4) begin:g4 sys_legacy_3 dut(clk,dut_rst_n,selected,q_data,q_valid,q_ready,r_data,r_valid,r_ready); end
else if(PROFILE==5) begin:g5 sys_legacy_4 dut(clk,dut_rst_n,selected,q_data,q_valid,q_ready,r_data,r_valid,r_ready); end
else if(PROFILE==6) begin:g6 sys_legacy_5 dut(clk,dut_rst_n,selected,q_data,q_valid,q_ready,r_data,r_valid,r_ready); end
else if(PROFILE==7) begin:g7 sys_legacy_6 dut(clk,dut_rst_n,selected,q_data,q_valid,q_ready,r_data,r_valid,r_ready); end
else if(PROFILE==8) begin:g8 sys_acquisition_demo dut(clk,dut_rst_n,selected,q_data,q_valid,q_ready,r_data,r_valid,r_ready); end
endgenerate
wire running; wire [31:0] mc,mi,mo,ins,outs,lmin,lmax,gap,me; reg was_active;
always @(posedge clk or negedge rst_n) if(!rst_n) was_active<=0; else was_active<=active;
sys_stream_metrics metrics(clk,rst_n,start,was_active&&!active,q_valid,q_ready,r_valid,r_ready,running,mc,mi,mo,ins,outs,lmin,lmax,gap,me);
reg sending; reg [5:0] tx_index; reg [7:0] cmd,status,tx_crc; reg [15:0] address; reg [191:0] response;
wire tx_ready; reg [7:0] tx_data;
sys_uart_tx #(.BIT_CYCLES(BIT_CYCLES)) transmitter(clk,rst_n,tx_data,sending,tx_ready,uart_tx);
function [7:0] crc_byte;
 input [7:0] prior,value; integer i; reg [7:0] c;
 begin c=prior^value; for(i=0;i<8;i=i+1) c=c[7]?(c<<1)^8'h07:(c<<1); crc_byte=c; end
endfunction
task reply;
 input [7:0] kind; input [15:0] index; input [191:0] raw;
 begin cmd<=kind; address<=index; response<=raw; status<=0; sending<=1; tx_index<=0; tx_crc<=0; end
endtask
always @* begin
 tx_data=0;
 case(tx_index)
  0:tx_data=8'h55; 1:tx_data=8'haa; 2:tx_data=cmd; 3:tx_data=status;
  4:tx_data=address[7:0]; 5:tx_data=address[15:8]; 30:tx_data=tx_crc;
  default: if(tx_index>=6&&tx_index<30) tx_data=response[(tx_index-6)*8+:8];
 endcase
end
assign led={error,state==18};
always @(posedge clk or negedge rst_n) begin
 if(!rst_n) begin
  state<=0; case_id<=0; load_address<=0; read_address<=0; n_inputs<=0; n_outputs<=0; offset<=0; startup<=0;
  pin<=1; rx_edges<=0; sending<=0; tx_index<=0; cmd<=0; status<=0; tx_crc<=0; address<=0; response<=0;
 end else begin
  pin<=uart_rx; if(pin!=uart_rx) rx_edges<=rx_edges+1;
  if(sending&&tx_ready) begin
   if(tx_index>=2&&tx_index<30) tx_crc<=crc_byte(tx_crc,tx_data);
   if(tx_index==30) sending<=0; else tx_index<=tx_index+1'b1;
  end
  case(state)
   0: if(startup<START_DELAY) startup<=startup+1;
      else begin n_inputs<=descriptor[15:0]; n_outputs<=descriptor[31:16]; offset<=descriptor[47:32]; load_address<=0; read_address<=0; state<=1; end
   1: state<=2;
   2: if(load_address+1==n_inputs) state<=3; else begin load_address<=load_address+1; state<=1; end
   3: state<=4;
   4: state<=5;
   5: if(done) state<=6;
   6: begin reply(8'h83,{case_id,8'd0},{80'd0,rx_edges,cycles,captured,issued,13'd0,active,done,error}); state<=7; end
   7: if(!sending) state<=8;
   8: state<=9;
   9: state<=10;
   10: begin reply(8'h84,{case_id,read_address[7:0]},read_data); state<=11; end
   11: if(!sending) begin
     if(read_address+1<n_outputs) begin read_address<=read_address+1; state<=8; end else state<=12;
   end
   12: begin reply(8'h85,{case_id,8'd0},{lmax,lmin,outs,ins,mo,mi}); state<=13; end
   13: if(!sending) state<=14;
   14: begin reply(8'h85,{case_id,8'd1},{96'd0,me,gap,mc}); state<=15; end
   15: if(!sending) state<=16;
   16: if(case_id+1<case_count) begin case_id<=case_id+1; state<=0; end else state<=17;
   17: begin reply(8'h86,{8'd0,PROFILE_ID},{128'd0,24'd0,case_count,32'h4155544f}); state<=18; end
  endcase
 end
end
endmodule
