`timescale 1ns/1ps
module tb;
 parameter HZ=10000000,HIGH_NS=1000,LOW_NS=1000,DEPTH=4;
 localparam real HALF=500000000.0/HZ;
 reg clk=0;always #(HALF)clk=~clk;
 reg rst_n=0,ce=1,abort=0,power_down=0,req_valid=0,out_ready=0,suppress_ready=0;
 reg[1:0]req_mode=0;wire req_ready,dout,pd_sck,out_valid,busy,powered_down;
 wire signed[23:0]out_data;wire[1:0]out_mode,out_next_mode;wire[2:0]out_error;wire[31:0]out_sequence;
 wire[31:0]accepted_count,completed_count,dropped_count,timeout_count;
 hx711_adc #(.CLOCK_HZ(HZ),.SCK_HIGH_NS(HIGH_NS),.SCK_LOW_NS(LOW_NS),.READY_TIMEOUT_US(100),.POWERDOWN_US(80),.WAKE_US(2),.FIFO_DEPTH(DEPTH))dut(.*);
 hx711_device_model device(.pd_sck(pd_sck),.dout(dout),.suppress_ready(suppress_ready));
 integer cycles=0,checks=0,index=0,curmode=0,seq_expected=0,ii;reg[23:0]held;integer olddrops,oldcompleted,oldaccepted,pulses_before;
 function[23:0]golden;
 input integer m,n;reg[23:0]b;
 begin case(n%6)0:b=24'h800000;1:b=24'h7fffff;2:b=24'hffffff;3:b=24'h000000;4:b=24'h123456;default:b=24'hedcbaa;endcase golden=b^(m*65793);end endfunction
 always @(negedge clk)begin cycles=cycles+1;ce=cycles%7!=0;if(cycles>3000000)$fatal(1,"watchdog");end
 task request;input integer nmode;begin
 @(negedge clk);req_mode=nmode;req_valid=1;@(posedge clk);while(!req_ready)@(posedge clk);@(negedge clk);req_valid=0;
 end endtask
 task packet;input integer err,mode,nmode,seq;input[23:0]value;
 reg[63:0]heldpacket;
 begin
 @(posedge clk);while(!out_valid)@(posedge clk);
 if(out_error!=err||out_mode!=mode||out_next_mode!=nmode||out_sequence!=seq||(err==0&&out_data!==value))$fatal(1,"packet seq%0d err%0d mode%0d next%0d data%h expected seq%0d err%0d mode%0d next%0d data%h",out_sequence,out_error,out_mode,out_next_mode,out_data,seq,err,mode,nmode,value);
 heldpacket={out_sequence,out_error,out_next_mode,out_mode,out_data};
 repeat(9)begin @(posedge clk);if(!out_valid||{out_sequence,out_error,out_next_mode,out_mode,out_data}!==heldpacket)$fatal(1,"held FIFO output changed");end
 @(negedge clk);out_ready=1;@(posedge clk);@(negedge clk);out_ready=0;checks=checks+1;
 end endtask
 task acquire;input integer nmode;begin
 request(nmode);packet(0,curmode,nmode,seq_expected,golden(curmode,index));index=index+1;curmode=nmode;seq_expected=seq_expected+1;
 end endtask
 task wake;begin wait(!busy);repeat(5)@(negedge clk);index=0;curmode=0;end endtask
 initial begin
 repeat(4)@(negedge clk);rst_n=1;wake;
 for(ii=0;ii<12;ii=ii+1)acquire((ii+1)%3);
 pulses_before=device.normal_pulses;request(3);packet(1,curmode,3,seq_expected,0);seq_expected=seq_expected+1;
 if(device.normal_pulses!=pulses_before)$fatal(1,"bad descriptor emitted pulses");
 // Leave FIFO full: new completed acquisitions are dropped, never stall SCK high.
 olddrops=dropped_count;oldcompleted=completed_count;
 for(ii=0;ii<DEPTH+3;ii=ii+1)begin request(0);wait(completed_count==oldcompleted+ii+1);end
 if(dropped_count!=olddrops+3)$fatal(1,"drop accounting");
 for(ii=0;ii<DEPTH;ii=ii+1)begin packet(0,ii==0?curmode:0,0,seq_expected+ii,golden(ii==0?curmode:0,index+ii));end
 index=index+DEPTH+3;seq_expected=seq_expected+DEPTH+3;curmode=0;
 acquire(2);
 // CE low during an accepted conversion and output backpressure cannot freeze SCK.
 request(1);force ce=0;packet(0,2,1,seq_expected,golden(2,index));release ce;index=index+1;seq_expected=seq_expected+1;curmode=1;
 // Intentional power-down resets ADC next channel to A128; queued output survives.
 @(negedge clk);power_down=1;repeat(3)@(negedge clk);power_down=0;wake;acquire(2);
 // Suppress asynchronous readiness; timeout produces no normal clocks.
 suppress_ready=1;repeat(10)@(negedge clk);pulses_before=device.normal_pulses;
 request(1);packet(2,2,1,seq_expected,0);seq_expected=seq_expected+1;
 if(timeout_count!=1||device.normal_pulses!=pulses_before)$fatal(1,"ready timeout safety");
 // Short asynchronous ready glitches must not start a clock burst or reset timeout.
 request(1);
 repeat(10)begin @(negedge clk);force dout=1'b0;@(negedge clk);release dout;repeat(2)@(negedge clk);end
 packet(2,2,1,seq_expected,0);seq_expected=seq_expected+1;
 if(timeout_count!=2||device.normal_pulses!=pulses_before)$fatal(1,"ready glitch guard");suppress_ready=0;
 // Abort a waiting request; physical power cycle restores known mode.
 suppress_ready=1;request(0);repeat(3)@(negedge clk);abort=1;@(negedge clk);abort=0;
 packet(3,2,0,seq_expected,0);seq_expected=seq_expected+1;suppress_ready=0;wake;acquire(1);
 // Abort while SCK is high: hold high intentionally to reset, never truncate pulses.
 request(2);wait(pd_sck);@(negedge clk);abort=1;@(negedge clk);abort=0;
 packet(3,1,2,seq_expected,0);seq_expected=seq_expected+1;wake;acquire(2);
 // Power-down interrupts active work with explicit error4.
 request(1);wait(pd_sck);@(negedge clk);power_down=1;repeat(5)@(negedge clk);power_down=0;
 packet(4,2,1,seq_expected,0);seq_expected=seq_expected+1;wake;acquire(0);
 if(accepted_count!=completed_count||dropped_count!=3)$fatal(1,"terminal accounting");
 // Reset drops queued outputs/counters and deliberately resets the physical ADC.
 request(0);wait(out_valid);@(negedge clk);rst_n=0;repeat(4)@(negedge clk);rst_n=1;seq_expected=0;wake;
 if(out_valid||accepted_count||completed_count||dropped_count||timeout_count)$fatal(1,"reset state");acquire(0);
 $display("HX711 PASS HZ%0d high%0d low%0d depth%0d checks%0d normalmax%0t",HZ,HIGH_NS,LOW_NS,DEPTH,checks,device.max_high);$finish;
 end
endmodule
