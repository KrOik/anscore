// Single-clock request/response CSR endpoint. Transport is deliberately separate.
module test_shell_csr(
 input wire clk,rst_n,
 input wire req_valid,req_write,input wire [7:0] req_addr,
 input wire [31:0] req_data,input wire [3:0] req_strobe,
 output wire req_ready,
 output reg resp_valid,output reg [31:0] resp_data,output reg resp_error,
 input wire resp_ready,
 input wire busy,done,run_error,
 input wire [31:0] frames,drops,cycles,
 output reg start,output reg [2:0] probe_page,
 output reg [31:0] seed,stall_mask,output reg [15:0] length
);
 localparam ID=32'h49503034; // "IP04"
 reg [31:0] merged;
 integer lane;
 assign req_ready=rst_n&&(!resp_valid||resp_ready);
 always @* begin
  case(req_addr)
   8'h08: merged={29'd0,probe_page};
   8'h0c: merged=seed;
   8'h10: merged={16'd0,length};
   8'h14: merged=stall_mask;
   default: merged=0;
  endcase
  for(lane=0;lane<4;lane=lane+1)
   if(req_strobe[lane]) merged[lane*8+:8]=req_data[lane*8+:8];
 end
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   resp_valid<=0; resp_data<=0; resp_error<=0; start<=0;
   probe_page<=0; seed<=1; length<=16; stall_mask<=0;
  end else begin
   start<=0;
   if(resp_valid&&resp_ready) resp_valid<=0;
   if(req_valid&&req_ready) begin
    resp_valid<=1; resp_data<=0; resp_error<=0;
    if(req_addr[1:0]!=0) resp_error<=1;
    else if(req_write) begin
     case(req_addr)
      8'h04: begin
       if(req_strobe[0]&&req_data[0]) begin
        if(busy) resp_error<=1; else start<=1;
       end
      end
      8'h08: begin
       if(merged>7) resp_error<=1; else probe_page<=merged[2:0];
      end
      8'h0c: if(busy) resp_error<=1; else seed<=merged;
      8'h10: begin
       if(busy||merged==0||merged>256) resp_error<=1;
       else length<=merged[15:0];
      end
      8'h14: if(busy) resp_error<=1; else stall_mask<=merged;
      default: resp_error<=1;
     endcase
    end else begin
     case(req_addr)
      8'h00: resp_data<=ID;
      8'h04: resp_data<={29'd0,run_error,done,busy};
      8'h08: resp_data<={29'd0,probe_page};
      8'h0c: resp_data<=seed;
      8'h10: resp_data<={16'd0,length};
      8'h14: resp_data<=stall_mask;
      8'h18: resp_data<=frames;
      8'h1c: resp_data<=drops;
      8'h20: resp_data<=cycles;
      default: resp_error<=1;
     endcase
    end
   end
  end
 end
endmodule
