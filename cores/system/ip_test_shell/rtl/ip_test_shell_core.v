// CSR-controlled runtime replay and synchronous full trace readback.
module generated_test_shell_core(
 input wire clk,rst_n,req_valid,req_write,input wire [7:0] req_addr,
 input wire [31:0] req_data,input wire [3:0] req_strobe,output wire req_ready,
 output wire resp_valid,output wire [31:0] resp_data,output wire resp_error,
 input wire resp_ready,output wire [7:0] probe,output wire [2:0] probe_page
);
 wire normal_valid,normal_error,normal_ready;
 wire [31:0] normal_data;
 reg ext_valid,ext_error;
 reg [31:0] ext_data;
 reg [8:0] trace_address;
 wire ext_select=req_addr>=8'h24;
 wire start,busy,done,error;
 wire [2:0] page;
 assign probe_page=page;
 wire [31:0] seed,mask,cycles,frames,byte_count,crc;
 wire [15:0] length;
 wire [9:0] trace_count;
 wire [35:0] trace_data;
 wire [7:0] stream_signals;
 assign req_ready=rst_n&&!ext_valid&&!normal_valid;
 assign resp_valid=ext_valid||normal_valid;
 assign resp_data=ext_valid?ext_data:normal_data;
 assign resp_error=ext_valid?ext_error:normal_error;
 test_shell_csr csr(.clk(clk),.rst_n(rst_n),
 .req_valid(req_valid&&req_ready&&!ext_select),.req_write(req_write),
 .req_addr(req_addr),.req_data(req_data),.req_strobe(req_strobe),.req_ready(normal_ready),
 .resp_valid(normal_valid),.resp_data(normal_data),.resp_error(normal_error),.resp_ready(resp_ready),
 .busy(busy),.done(done),.run_error(error),.frames(frames),.drops(32'd0),.cycles(cycles),
 .start(start),.probe_page(page),.seed(seed),.stall_mask(mask),.length(length));
 fabric_replay_runner runner(.clk(clk),.rst_n(rst_n),.start(start),.seed(seed),.stall_mask(mask),
 .length(length),.busy(busy),.done(done),.error(error),.cycles(cycles),.frames(frames),
 .bytes(byte_count),.crc32(crc),.trace_count(trace_count),.trace_read(!busy),
 .trace_address(trace_address),.trace_data(trace_data),.stream_probe(stream_signals));
 logic_probe8 probes(clk,rst_n,page,stream_signals,8'd0,8'd0,trace_data[7:0],probe);
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin ext_valid<=0; ext_data<=0; ext_error<=0; trace_address<=0; end
  else begin
   if(ext_valid&&resp_ready) ext_valid<=0;
   if(req_valid&&req_ready&&ext_select) begin
    ext_valid<=1; ext_data<=0; ext_error<=0;
    if(req_addr[1:0]!=0) ext_error<=1;
    else if(req_write) begin
     if(req_addr!=8'h24||busy||req_strobe!=15||req_data>511) ext_error<=1;
     else trace_address<=req_data[8:0];
    end else begin
     case(req_addr)
      8'h24: ext_data<={23'd0,trace_address};
      8'h28: if(busy||trace_address>=trace_count) ext_error<=1; else ext_data<=trace_data[31:0];
      8'h2c: if(busy||trace_address>=trace_count) ext_error<=1; else ext_data<={28'd0,trace_data[35:32]};
      8'h30: ext_data<={22'd0,trace_count};
      8'h34: ext_data<=crc;
      8'h38: ext_data<=byte_count;
      8'h3c: ext_data<=32'h00010000;
      default: ext_error<=1;
     endcase
    end
   end
  end
 end
endmodule

// One outstanding request; response selection is held until accepted.
// 0x00..0x3c retains the original generated-runner register contract.
// 0x40..0x64 is the independent host-loaded packet-fabric replay aperture.
module ip_test_shell_core(
 input wire clk,rst_n,req_valid,req_write,input wire [7:0] req_addr,
 input wire [31:0] req_data,input wire [3:0] req_strobe,output wire req_ready,
 output wire resp_valid,output wire [31:0] resp_data,output wire resp_error,
 input wire resp_ready,output wire [7:0] probe
);
 wire select_loaded=req_addr>=8'h40&&req_addr<=8'h67;
 reg pending,response_loaded;
 wire g_ready,l_ready,g_valid,l_valid,g_error,l_error;
 wire [31:0] g_data,l_data;
 wire [7:0] g_probe,l_probe;
 wire [2:0] probe_page;
 assign req_ready=rst_n&&!pending&&(select_loaded?l_ready:g_ready);
 assign resp_valid=pending&&(response_loaded?l_valid:g_valid);
 assign resp_data=response_loaded?l_data:g_data;
 assign resp_error=response_loaded?l_error:g_error;
 // Page 2 observes the loaded path; other pages retain their old meanings.
 assign probe=probe_page==2?l_probe:g_probe;
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin pending<=0;response_loaded<=0;end
  else begin
   if(resp_valid&&resp_ready) pending<=0;
   if(req_valid&&req_ready) begin pending<=1;response_loaded<=select_loaded;end
  end
 end
 generated_test_shell_core generated_core(clk,rst_n,
 req_valid&&req_ready&&!select_loaded,req_write,req_addr,req_data,req_strobe,
 g_ready,g_valid,g_data,g_error,resp_ready&&pending&&!response_loaded,g_probe,probe_page);
 loaded_fabric_replay loaded_core(clk,rst_n,
 req_valid&&req_ready&&select_loaded,req_write,req_addr-8'h40,req_data,req_strobe,
 l_ready,l_valid,l_error,l_data,resp_ready&&pending&&response_loaded,l_probe);
endmodule
