// Full-rate mixed-mode CORDIC stream at 27 MHz. 32 inputs on adjacent cycles;
// all output words are exported, and latency/cadence are checked in hardware.
// Small register capture is test instrumentation, not a coefficient memory.
module cordic_rate_board(input wire clk,
    output wire uart_tx, dbg_uart, dbg_done, dbg_pass, dbg_fail,
    output wire dbg_ce, dbg_rstn, dbg_busy, dbg_hb);
  reg [12:0] por=0;
  always @(posedge clk) if(!por[12]) por<=por+1'b1;
  wire rst_n=por[12];
  reg [24:0] hb=0;
  always @(posedge clk) hb<=hb+1'b1;
  localparam RUN=0, REPORT=1, GAP=2;
  reg [1:0] state;
  reg [5:0] sent, received;
  reg [7:0] ticks, latency;
  reg failed;
  reg [2047:0] results;
  reg [9:0] pos;
  reg [19:0] gap;
  wire iv=rst_n && state==RUN && sent<32;
  wire [15:0] n={10'd0,sent};
  wire signed [15:0] x=(n<<10)-16'd16384;
  wire signed [15:0] y=(n<<9)+(n<<7)+(n<<6)+(n<<4)+(n<<3)+(n<<2)+n-16'd12000;
  wire signed [15:0] z=(n<<11)-(n<<5)-(n<<4)-16'd31000;
  wire signed [15:0] xo,yo;
  wire signed [17:0] zo;
  wire ov,tx_ready;
  cordic dut(.clk(clk),.clk_en(1'b1),.rst_n(rst_n),.mode(sent[0]),.in_valid(iv),
    .x_in(x),.y_in(y),.z_in(z),.x_out(xo),.y_out(yo),.z_out(zo),.out_valid(ov));
  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      state<=RUN; sent<=0; received<=0; ticks<=0; latency<=0;
      failed<=0; results<=0; pos<=0; gap<=0;
    end else case(state)
      RUN: begin
        ticks<=ticks+1'b1;
        if(iv) sent<=sent+1'b1;
        if(ov) begin
          // The capture register observes the port one edge later. Report
          // the 17-cycle port latency, not the 18-cycle capture latency.
          if(received==0) latency<=ticks-1'b1;
          if(ticks!=18+received) failed<=1;
          results[2047-received*64 -: 64]<={14'd0,zo,yo,xo};
          received<=received+1'b1;
          if(received==31) begin
            if(sent!=32) failed<=1;
            state<=REPORT; pos<=0;
          end
        end else if(ticks==100) begin failed<=1; state<=REPORT; pos<=0; end
      end
      REPORT: if(tx_ready) begin
        if(pos==534) begin state<=GAP; gap<=0; end
        else pos<=pos+1'b1;
      end
      GAP: if(gap==1000000) begin state<=RUN; sent<=0; received<=0; ticks<=0; end
           else gap<=gap+1'b1;
    endcase
  end
  function [7:0] hexchar(input [3:0] v);
    begin hexchar=v<10 ? 8'd48+v : 8'd55+v; end
  endfunction
  reg [7:0] ch;
  always @* begin
    case(pos)
      0:ch="C"; 1:ch="O"; 2:ch="R"; 3:ch="D"; 4:ch="2"; 5:ch="7"; 6:ch=" ";
      7:ch=failed?"F":"P"; 8:ch="A"; 9:ch=failed?"I":"S"; 10:ch=failed?"L":"S";
      11:ch=" "; 12:ch="N"; 13:ch="="; 14:ch=hexchar({2'b0,received[5:4]});
      15:ch=hexchar(received[3:0]); 16:ch=" "; 17:ch="L"; 18:ch="=";
      19:ch=hexchar(latency[7:4]); 20:ch=hexchar(latency[3:0]); 21:ch=" ";
      534:ch=10;
      default:ch=hexchar(results[2047-(pos-22)*4 -: 4]);
    endcase
  end
  uart_tx tx(.clk(clk),.rst_n(rst_n),.tx_data(ch),.tx_data_valid(state==REPORT),
    .tx_data_ready(tx_ready),.tx_pin(uart_tx),.tx_busy());
  assign dbg_uart=uart_tx;
  assign dbg_done=state!=RUN;
  assign dbg_pass=dbg_done && !failed;
  assign dbg_fail=failed;
  assign dbg_ce=iv;
  assign dbg_rstn=rst_n;
  assign dbg_busy=ov;
  assign dbg_hb=hb[24];
endmodule
