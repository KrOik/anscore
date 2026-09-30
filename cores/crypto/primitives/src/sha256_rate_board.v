// 27 MHz full-rate SHA test, including one-/two-/three-/five-block padding
// boundaries. Export every digest and measured cycles; host checks hashlib.
module sha256_rate_board(input wire clk,
    output wire uart_tx,dbg_uart,dbg_done,dbg_pass,dbg_fail,
    output wire dbg_ce,dbg_rstn,dbg_busy,dbg_hb);
  reg [12:0] por=0;
  always @(posedge clk) if(!por[12]) por<=por+1'b1;
  wire rst_n=por[12];
  reg [24:0] hb=0;
  always @(posedge clk) hb<=hb+1'b1;
  localparam INIT=0, FEED=1, WAIT_HASH=2, REPORT=3, GAP=4;
  reg [2:0] state;
  reg [3:0] msg,completed;
  reg [8:0] byte_index;
  reg [15:0] cycles;
  reg [3263:0] results;
  reg failed;
  reg [9:0] pos;
  reg [19:0] gap;
  wire ready,digest_valid,tx_ready;
  wire [255:0] digest;
  function [8:0] message_length(input [3:0] index);
    begin case(index)
      0:message_length=3; 1:message_length=55; 2:message_length=56;
      3:message_length=63; 4:message_length=64; 5:message_length=65;
      6:message_length=119; 7:message_length=120; 8:message_length=127;
      9:message_length=128; 10:message_length=129; default:message_length=255;
    endcase end
  endfunction
  wire [15:0] bi={7'd0,byte_index}, mi={12'd0,msg};
  wire [7:0] pattern=(bi<<5)-bi+(bi>>2)+16'd7+(mi<<4)+mi;
  wire [7:0] din=msg==0 ? (byte_index==0 ? 8'h61 : byte_index==1 ? 8'h62 : 8'h63) : pattern;
  wire last=byte_index==message_length(msg)-1'b1;
  wire [15:0] expected_cycles=((({7'd0,message_length(msg)}+16'd72)>>6)<<7)+16'd1;
  sha256_core dut(.clk(clk),.clk_en(1'b1),.rst_n(rst_n),.init(state==INIT),
    .din(din),.din_valid(state==FEED),.din_last(last),.din_ready(ready),
    .digest(digest),.digest_valid(digest_valid));
  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      state<=INIT; msg<=0; completed<=0; byte_index<=0; cycles<=0;
      results<=0; failed<=0; pos<=0; gap<=0;
    end else case(state)
      INIT: begin state<=FEED; byte_index<=0; cycles<=0; end
      FEED: begin
        cycles<=cycles+1'b1;
        if(ready) begin
          if(last) state<=WAIT_HASH;
          else byte_index<=byte_index+1'b1;
        end
        if(cycles==2000) begin failed<=1; state<=REPORT; pos<=0; end
      end
      WAIT_HASH: begin
        cycles<=cycles+1'b1;
        if(digest_valid) begin
          results[3263-({msg,8'b0}+{msg,4'b0}) -: 272]<={cycles,digest};
          completed<=completed+1'b1;
          if(cycles!=expected_cycles) failed<=1;
          if(msg==11) begin state<=REPORT; pos<=0; end
          else begin msg<=msg+1'b1; state<=INIT; end
        end else if(cycles==2000) begin failed<=1; state<=REPORT; pos<=0; end
      end
      REPORT: if(tx_ready) begin
        if(pos==832) begin state<=GAP; gap<=0; end
        else pos<=pos+1'b1;
      end
      GAP: if(gap==1000000) begin state<=INIT; msg<=0; completed<=0; end
           else gap<=gap+1'b1;
    endcase
  end
  function [7:0] hexchar(input [3:0] n);
    begin hexchar=n<10 ? 8'd48+n : 8'd55+n; end
  endfunction
  reg [7:0] ch;
  always @* begin
    case(pos)
      0:ch="S"; 1:ch="H"; 2:ch="A"; 3:ch="2"; 4:ch="7"; 5:ch=" ";
      6:ch=failed?"F":"P"; 7:ch="A"; 8:ch=failed?"I":"S"; 9:ch=failed?"L":"S";
      10:ch=" "; 11:ch="N"; 12:ch="="; 13:ch="0"; 14:ch=hexchar(completed); 15:ch=" ";
      832:ch=10;
      default:ch=hexchar(results[3263-(pos-16)*4 -: 4]);
    endcase
  end
  uart_tx tx(.clk(clk),.rst_n(rst_n),.tx_data(ch),.tx_data_valid(state==REPORT),
    .tx_data_ready(tx_ready),.tx_pin(uart_tx),.tx_busy());
  assign dbg_uart=uart_tx;
  assign dbg_done=(state==REPORT || state==GAP);
  assign dbg_pass=dbg_done && !failed;
  assign dbg_fail=failed;
  assign dbg_ce=(state==FEED && ready);
  assign dbg_rstn=rst_n;
  assign dbg_busy=!ready;
  assign dbg_hb=hb[24];
endmodule
