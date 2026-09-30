// Full-rate AES board test: clk_en=1 at 27 MHz, four independent KATs,
// live latency check and all 64 ciphertext bytes exported as ASCII hex.
// Unmasked functional test; no side-channel protection claim.
module aes128_rate_board(input wire clk,
    output wire uart_tx, dbg_uart, dbg_done, dbg_pass, dbg_fail,
    output wire dbg_ce, dbg_rstn, dbg_busy, dbg_hb);
  reg [12:0] por=0;
  always @(posedge clk) if(!por[12]) por<=por+1'b1;
  wire rst_n=por[12];
  reg [24:0] hb=0;
  always @(posedge clk) hb<=hb+1'b1;
  reg [1:0] index;
  reg [2:0] state;
  reg [7:0] cycles, measured;
  reg failed;
  reg [511:0] results;
  reg [7:0] pos;
  reg [19:0] gap;
  wire done, busy, tx_ready;
  wire [127:0] cipher;
  localparam LAUNCH=0, WAIT_RESULT=1, REPORT=2, GAP=3;
  function [127:0] key_for(input [1:0] n);
    begin case(n)
      0:key_for=128'h000102030405060708090a0b0c0d0e0f;
      1:key_for=0;
      2:key_for=128'h2b7e151628aed2a6abf7158809cf4f3c;
      3:key_for=128'hd5f0e1d2c3b4a5968778695a4b3c2d1e;
    endcase end
  endfunction
  function [127:0] plain_for(input [1:0] n);
    begin case(n)
      0:plain_for=128'h00112233445566778899aabbccddeeff;
      1:plain_for=0;
      2:plain_for=128'h6bc1bee22e409f96e93d7e117393172a;
      3:plain_for=128'h00102030405060708090a0b0c0d0e0f0;
    endcase end
  endfunction
  function [127:0] expected_for(input [1:0] n);
    begin case(n)
      0:expected_for=128'h69c4e0d86a7b0430d8cdb78070b4c55a;
      1:expected_for=128'h66e94bd4ef8a2c3b884cfa59ca342b2e;
      2:expected_for=128'h3ad77bb40d7a3660a89ecaf32466ef97;
      3:expected_for=128'h159a051d0660c2c42511c3fdb23682a2;
    endcase end
  endfunction
  aes128_core aes(.clk(clk),.clk_en(1'b1),.rst_n(rst_n),
    .start(state==LAUNCH),.key(key_for(index)),.din(plain_for(index)),
    .dout(cipher),.done(done),.busy(busy));
  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      state<=LAUNCH; index<=0; cycles<=0; measured<=0; failed<=0;
      results<=0; pos<=0; gap<=0;
    end else case(state)
      LAUNCH: begin state<=WAIT_RESULT; cycles<=0; end
      WAIT_RESULT: begin
        if(done) begin
          results[511-index*128 -: 128]<=cipher;
          measured<=cycles;
          if(cipher!=expected_for(index) || cycles!=10) failed<=1;
          if(index==3) begin state<=REPORT; pos<=0; end
          else begin index<=index+1'b1; state<=LAUNCH; end
        end else if(cycles==100) begin
          failed<=1; measured<=cycles; state<=REPORT; pos<=0;
        end else cycles<=cycles+1'b1;
      end
      REPORT: if(tx_ready) begin
        if(pos==144) begin state<=GAP; gap<=0; end
        else pos<=pos+1'b1;
      end
      GAP: if(gap==1000000) begin index<=0; state<=LAUNCH; end
           else gap<=gap+1'b1;
    endcase
  end
  function [7:0] hexchar(input [3:0] n);
    begin hexchar=n<10 ? 8'd48+n : 8'd55+n; end
  endfunction
  reg [7:0] ch;
  always @* begin
    case(pos)
      0:ch="A"; 1:ch="E"; 2:ch="S"; 3:ch="2"; 4:ch="7"; 5:ch=" ";
      6:ch=failed?"F":"P"; 7:ch="A"; 8:ch=failed?"I":"S";
      9:ch=failed?"L":"S"; 10:ch=" "; 11:ch="R"; 12:ch="=";
      13:ch=hexchar(measured[7:4]); 14:ch=hexchar(measured[3:0]);
      15:ch=" "; 144:ch=10;
      default: ch=hexchar(results[511-(pos-16)*4 -: 4]);
    endcase
  end
  uart_tx tx(.clk(clk),.rst_n(rst_n),.tx_data(ch),.tx_data_valid(state==REPORT),
    .tx_data_ready(tx_ready),.tx_pin(uart_tx),.tx_busy());
  assign dbg_uart=uart_tx;
  assign dbg_done=(state==REPORT || state==GAP);
  assign dbg_pass=dbg_done && !failed;
  assign dbg_fail=failed;
  assign dbg_ce=1'b1;
  assign dbg_rstn=rst_n;
  assign dbg_busy=busy;
  assign dbg_hb=hb[24];
endmodule
