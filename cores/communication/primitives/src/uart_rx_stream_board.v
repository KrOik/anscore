// Continuous 8N1 test source and delayed consumer. Internal loopback is
// exposed on dbg_d0; it does not certify an external RX pad or cable.
module uart_rx_stream_board(input wire clk,
    output wire uart_tx, dbg_uart, dbg_hb, dbg_pass, dbg_fail,
    output wire dbg_d0, dbg_d1, dbg_d2, dbg_d3);
  reg [12:0] por=0;
  always @(posedge clk) if (!por[12]) por<=por+1'b1;
  wire rst_n=por[12];
  reg [24:0] heartbeat=0;
  always @(posedge clk) heartbeat<=heartbeat+1'b1;
  assign dbg_hb=heartbeat[24];
  reg [7:0] tick;
  reg [3:0] bit_no;
  reg [5:0] sent, received;
  reg [11:0] settle;
  reg [7:0] ack_wait;
  reg failed, done;
  wire [7:0] payload=((sent<<6)+(sent<<3)+sent)^8'ha5;
  wire stimulus=(sent==32) ? 1'b1 :
                (bit_no==0) ? 1'b0 :
                (bit_no==9) ? 1'b1 : payload[bit_no-1'b1];
  wire [7:0] rx_data;
  wire valid, ferr;
  wire ack=valid && ack_wait==234;
  wire [7:0] expected=((received<<6)+(received<<3)+received)^8'ha5;
  uart_rx receiver(.clk(clk),.rst_n(rst_n),.clk_en(1'b1),
    .rx_pin(stimulus),.rx_data(rx_data),.rx_valid(valid),
    .rx_ack(ack),.framing_err(ferr));
  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      tick<=0; bit_no<=0; sent<=0; received<=0; settle<=0;
      ack_wait<=0; failed<=0; done<=0;
    end else begin
      if(sent<32) begin
        if(tick==233) begin
          tick<=0;
          if(bit_no==9) begin bit_no<=0; sent<=sent+1'b1; end
          else bit_no<=bit_no+1'b1;
        end else tick<=tick+1'b1;
      end else if(!done) begin
        if(settle==3000) begin
          done<=1;
          if(received!=32) failed<=1;
        end else settle<=settle+1'b1;
      end
      if(valid) begin
        if(ack) begin
          ack_wait<=0;
          if(rx_data!=expected || ferr || received>=32) failed<=1;
          if(received<63) received<=received+1'b1;
        end else ack_wait<=ack_wait+1'b1;
      end
    end
  end
  assign dbg_pass=done && !failed;
  assign dbg_fail=failed;
  assign dbg_d0=stimulus;
  assign dbg_d1=valid;
  assign dbg_d2=ack;
  assign dbg_d3=done;
  // Distinct report identifies this test image. Count is live, not a constant.
  function [7:0] hexchar(input [3:0] n);
    begin hexchar=n<10 ? 8'd48+n : 8'd55+n; end
  endfunction
  reg [4:0] pos;
  reg [19:0] pause_count;
  reg sending;
  reg [7:0] ch;
  wire ready;
  always @* begin
    case(pos)
      0:ch="U"; 1:ch="R"; 2:ch="X"; 3:ch="2"; 4:ch=" ";
      5:ch=failed?"F":"P"; 6:ch="A"; 7:ch=failed?"I":"S";
      8:ch=failed?"L":"S"; 9:ch=" "; 10:ch="N"; 11:ch="=";
      12:ch="0"; 13:ch="0"; 14:ch=hexchar({2'b0,received[5:4]});
      15:ch=hexchar(received[3:0]); 16:ch=13; default:ch=10;
    endcase
  end
  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin pos<=0; pause_count<=0; sending<=0; end
    else if(done) begin
      if(!sending) begin
        if(pause_count==1000000) begin sending<=1; pause_count<=0; end
        else pause_count<=pause_count+1'b1;
      end else if(ready) begin
        if(pos==17) begin pos<=0; sending<=0; end
        else pos<=pos+1'b1;
      end
    end
  end
  uart_tx reporter(.clk(clk),.rst_n(rst_n),.tx_data(ch),
    .tx_data_valid(sending),.tx_data_ready(ready),.tx_pin(uart_tx),.tx_busy());
  assign dbg_uart=uart_tx;
endmodule
