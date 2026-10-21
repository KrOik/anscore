// Transport-neutral CSR wrapper around the canonical synchronous replay RAM.
// Word addresses are byte-addressed, aligned, and all writes require strobe=15.
module csr_capture_replay #(parameter DEPTH=256, TIMEOUT=1000000)(
 input wire clk,rst_n,req_valid,req_write,input wire [7:0] req_addr,
 input wire [31:0] req_data,input wire [3:0] req_strobe,
 output wire req_ready,output reg resp_valid,resp_error,
 output reg [31:0] resp_data,input wire resp_ready,
 output wire [31:0] s_data,output wire s_valid,input wire s_ready,
 input wire [31:0] m_data,input wire m_valid,output wire m_ready,
 output wire active,done,error
);
 localparam AW=$clog2(DEPTH);
 reg [15:0] input_length,output_length;
 reg [AW-1:0] write_index,read_index;
 reg read_wait;
 wire [15:0] issued,captured;
 wire [31:0] cycles,read_data;
 wire accept=req_valid&&req_ready;
 wire aligned=req_addr[1:0]==0;
 wire writable=accept&&req_write&&aligned&&req_strobe==15&&!active;
 wire launch=writable&&req_addr==0&&req_data==1;
 wire load=writable&&req_addr==8'h10;
 assign req_ready=rst_n&&!read_wait&&(!resp_valid||resp_ready);
 sys_capture_replay #(.DEPTH(DEPTH),.IN_WIDTH(32),.OUT_WIDTH(32),.TIMEOUT(TIMEOUT)) ram(
 .clk(clk),.rst_n(rst_n),.host_write(load),.host_address(write_index),.host_data(req_data),
 .start(launch),.input_length(input_length),.output_length(output_length),
 .s_data(s_data),.s_valid(s_valid),.s_ready(s_ready),
 .m_data(m_data),.m_valid(m_valid),.m_ready(m_ready),
 .host_read(!active),.read_address(read_index),.read_data(read_data),
 .active(active),.done(done),.error(error),.issued(issued),.captured(captured),.cycles(cycles));
 // Read-index writes insert a pipeline bubble so immediately following reads
 // always see the newly selected synchronous RAM word, including pipelined CSR.
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   resp_valid<=0;resp_error<=0;resp_data<=0;input_length<=1;output_length<=1;
   write_index<=0;read_index<=0;read_wait<=0;
  end else begin
   if(resp_valid&&resp_ready) resp_valid<=0;
   if(read_wait) begin read_wait<=0;resp_valid<=1; end
   if(accept) begin
    resp_valid<=1;resp_error<=0;resp_data<=0;
    if(!aligned) resp_error<=1;
    else if(req_write) begin
     if(active||req_strobe!=15) resp_error<=1;
     else case(req_addr)
      8'h00: if(req_data!=1) resp_error<=1;
      8'h04: if(req_data>65535) resp_error<=1;else input_length<=req_data[15:0];
      8'h08: if(req_data>65535) resp_error<=1;else output_length<=req_data[15:0];
      8'h0c: if(req_data>=DEPTH) resp_error<=1;else write_index<=req_data[AW-1:0];
      8'h10: begin end
      8'h14: if(req_data>=DEPTH) resp_error<=1;else begin
       read_index<=req_data[AW-1:0];read_wait<=1;resp_valid<=0;
      end
      default:resp_error<=1;
     endcase
    end else case(req_addr)
     8'h00:resp_data<={29'd0,error,done,active};
     8'h04:resp_data<=input_length;
     8'h08:resp_data<=output_length;
     8'h0c:resp_data<=write_index;
     8'h14:resp_data<=read_index;
     8'h18:if(active||read_index>=captured) resp_error<=1;else resp_data<=read_data;
     8'h1c:resp_data<=cycles;
     8'h20:resp_data<=issued;
     8'h24:resp_data<=captured;
     default:resp_error<=1;
    endcase
   end
  end
 end
endmodule
