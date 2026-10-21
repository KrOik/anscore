// Isolated test harness: synchronous reset requires the continuously running board clock during POR.
// Generic public-image-wrapper ROM acceptance driver. All DUT transactions use CE.
// UART runs at the physical clock rate; DUT CE_DIV=4 is recorded in manifests.
module acceptance48_driver #(parameter COMMANDS=1, parameter CASE_ID=32'h42524954,
 parameter CE_DIV=4, parameter TIMEOUT_CYCLES=50000000, parameter UART_DIV=434)(
 input wire clk,rst_n,
 output reg [15:0] command_index,input wire [383:0] configuration,
 output wire [15:0] input_index,aux_index,coefficient_index,expected_index,
 input wire [33:0] input_word,aux_word,expected_word,input wire [47:0] coefficient_word,
 output wire ce,cmd_valid,input wire cmd_ready,
 output wire [7:0] cmd_tag,input wire rsp_valid,output wire rsp_ready,
 input wire [7:0] rsp_tag,input wire [1:0] rsp_error,
 output wire s_valid,input wire s_ready,output wire aux_valid,input wire aux_ready,
 output wire coeff_valid,input wire coeff_ready,input wire m_valid,
 output wire m_ready,input wire [31:0] m_data,input wire m_sof,m_eol,
 input wire unexpected_memory,output wire uart_tx,
 output wire done,output reg [31:0] error_count,digest,output reg timed_out);
localparam ISSUE=0,RUN=1,NEXT=2,REPORT=3,FINISH=4;
reg [2:0] state;reg [15:0] sent,received,aux_sent,coeff_sent;
reg [31:0] timer,tick;reg [15:0] divider;
wire [15:0] ni=configuration[251:236],no=configuration[267:252],na=configuration[283:268],nk=configuration[299:284];
assign input_index=configuration[317:302]+sent;
assign expected_index=configuration[333:318]+received;
assign aux_index=configuration[349:334]+aux_sent;
assign coefficient_index=configuration[365:350]+coeff_sent;
assign ce=divider==CE_DIV-1;
assign cmd_valid=rst_n && state==ISSUE;
assign cmd_tag=configuration[11:4];
assign rsp_ready=rst_n && state==RUN;
// Source and aux stay asserted and retain their ROM word until CE handshake.
assign s_valid=rst_n && state==RUN && sent<ni;
assign aux_valid=rst_n && state==RUN && aux_sent<na;
assign coeff_valid=rst_n && state==RUN && coeff_sent<nk;
assign m_ready=state==RUN && tick[2:0]!=3;
wire take_s=s_valid && s_ready,take_a=aux_valid && aux_ready,take_k=coeff_valid && coeff_ready;
wire take_m=m_valid && m_ready;
wire bad_pixel=take_m && (received>=no || m_data!==expected_word[31:0]);
wire bad_marker=take_m && (m_sof!==expected_word[33] || m_eol!==expected_word[32]);
wire bad_response=rsp_valid && ((sent+take_s)!=ni || (received+take_m)!=no || (aux_sent+take_a)!=na ||
 (coeff_sent+take_k)!=nk || rsp_tag!=cmd_tag || rsp_error!=configuration[301:300]);
wire [3:0] faults={3'b0,bad_pixel}+{3'b0,bad_marker}+{3'b0,bad_response}+{3'b0,unexpected_memory};
assign done=state==FINISH;
// Register scoreboard faults before the wide error accumulator. NEXT provides
// a CE interval to retire the final response event before UART reporting.
reg [1:0] next_age;
always @(posedge clk)begin
 if(!rst_n)next_age<=0;
 else if(state!=NEXT)next_age<=0;
 else if(next_age!=3)next_age<=next_age+1'b1;
