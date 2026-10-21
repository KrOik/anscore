// Full-rate 27 MHz FFT validation harness. Every vector exports all 64 complex
// bins, measured busy cycles and a sticky latency error. No on-board golden ROM.
// Frame: "FFT", vector, cycles big-endian, error, A5, 64*(reBE16,imBE16).
module fft64_rate_board #(parameter DIAGNOSTIC_INPUT=0, parameter ENABLE_DIV=1)
 (input wire clk, output wire uart_tx, output wire dbg_uart);
reg [12:0] reset_count=0;
wire rst_n=reset_count[12];
always @(posedge clk) if(!rst_n) reset_count<=reset_count+1'b1;
reg [3:0] enable_count=0;
wire ce=(ENABLE_DIV==1) || (enable_count==ENABLE_DIV-1);
always @(posedge clk) begin
 if(!rst_n || ce) enable_count<=0; else enable_count<=enable_count+1'b1;
end
localparam LOAD=0, START=1, WAIT_BUSY=2, COMPUTE=3, HEADER=4,
 READ=5, SNAP=6, DATA=7, TX=8, ACK=9;
reg [3:0] state, return_state;
reg [2:0] vec;
reg [5:0] addr;
reg [2:0] byte_index;
reg [15:0] cycles;
reg error;
reg [31:0] input_rom[0:511];
initial $readmemh("fft_board_input.mem",input_rom);
wire [31:0] sample=input_rom[{vec,addr}];
wire busy,done;
wire [15:0] rd_re,rd_im;
wire [5:0] read_addr=DIAGNOSTIC_INPUT ? {addr[0],addr[1],addr[2],addr[3],addr[4],addr[5]} : addr;
reg [31:0] snapshot;
fft64 core(.clk(clk),.clk_en(ce),.rst_n(rst_n),
 .ld_en(state==LOAD),.ld_addr(addr),.ld_re(sample[31:16]),.ld_im(sample[15:0]),
 .start(state==START),.busy(busy),.done(done),
 .rd_en(state==READ),.rd_addr(read_addr),.rd_re(rd_re),.rd_im(rd_im));
reg [7:0] tx_data;
reg tx_valid;
wire tx_ready,tx_busy;
uart_tx uart(.clk(clk),.rst_n(rst_n),.tx_data(tx_data),
 .tx_data_valid(tx_valid),.tx_data_ready(tx_ready),.tx_busy(tx_busy),.tx_pin(dbg_uart));
assign uart_tx=dbg_uart;
always @(posedge clk or negedge rst_n) begin
 if(!rst_n) begin
  state<=LOAD; return_state<=LOAD; vec<=0; addr<=0; byte_index<=0;
  cycles<=0; error<=0; tx_valid<=0; tx_data<=0; snapshot<=0;
 end else if(ce) begin
  case(state)
   LOAD: if(addr==63) begin addr<=0; state<=DIAGNOSTIC_INPUT ? HEADER : START; end else addr<=addr+1'b1;
   START: begin cycles<=0; state<=WAIT_BUSY; end
   WAIT_BUSY: if(busy) begin cycles<=1; state<=COMPUTE; end
   COMPUTE: if(busy) cycles<=cycles+1'b1;
    else if(done) begin
     if(cycles!=768) error<=1;
     byte_index<=0; state<=HEADER;
    end
   HEADER: begin
    case(byte_index)
     0:tx_data<=8'h46; 1:tx_data<=8'h46; 2:tx_data<=8'h54;
     3:tx_data<={5'd0,vec}; 4:tx_data<=cycles[15:8]; 5:tx_data<=cycles[7:0];
     6:tx_data<={7'd0,error}; 7:tx_data<=8'ha5;
    endcase
    if(byte_index==7) begin byte_index<=0; return_state<=READ; end
    else begin byte_index<=byte_index+1'b1; return_state<=HEADER; end
    state<=TX;
   end
   READ: state<=SNAP;
   SNAP: begin snapshot<={rd_re,rd_im}; state<=DATA; end
   DATA: begin
    case(byte_index)
     0:tx_data<=snapshot[31:24]; 1:tx_data<=snapshot[23:16];
     2:tx_data<=snapshot[15:8]; 3:tx_data<=snapshot[7:0];
    endcase
    if(byte_index==3) begin
     byte_index<=0;
     if(addr==63) begin addr<=0; vec<=vec+1'b1; return_state<=LOAD; end
     else begin addr<=addr+1'b1; return_state<=READ; end
    end else begin byte_index<=byte_index+1'b1; return_state<=DATA; end
    state<=TX;
   end
   TX: if(tx_ready) begin tx_valid<=1; state<=ACK; end
   ACK: if(tx_busy) begin tx_valid<=0; state<=return_state; end
   default: state<=LOAD;
  endcase
 end
end
endmodule
