// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_spectral_band_monitor;
 parameter integer N=1024,B=4,T=8,IQ=0;
 localparam integer IW=(N<2)?1:$clog2(N),SW=32+IW,MW=32+2*IW;
 reg clk=0;always #5 clk=~clk;
 reg rst=1,c_valid=0,s_valid=0,m_ready=0;
 wire c_ready,s_ready,m_valid;
 reg [31:0]c_bins=0,c_threshold=0,s_power=0;
 reg [32*B-1:0]c_low=0,c_high=0;
 reg [T-1:0]c_tag=0;
 wire[1:0]m_status;wire[31:0]m_band,m_low,m_high,m_peak_power,m_peak_bin,m_above;
 wire[SW-1:0]m_energy;wire[MW-1:0]m_moment;wire m_last;wire[T-1:0]m_tag;
 generate if(IQ)begin:example
   iq_spectral_band_monitor dut(.clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),.c_bins(c_bins),.c_threshold(c_threshold),
    .c_low(c_low),.c_high(c_high),.c_tag(c_tag),.s_valid(s_valid),.s_ready(s_ready),.s_iq(s_power),
    .m_valid(m_valid),.m_ready(m_ready),.m_status(m_status),.m_band(m_band),.m_low(m_low),.m_high(m_high),
    .m_energy(m_energy),.m_moment(m_moment),.m_peak_power(m_peak_power),.m_peak_bin(m_peak_bin),.m_above(m_above),.m_last(m_last),.m_tag(m_tag));
 end else begin:core
   spectral_band_monitor #(.MAX_BINS(N),.BANDS(B),.TAG_W(T)) dut(.*);
 end endgenerate
 integer fd,rc,k,j,checks=0,commands=0,samples=0,stalls=0,resets=0,waits;
 reg[63:0]v[0:11];reg[2047:0]path;
 localparam integer BW=195+SW+MW+T;
 wire[BW-1:0]bundle={m_status,m_band,m_low,m_high,m_energy,m_moment,m_peak_power,m_peak_bin,m_above,m_last,m_tag};
 task command(input[31:0]n,thr,input[T-1:0]tag);
 begin
   @(negedge clk);waits=0;
   while(!c_ready)begin @(negedge clk);waits=waits+1;if(waits>20000)$fatal(1,"command timeout");end
   c_valid=1;c_bins=n;c_threshold=thr;c_tag=tag;
   @(posedge clk);@(negedge clk);c_valid=0;c_bins='1;c_threshold='1;c_tag=~tag;c_low='1;c_high=0;
   commands=commands+1;
 end endtask
 task sample(input[31:0]data);
 begin
   waits=0;while(!s_ready)begin @(negedge clk);waits=waits+1;if(waits>20000)$fatal(1,"sample timeout");end
   s_valid=1;s_power=data;@(posedge clk);@(negedge clk);s_valid=0;s_power=~data;samples=samples+1;
 end endtask
 task check(input[63:0]status,band,lo,hi,energy,moment,peak,index,above,last,tag);
 reg[BW-1:0]held;
 begin
   @(negedge clk);waits=0;while(!m_valid)begin @(negedge clk);waits=waits+1;if(waits>20000)$fatal(1,"result timeout");end
   if(m_status!==status[1:0]||m_band!==band[31:0]||m_low!==lo[31:0]||m_high!==hi[31:0]||m_energy!==energy[SW-1:0]||
      m_moment!==moment[MW-1:0]||m_peak_power!==peak[31:0]||m_peak_bin!==index[31:0]||m_above!==above[31:0]||m_last!==last[0]||m_tag!==tag[T-1:0])
     $fatal(1,"record%0d band%0d status%0d energy%h/%h moment%h/%h peak%h/%h at%0d/%0d above%0d/%0d tag%h/%h",checks,m_band,m_status,m_energy,energy,m_moment,moment,m_peak_power,peak,m_peak_bin,index,m_above,above,m_tag,tag);
   held=bundle;
   repeat(3)begin
     @(posedge clk);#1;if(!m_valid||bundle!==held||c_ready||s_ready)$fatal(1,"held record/ownership");stalls=stalls+1;
   end
   @(negedge clk);m_ready=1;@(posedge clk);@(negedge clk);m_ready=0;checks=checks+1;
 end endtask
 task reset_core;
 begin
   @(negedge clk);rst=1;c_valid=0;s_valid=0;m_ready=0;
   @(posedge clk);#1;if(m_valid||c_ready||s_ready)$fatal(1,"reset cancellation");
   @(negedge clk);rst=0;@(negedge clk);if(!c_ready||m_valid||s_ready)$fatal(1,"reset recovery");resets=resets+1;
 end endtask
 task singleton_config;
 begin for(j=0;j<B;j=j+1)begin c_low[32*j+:32]=0;c_high[32*j+:32]=0;end end
 endtask
 initial begin
   if(!$value$plusargs("vectors=%s",path))$fatal(1,"vector path missing");
   reset_core;fd=$fopen(path,"r");if(!fd)$fatal(1,"vectors missing");
   while(!$feof(fd))begin
     rc=$fscanf(fd,"%h %h %h %h %h %h %h %h %h %h %h %h\n",v[0],v[1],v[2],v[3],v[4],v[5],v[6],v[7],v[8],v[9],v[10],v[11]);
     if(rc!=12)$fatal(1,"malformed vectors");
     case(v[0])
       0:begin c_low[32*v[1]+:32]=v[2][31:0];c_high[32*v[1]+:32]=v[3][31:0];end
       1:command(v[1][31:0],v[2][31:0],v[3][T-1:0]);
       2:sample(v[1][31:0]);
       3:check(v[1],v[2],v[3],v[4],v[5],v[6],v[7],v[8],v[9],v[10],v[11]);
       4:repeat(v[1])@(negedge clk);
       default:$fatal(1,"bad operation");
     endcase
   end
   $fclose(fd);
   singleton_config;command(N,0,8'hc1);if(N>1)sample(32'h80008000);reset_core;
   singleton_config;command(1,0,8'hc2);sample(32'h80008000);reset_core;
   singleton_config;command(1,0,8'hc3);sample(32'h80008000);
   while(!m_valid)@(negedge clk);repeat(2)@(negedge clk);reset_core;
   singleton_config;command(1,0,8'hc4);sample(32'h80008000);
   for(k=0;k<B;k=k+1)check(0,k,0,0,IQ?64'h80000000:64'h80008000,0,IQ?64'h80000000:64'h80008000,0,1,k==B-1,T'(8'hc4));
   if(checks==0||stalls==0||resets!=4)$fatal(1,"vacuous coverage");
   $display("PASS spectral_band_monitor N=%0d B=%0d T=%0d IQ=%0d records=%0d samples=%0d commands=%0d held_cycles=%0d resets=%0d",N,B,T,IQ,checks,samples,commands,stalls,resets);
   $finish;
 end
 initial begin #10000000;$fatal(1,"global TB deadline");end
endmodule