end
// A consumed response has a clock to withdraw; by the next CE it must be gone.
wire outside_output=(state==ISSUE || state==NEXT) && m_valid;
wire outside_response=(state==ISSUE || (state==NEXT && next_age>=2)) && rsp_valid;
reg [3:0] pending_faults;
// Byte carry retirement avoids a 32-LUT ripple path in the harness itself.
// The full count is exact four clocks after an event; NEXT lasts CE_DIV clocks.
reg carry0,carry1,carry2;
wire [8:0] count0={1'b0,error_count[7:0]}+pending_faults;
wire [8:0] count1={1'b0,error_count[15:8]}+carry0;
wire [8:0] count2={1'b0,error_count[23:16]}+carry1;
wire [8:0] count3={1'b0,error_count[31:24]}+carry2;
always @(posedge clk)begin
 if(!rst_n)begin pending_faults<=0;error_count<=0;carry0<=0;carry1<=0;carry2<=0;end
 else begin
  pending_faults<=0;
  if(ce && state==RUN)pending_faults<=faults;
  else if(ce && (state==ISSUE || state==NEXT))pending_faults<={3'b0,outside_output}+{3'b0,outside_response};
  if(state<REPORT && timer>=TIMEOUT_CYCLES-1)pending_faults<=1;
  error_count<={count3[7:0],count2[7:0],count1[7:0],count0[7:0]};
  carry0<=count0[8];carry1<=count1[8];carry2<=count2[8];
 end
end
wire report_done;
always @(posedge clk)begin
 if(!rst_n)begin state<=ISSUE;command_index<=0;sent<=0;received<=0;aux_sent<=0;coeff_sent<=0;
 timer<=0;tick<=0;divider<=0;digest<=32'h811c9dc5;timed_out<=0;end
 else begin
  divider<=ce?0:divider+1'b1;
  if(state<REPORT)begin
   if(timer>=TIMEOUT_CYCLES-1)begin timed_out<=1;state<=REPORT;end
   else begin
    timer<=timer+1'b1;
    if(ce)begin
     tick<=tick+1'b1;
     case(state)
      ISSUE:if(cmd_ready)begin state<=RUN;timer<=0;end
      RUN:begin

       if(take_s)sent<=sent+1'b1;if(take_a)aux_sent<=aux_sent+1'b1;if(take_k)coeff_sent<=coeff_sent+1'b1;
       if(take_m)begin received<=received+1'b1;digest<={digest[26:0],digest[31:27]} ^ m_data ^ {30'd0,m_sof,m_eol};end
       if(rsp_valid)state<=NEXT;
      end
      NEXT:begin
       if(command_index==COMMANDS-1)state<=REPORT;
       else begin command_index<=command_index+1'b1;state<=ISSUE;sent<=0;received<=0;aux_sent<=0;coeff_sent<=0;timer<=0;end
      end
     endcase
    end
   end
  end
  else if(state==REPORT && report_done)state<=FINISH;
 end
end
acceptance48_report #(.DIV(UART_DIV),.CASE_ID(CASE_ID)) reporter(.clk(clk),.rst_n(rst_n),.start(state==REPORT),
 .errors(error_count),.digest(digest),.timeout(timed_out),.tx(uart_tx),.done(report_done));
endmodule

// Exactly: A48 IIIIIIII PASS E=EEEEEEEE D=DDDDDDDD T=0\r\n (or FAIL).
module acceptance48_report #(parameter DIV=434,parameter CASE_ID=0)(
 input wire clk,rst_n,start,input wire [31:0] errors,digest,input wire timeout,
 output wire tx,output reg done);
reg [5:0] index;reg sending;wire busy;wire [7:0] character;
function [7:0] hexchar;input [3:0] n;begin hexchar=n<10?48+n:65+n-10;end endfunction
function [7:0] msg;input [5:0] i;begin
 case(i)
 0:msg="A";1:msg="4";2:msg="8";3:msg=" ";12:msg=" ";
 13:msg=errors==0?"P":"F";14:msg=errors==0?"A":"A";15:msg=errors==0?"S":"I";16:msg=errors==0?"S":"L";
 17:msg=" ";18:msg="E";19:msg="=";28:msg=" ";29:msg="D";30:msg="=";39:msg=" ";40:msg="T";41:msg="=";
 42:msg=timeout?"1":"0";43:msg=13;44:msg=10;
 default:if(i>=4 && i<=11)msg=hexchar(CASE_ID>>((11-i)*4));
 else if(i>=20 && i<=27)msg=hexchar(errors>>((27-i)*4));
 else if(i>=31 && i<=38)msg=hexchar(digest>>((38-i)*4));else msg="?";
 endcase
end endfunction
assign character=msg(index);
wire launch=start && !done && !sending && !busy;
acceptance48_uart #(.DIV(DIV)) uart(.clk(clk),.rst_n(rst_n),.valid(launch),.data(character),.busy(busy),.tx(tx));
always @(posedge clk)begin
 if(!rst_n)begin index<=0;sending<=0;done<=0;end
 else if(start && !done)begin
  if(launch)sending<=1;
  if(sending && !busy)begin sending<=0;if(index==44)done<=1;else index<=index+1'b1;end
 end
end
endmodule
module acceptance48_uart #(parameter DIV=434)(input wire clk,rst_n,valid,input wire [7:0] data,output wire busy,tx);
reg [9:0] shift;reg [3:0] bits;reg [15:0] count;
assign busy=bits!=0;assign tx=busy?shift[0]:1'b1;
always @(posedge clk)begin
 if(!rst_n)begin shift<=10'h3ff;bits<=0;count<=0;end
 else if(!busy)begin if(valid)begin shift<={1'b1,data,1'b0};bits<=10;count<=DIV-1;end end
 else if(count==0)begin shift<={1'b1,shift[9:1]};bits<=bits-1'b1;count<=DIV-1;end
 else count<=count-1'b1;
end
endmodule
