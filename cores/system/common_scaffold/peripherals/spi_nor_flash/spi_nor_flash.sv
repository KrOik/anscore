`default_nettype none
// SPI NOR single-lane, 24-bit addressing, modes 0 and 3. No quad/QPI/4-byte mode.
module spi_nor_flash #(
 parameter integer CLOCK_DIV=2, SPI_MODE=0, CS_HIGH_CYCLES=4,
 parameter integer HOST_TIMEOUT=4096, POLL_LIMIT=1024
)(
 input wire clk,rst_n,ce,abort,
 input wire cmd_valid,output wire cmd_ready,input wire[3:0]cmd_op,
 input wire[23:0]cmd_addr,input wire[8:0]cmd_length,
 input wire w_valid,output wire w_ready,input wire[7:0]w_data,
 output reg r_valid,input wire r_ready,output reg[7:0]r_data,
 output reg rsp_valid,input wire rsp_ready,output reg[3:0]rsp_error,
 output reg[8:0]rsp_bytes,output reg[7:0]rsp_status,
 output wire busy,output reg spi_cs_n,output wire spi_sclk,spi_mosi,input wire spi_miso
);
 // op: 0=JEDEC ID(3),1=read,2=fast read,3=page program,4=4KiB erase,
 // 5=WREN,6=status(1),7=poll WIP. Lengths for erase/WREN/poll must be zero.
 // errors: 0=OK,1=descriptor,2=host timeout,3=WIP timeout,4=WEL,5=busy,6=abort.
 localparam IDLE=0,PRELOAD=1,PREP=2,MEMWAIT=3,MEMGO=4,GO=5,WAITBYTE=6,
 RXWAIT=7,ADVANCE=8,GAP=9;
 localparam K_ID=0,K_READ=1,K_FAST=2,K_PP=3,K_ERASE=4,K_WREN=5,
 K_DIRECT=6,K_POLL=7,K_CHECK=8,K_READY=9;
 reg[3:0]state,kind,op;
 reg[23:0]address;
 reg[8:0]length,loaded;
 reg[9:0]position,total;
 reg[31:0]host_wait,gap_wait,polls;
 reg[7:0]buffer[0:255];
 reg[7:0]buffer_q,buffer_addr;
 reg buffer_en;
 reg byte_start,byte_cancel;
 reg[7:0]byte_tx;
 wire[7:0]byte_rx;wire byte_done,byte_busy;
 wire payload=(kind==K_ID&&position>=1)||(kind==K_READ&&position>=4)||
 (kind==K_FAST&&position>=5)||(kind==K_DIRECT&&position==1);
 assign cmd_ready=ce&&!abort&&state==IDLE&&!rsp_valid&&gap_wait==0;
 assign w_ready=state==PRELOAD&&!abort;
 assign busy=state!=IDLE||rsp_valid;
 spi_nor_byte #(.CLOCK_DIV(CLOCK_DIV),.SPI_MODE(SPI_MODE)) byte_engine(
 .clk(clk),.rst_n(rst_n),.cancel(byte_cancel||abort),.start(byte_start),.tx(byte_tx),
 .rx(byte_rx),.busy(byte_busy),.done(byte_done),.sclk(spi_sclk),.mosi(spi_mosi),.miso(spi_miso));
 always @(posedge clk)if(buffer_en)buffer_q<=buffer[buffer_addr];
 task finish;
 input[3:0]err;
 begin state<=IDLE;spi_cs_n<=1;r_valid<=0;byte_cancel<=1;rsp_valid<=1;rsp_error<=err;gap_wait<=CS_HIGH_CYCLES-1;end
 endtask
 task transaction;
 input[3:0]k;input[9:0]n;
 begin kind<=k;total<=n;position<=0;spi_cs_n<=0;state<=PREP;end
 endtask
 function valid_descriptor;
 input[3:0]o;input[23:0]a;input[8:0]n;
 reg[24:0]endaddr;
 begin
 endaddr={1'b0,a}+n;
 case(o)
 0:valid_descriptor=n==3;
 1,2:valid_descriptor=n>=1&&n<=256&&endaddr<=25'h1000000;
 3:valid_descriptor=n>=1&&n<=256&&({1'b0,a[7:0]}+n)<=256;
 4:valid_descriptor=n==0&&a[11:0]==0;
 5,7:valid_descriptor=n==0;
 6:valid_descriptor=n==1;
 default:valid_descriptor=0;
 endcase
 end endfunction
 always @(posedge clk)begin
 if(!rst_n)begin
 state<=IDLE;kind<=0;op<=0;address<=0;length<=0;loaded<=0;position<=0;total<=0;
 host_wait<=0;gap_wait<=CS_HIGH_CYCLES-1;polls<=0;buffer_en<=0;buffer_addr<=0;byte_start<=0;byte_cancel<=1;
 byte_tx<=0;r_valid<=0;r_data<=0;rsp_valid<=0;rsp_error<=0;rsp_bytes<=0;rsp_status<=0;spi_cs_n<=1;
 end else begin
 byte_start<=0;byte_cancel<=0;buffer_en<=0;
 if(rsp_valid&&rsp_ready)rsp_valid<=0;
 if(abort&&state!=IDLE)begin
  // A visible R handshake at the abort edge is still externally consumed.
  if(state==RXWAIT&&r_valid&&r_ready)rsp_bytes<=rsp_bytes+1'b1;
  finish(6);
 end
 else case(state)
 IDLE:begin
 if(gap_wait!=0)gap_wait<=gap_wait-1'b1;
 if(cmd_valid&&cmd_ready)begin
  op<=cmd_op;address<=cmd_addr;length<=cmd_length;loaded<=0;rsp_error<=0;rsp_status<=0;rsp_bytes<=0;host_wait<=0;polls<=0;
  if(!valid_descriptor(cmd_op,cmd_addr,cmd_length))finish(1);
  else if(cmd_op==3)state<=PRELOAD;
  else if(cmd_op==4||cmd_op==5)transaction(K_WREN,1);
  else if(cmd_op==6)transaction(K_DIRECT,2);
  else if(cmd_op==7)transaction(K_POLL,2);
  else transaction(K_READY,2);
 end end
 PRELOAD:if(w_valid&&w_ready)begin
  buffer[loaded[7:0]]<=w_data;loaded<=loaded+1'b1;host_wait<=0;
  if(loaded+1'b1==length)transaction(K_WREN,1);
 end else if(host_wait==HOST_TIMEOUT-1)finish(2);else host_wait<=host_wait+1'b1;
 PREP:begin
  if(kind==K_PP&&position>=4)begin buffer_addr<=position-4;buffer_en<=1;state<=MEMWAIT;end
  else begin
   if(position==0)case(kind)
    K_ID:byte_tx<=8'h9f;K_READ:byte_tx<=8'h03;K_FAST:byte_tx<=8'h0b;
    K_PP:byte_tx<=8'h02;K_ERASE:byte_tx<=8'h20;K_WREN:byte_tx<=8'h06;
    default:byte_tx<=8'h05;
   endcase
   else if((kind==K_READ||kind==K_FAST||kind==K_PP||kind==K_ERASE)&&position<=3)
    case(position)1:byte_tx<=address[23:16];2:byte_tx<=address[15:8];default:byte_tx<=address[7:0];endcase
   else byte_tx<=0;
   state<=GO;
  end
 end
 MEMWAIT:state<=MEMGO;
 MEMGO:begin byte_tx<=buffer_q;state<=GO;end
 GO:begin byte_start<=1;state<=WAITBYTE;end
 WAITBYTE:if(byte_done)begin
  if((kind==K_DIRECT||kind==K_POLL||kind==K_CHECK||kind==K_READY)&&position==1)rsp_status<=byte_rx;
  if(payload)begin r_data<=byte_rx;r_valid<=1;host_wait<=0;state<=RXWAIT;end
  else state<=ADVANCE;
 end
 RXWAIT:if(r_valid&&r_ready)begin r_valid<=0;rsp_bytes<=rsp_bytes+1'b1;host_wait<=0;state<=ADVANCE;end
 else if(host_wait==HOST_TIMEOUT-1)finish(2);else host_wait<=host_wait+1'b1;
 ADVANCE:if(position+1'b1==total)begin
  spi_cs_n<=1;gap_wait<=CS_HIGH_CYCLES-1;state<=GAP;
 end else begin position<=position+1'b1;state<=PREP;end
 GAP:if(gap_wait!=0)gap_wait<=gap_wait-1'b1;
 else case(kind)
  K_READY:if(rsp_status[0])finish(5);
   else if(op==0)transaction(K_ID,4);
   else if(op==1)transaction(K_READ,4+length);
   else transaction(K_FAST,5+length);
  K_WREN:transaction(K_CHECK,2);
  K_CHECK:if(rsp_status[0])finish(5);else if(!rsp_status[1])finish(4);
   else if(op==5)finish(0);else if(op==3)transaction(K_PP,4+length);else transaction(K_ERASE,4);
  K_PP,K_ERASE:begin polls<=0;transaction(K_POLL,2);end
  K_POLL:if(!rsp_status[0])begin if(op==3)rsp_bytes<=length;finish(0);end
   else if(polls==POLL_LIMIT-1)finish(3);
   else begin polls<=polls+1'b1;transaction(K_POLL,2);end
  default:finish(0);
 endcase
 default:finish(1);
 endcase
 end end
 initial if(CLOCK_DIV<1||CLOCK_DIV>65535||(SPI_MODE!=0&&SPI_MODE!=3)||CS_HIGH_CYCLES<1||CS_HIGH_CYCLES>65535||HOST_TIMEOUT<1||POLL_LIMIT<1)$fatal(1,"invalid NOR parameters");
endmodule

module spi_nor_byte #(parameter integer CLOCK_DIV=2,SPI_MODE=0)(
 input wire clk,rst_n,cancel,start,input wire[7:0]tx,output reg[7:0]rx,
 output reg busy,done,output reg sclk,mosi,input wire miso);
 localparam CPOL=SPI_MODE==3,CPHA=SPI_MODE==3;
 reg[15:0]timer;reg[2:0]bitindex;reg[7:0]saved,shift;reg trailing;
 always @(posedge clk)begin
 if(!rst_n||cancel)begin rx<=0;busy<=0;done<=0;sclk<=CPOL;mosi<=0;timer<=0;bitindex<=0;saved<=0;shift<=0;trailing<=0;end
 else begin
 done<=0;
 if(start&&!busy)begin busy<=1;saved<=tx;shift<=0;bitindex<=0;trailing<=0;timer<=CLOCK_DIV-1;sclk<=CPOL;mosi<=tx[7];end
 else if(busy)begin
 if(timer!=0)timer<=timer-1'b1;
 else begin
  timer<=CLOCK_DIV-1;
  if(!trailing)begin sclk<=!CPOL;trailing<=1;if(CPHA)mosi<=saved[7-bitindex];else shift[7-bitindex]<=miso;end
  else begin
   sclk<=CPOL;trailing<=0;
   if(CPHA)shift[7-bitindex]<=miso;
   if(bitindex==7)begin busy<=0;done<=1;rx<=CPHA?{shift[7:1],miso}:shift;end
   else begin bitindex<=bitindex+1'b1;if(!CPHA)mosi<=saved[6-bitindex];end
  end
 end end
 end end
endmodule
`default_nettype wire
