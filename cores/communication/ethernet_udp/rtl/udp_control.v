// Transport-neutral one-outstanding CSR with canonical atomic configuration.
module udp_control #(parameter [63:0] BUILD_ID=0)(
 input wire clk,rst_n,req_valid,req_write,input wire [7:0] req_addr,
 input wire [31:0] req_data,input wire [3:0] req_strobe,
 output wire req_ready,resp_valid,output reg resp_error,output reg [31:0] resp_data,
 input wire resp_ready,output wire [7:0] probe
);
 reg response;reg[31:0] launched_version,run_id;
 wire take=req_valid&&req_ready;
 wire aligned=req_addr[1:0]==0;
 wire cfg_addr=req_addr>=8'h40&&req_addr<=8'h5c;
 wire wr,cr,pending,ready,done;wire[255:0] active;wire[31:0] version;
 wire cv=version!=launched_version;
 wire write_cfg=take&&req_write&&aligned&&cfg_addr;
 wire commit=take&&req_write&&aligned&&req_addr==12&&req_strobe==15&&req_data==1;
 wire ack=take&&req_write&&aligned&&req_addr==16&&req_strobe==15&&req_data==1&&done;
 wire[4:0] error;wire[31:0] cycles,tp,rp,tb,rb,tc,rc;wire txen;wire[1:0] txd;
 assign req_ready=rst_n&&!response;assign resp_valid=rst_n&&response;
 assign probe={error!=0,done,pending,txen,txd,cv,ready};
 sys_atomic_config #(.WORDS(8)) config_bank(clk,rst_n,write_cfg,wr,
  req_addr[4:2],req_data,req_strobe,commit,cr,ready&&!cv,active,version,pending);
 udp_replay replay(clk,rst_n,cv,ready,active[0+:16],active[16+:16],
  active[32+:32],active[64+:32],active[96+:2],done,ack,error,cycles,tp,rp,tb,rb,tc,rc,txen,txd);
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin launched_version<=0;run_id<=0;end
  else if(cv&&ready)begin launched_version<=version;run_id<=active[128+:32];end
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin response<=0;resp_error<=0;resp_data<=0;end
  else if(response)begin if(resp_ready)response<=0;end
  else if(take)begin
   response<=1;resp_error<=0;resp_data<=0;
   if(!aligned)resp_error<=1;
   else if(req_write)begin
    if(cfg_addr)begin if(!wr)resp_error<=1;end
    else if(req_addr==12)begin if(req_strobe!=15||req_data!=1||!cr)resp_error<=1;end
    else if(req_addr==16)begin if(req_strobe!=15||req_data!=1||!done)resp_error<=1;end
    else resp_error<=1;
   end else if(cfg_addr)resp_data<=active[req_addr[4:2]*32+:32];
   else case(req_addr)
    0:resp_data<=32'h55445031;
    4:resp_data<={27'd0,cv,cr,pending,done,ready};
    8:resp_data<=version;
    20:resp_data<=BUILD_ID[31:0];24:resp_data<=BUILD_ID[63:32];
    default:begin
     if(!done)resp_error<=1;
     else case(req_addr)
      8'h80:resp_data<=run_id;
      8'h84:resp_data<={27'd0,error};
      8'h88:resp_data<=cycles;
      8'h8c:resp_data<=tp;
      8'h90:resp_data<=rp;
      8'h94:resp_data<=tb;
      8'h98:resp_data<=rb;
      8'h9c:resp_data<=~tc;
      8'ha0:resp_data<=~rc;
      default:resp_error<=1;
     endcase
    end
   endcase
  end
 end
endmodule
