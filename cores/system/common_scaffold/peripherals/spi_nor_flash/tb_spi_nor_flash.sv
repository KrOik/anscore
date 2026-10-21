module tb;
 parameter DIV=2,MODE=0,HIGH=4;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,ce=1,abort=0,cmd_valid=0,w_valid=0,r_ready=0,rsp_ready=0;
 reg[3:0]cmd_op=0;reg[23:0]cmd_addr=0;reg[8:0]cmd_length=0;reg[7:0]w_data=0;
 wire cmd_ready,w_ready,r_valid,rsp_valid,busy,spi_cs_n,spi_sclk,spi_mosi,spi_miso;
 wire[7:0]r_data,rsp_status;wire[3:0]rsp_error;wire[8:0]rsp_bytes;
 reg force_busy=0,reject_wren=0;reg[1:0]busy_polls=3;
 spi_nor_flash #(.CLOCK_DIV(DIV),.SPI_MODE(MODE),.CS_HIGH_CYCLES(HIGH),.HOST_TIMEOUT(32),.POLL_LIMIT(5))dut(.*);
 nor_device_model #(.MIN_CS_NS(HIGH*10))flash(.rst_n(rst_n),.cs_n(spi_cs_n),.sclk(spi_sclk),.mosi(spi_mosi),.miso(spi_miso),.force_busy(force_busy),.reject_wren(reject_wren),.busy_polls(busy_polls));
 reg[7:0]expected[0:65535];integer page,ln,ii,cycle=0,checks=0,received=0;reg receive_enable=1;integer active_op=0,active_addr=0,active_len=0;
 function[7:0]pattern;input integer seed,index;begin pattern=(seed*37+index*73)^(index>>1);end endfunction
 always @(negedge clk)begin cycle=cycle+1;ce=cycle%7!=0;r_ready=receive_enable&&(cycle%5!=0);if(cycle>2000000)$fatal(1,"watchdog");end
 always @(posedge clk)if(r_valid&&r_ready)begin
  if(active_op==0)begin case(received)0:if(r_data!=8'hef)$fatal;1:if(r_data!=8'h40)$fatal;2:if(r_data!=8'h18)$fatal;default:$fatal;endcase end
  else if(active_op==1||active_op==2)begin if(r_data!==(active_addr+received<65536?expected[active_addr+received]:8'hff))$fatal(1,"read data addr%h got%h expected%h",active_addr+received,r_data,expected[active_addr+received]);end
  received=received+1;
 end
 task descriptor;
 input integer op,addr,len;
 begin
 @(negedge clk);cmd_op=op;cmd_addr=addr;cmd_length=len;cmd_valid=1;active_op=op;active_addr=addr;active_len=len;received=0;
 @(posedge clk);while(!cmd_ready)@(posedge clk);@(negedge clk);cmd_valid=0;
 end endtask
 task response;
 input integer err,bytes;
 reg[3:0]held_error;reg[8:0]held_bytes;reg[7:0]held_status;
 begin
 @(posedge clk);while(!rsp_valid)@(posedge clk);
 if(rsp_error!=err||rsp_bytes!=bytes||!spi_cs_n||spi_sclk!==(MODE==3))$fatal(1,"response got error%0d bytes%0d expected%0d/%0d",rsp_error,rsp_bytes,err,bytes);
 held_error=rsp_error;held_bytes=rsp_bytes;held_status=rsp_status;
 repeat(5)begin @(posedge clk);if(!rsp_valid||rsp_error!=held_error||rsp_bytes!=held_bytes||rsp_status!=held_status||cmd_ready)$fatal(1,"response stability");end
 @(negedge clk);rsp_ready=1;@(posedge clk);@(negedge clk);rsp_ready=0;checks=checks+1;
 end endtask
 task operation;
 input integer op,addr,len,seed;
 integer b;
 begin
 descriptor(op,addr,len);
 if(op==3)for(b=0;b<len;b=b+1)begin
  repeat(b%3)@(negedge clk);w_data=pattern(seed,b);w_valid=1;
  @(posedge clk);while(!w_ready)@(posedge clk);@(negedge clk);w_valid=0;
 end
 response(0,(op==0||op==1||op==2||op==3||op==6)?len:0);
 if(op==0||op==1||op==2||op==6)if(received!=len)$fatal(1,"read count");
 if(op==3)for(b=0;b<len;b=b+1)expected[addr+b]=expected[addr+b]&pattern(seed,b);
 if(op==4)for(b=0;b<4096;b=b+1)expected[addr+b]=8'hff;
 end endtask
 initial begin
 for(ii=0;ii<65536;ii=ii+1)expected[ii]=8'hff;
 repeat(4)@(negedge clk);rst_n=1;repeat(HIGH+2)@(negedge clk);
 operation(0,0,3,0);operation(5,0,0,0);operation(6,0,1,0);if(!rsp_status[1])$fatal(1,"WEL missing");
 operation(3,0,256,17);operation(1,0,256,0);operation(2,0,256,0);
 operation(3,17,63,71);operation(1,0,256,0);
 operation(3,16'h12f9,7,21);operation(2,16'h12f8,8,0);
 operation(4,0,0,0);operation(1,0,256,0);operation(1,16'h12f9,7,0);
 operation(4,16'h1000,0,0);operation(2,16'h1200,256,0);operation(7,0,0,0);
 for(page=0;page<12;page=page+1)begin
  ln=(page*29)%256+1;
  operation(3,16'h3000+page*256,ln,page*13+9);
  operation(page%2==0?1:2,16'h3000+page*256,ln,0);
 end
 operation(1,24'h123456,7,0);operation(2,24'hffffff,1,0);
 operation(4,16'h3000,0,0);operation(2,16'h3000,256,0);
 // A byte arriving on the final permitted preload cycle wins over timeout.
 descriptor(3,16'h2000,1);repeat(31)@(negedge clk);w_valid=1;w_data=8'haa;
 @(posedge clk);if(!w_ready)$fatal(1,"deadline ready");@(negedge clk);w_valid=0;
 response(0,1);expected[16'h2000]=8'haa;operation(1,16'h2000,1,0);
 // Explicit descriptor rejection; no wire transaction is launched.
 descriptor(3,255,2);response(1,0);descriptor(4,1,0);response(1,0);
 descriptor(1,24'hffffff,2);response(1,0);descriptor(0,0,2);response(1,0);
 descriptor(9,0,0);response(1,0);descriptor(1,0,0);response(1,0);
 descriptor(3,0,1);response(2,0); // preload starvation, no destructive command
 receive_enable=0;descriptor(1,0,1);response(2,0);receive_enable=1;
 force_busy=1;descriptor(7,0,0);response(3,0);
 descriptor(1,0,1);response(5,0);descriptor(4,0,0);response(5,0);force_busy=0;
 reject_wren=1;descriptor(5,0,0);response(4,0);reject_wren=0;
 descriptor(3,0,1);@(negedge clk);abort=1;@(negedge clk);abort=0;response(6,0);
 // Abort while a physical byte is active; subsequent command must recover cleanly.
 descriptor(1,0,1);wait(!spi_cs_n);repeat(3*DIV)@(negedge clk);abort=1;@(negedge clk);abort=0;response(6,0);
 repeat(HIGH+2)@(negedge clk);operation(0,0,3,0);
 receive_enable=0;descriptor(1,0,1);wait(r_valid);
 repeat(4)begin @(posedge clk);if(!r_valid||r_data!=8'hff)$fatal(1,"held read changed");end
 @(negedge clk);abort=1;@(negedge clk);abort=0;response(6,0);receive_enable=1;
 // A coincident accepted R beat is counted even though abort wins completion.
 receive_enable=0;descriptor(1,0,1);wait(r_valid);
 @(negedge clk);#1;abort=1;r_ready=1;
 @(negedge clk);abort=0;response(6,1);receive_enable=1;
 // Abort does not replace an already completed, backpressured response.
 descriptor(9,0,0);wait(rsp_valid);@(negedge clk);abort=1;
 repeat(4)begin @(posedge clk);if(!rsp_valid||rsp_error!=1||rsp_bytes!=0||!spi_cs_n||spi_sclk!==(MODE==3))$fatal(1,"abort overwrote completed response");end
 @(negedge clk);abort=0;response(1,0);
 // Coordinated controller reset drops a staged request and pending read output.
 descriptor(3,16'h2000,2);@(negedge clk);rst_n=0;repeat(3)@(negedge clk);rst_n=1;
 repeat(HIGH+2)@(negedge clk);if(rsp_valid||r_valid||!spi_cs_n||busy)$fatal(1,"reset not idle");
 operation(0,0,3,0);
 if(flash.programs!=16||flash.erases!=3)$fatal(1,"device destructive transaction count");
 $display("NOR PASS mode%0d div%0d high%0d checks%0d programs%0d erases%0d",MODE,DIV,HIGH,checks,flash.programs,flash.erases);$finish;
 end
endmodule

