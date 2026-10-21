// Transport-neutral, one-outstanding CSR slave. Addresses are byte addresses.
module lockin_control #(
 parameter [63:0] BUILD_ID=0,
 parameter SIN_FILE="cores/signal_processing/lockin/vectors/sine.mem",
 parameter COS_FILE="cores/signal_processing/lockin/vectors/cosine.mem"
)(
 input wire clk,rst_n,req_valid,req_write,input wire [7:0] req_addr,
 input wire [31:0] req_data,input wire [3:0] req_strobe,
 output wire req_ready,resp_valid,output reg resp_error,output reg [31:0] resp_data,
 input wire resp_ready,output wire [7:0] probe
);
 reg response;
 wire take=req_valid&&req_ready;
 wire aligned=req_addr[1:0]==0;
 wire cfg_addr=req_addr>=8'h40&&req_addr<=8'h7c;
 wire full=req_strobe==15;
 wire wr,cr,pending,cv,ready,done;
 wire [511:0] active;wire [31:0] version;
 wire write_cfg=take&&req_write&&aligned&&cfg_addr;
 wire commit=take&&req_write&&aligned&&req_addr==12&&full&&req_data==1;
 wire ack=take&&req_write&&aligned&&req_addr==16&&full&&req_data==1&&done;
 wire [63:0] oi,oq,amp,first,last;wire [71:0] phase;
 wire [31:0] id,cycles,generated,accepted,dropped;wire [7:0] error;
 assign req_ready=rst_n&&!response;
 assign resp_valid=rst_n&&response;
 assign probe={error!=0,done,pending,cv,ready,commit,req_valid,req_ready};
 lockin_config cfg(clk,rst_n,write_cfg,wr,req_addr[5:2],req_data,req_strobe,
  commit,cr,ready,ready,cv,active,version,pending);
 lockin_replay #(.SIN_FILE(SIN_FILE),.COS_FILE(COS_FILE)) replay(
  clk,rst_n,cv,ready,active[0+:32],active[32+:32],active[96+:32],active[128+:32],active[64+:4],
  active[160+:64],active[256+:64],active[320+:64],active[224+:32],!active[384],
  done,ack,oi,oq,amp,phase,first,last,id,cycles,generated,accepted,dropped,error);
 integer lane;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin response<=0;resp_error<=0;resp_data<=0;end
  else if(response)begin if(resp_ready)response<=0;end
  else if(take)begin
   response<=1;resp_error<=0;resp_data<=0;
   if(!aligned)resp_error<=1;
   else if(req_write)begin
    if(cfg_addr)begin if(!wr)resp_error<=1;end
    else if(req_addr==12)begin if(!full||req_data!=1||!cr)resp_error<=1;end
    else if(req_addr==16)begin if(!full||req_data!=1||!done)resp_error<=1;end
    else resp_error<=1;
   end else if(cfg_addr)resp_data<=active[req_addr[5:2]*32+:32];
   else case(req_addr)
    0:resp_data<=32'h4c4f434b;
    4:resp_data<={27'd0,cv,cr,pending,done,ready};
    8:resp_data<=version;
    20:resp_data<=BUILD_ID[31:0];
    24:resp_data<=BUILD_ID[63:32];
    default:begin
     if(!done)resp_error<=1;
     else case(req_addr)
      8'h80:resp_data<=id;
      8'h84:resp_data<={24'd0,error};
      8'h88:resp_data<=cycles;
      8'h8c:resp_data<=generated;
      8'h90:resp_data<=accepted;
      8'h94:resp_data<=dropped;
      8'h98:resp_data<=first[31:0];
      8'h9c:resp_data<=first[63:32];
      8'ha0:resp_data<=last[31:0];
      8'ha4:resp_data<=last[63:32];
      default:begin
       if(req_addr>=8'hb0&&req_addr<=8'hdc)begin
        lane=(req_addr-8'hb0)/12;
        case((req_addr-8'hb0)%12)
         0:resp_data<={oq[lane*16+:16],oi[lane*16+:16]};
         4:resp_data<={16'd0,amp[lane*16+:16]};
         8:resp_data<={{14{phase[lane*18+17]}},phase[lane*18+:18]};
        endcase
       end else resp_error<=1;
      end
     endcase
    end
   endcase
  end
 end
endmodule
