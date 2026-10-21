// Reuses the canonical byte-compaction serializer, then packs output words.
// user is packet-constant metadata. Empty TLAST is preserved as a boundary.
module stream_width_adapter #(parameter IN_WIDTH=32, OUT_WIDTH=24)(
 input wire clk,rst_n,
 input wire [IN_WIDTH-1:0] s_data,
 input wire [IN_WIDTH/8-1:0] s_keep,
 input wire [7:0] s_user,
 input wire s_last,s_valid,output wire s_ready,
 output wire [OUT_WIDTH-1:0] m_data,
 output wire [OUT_WIDTH/8-1:0] m_keep,
 output wire [7:0] m_user,
 output wire m_last,m_valid,input wire m_ready
);
 wire [31:0] byte_data;
 wire [3:0] byte_keep;
 wire [7:0] byte_user;
 wire byte_last,byte_valid,byte_ready;
 sys_width_converter #(.MODE(0)) serializer(
  .clk(clk),.rst_n(rst_n),
  .s_data({{(32-IN_WIDTH){1'b0}},s_data}),
  .s_keep({{(4-IN_WIDTH/8){1'b0}},s_keep}),
  .s_user(s_user),.s_last(s_last),.s_valid(s_valid),.s_ready(s_ready),
  .m_data(byte_data),.m_keep(byte_keep),.m_user(byte_user),
  .m_last(byte_last),.m_valid(byte_valid),.m_ready(byte_ready));
 localparam N=OUT_WIDTH/8;
 reg [OUT_WIDTH-1:0] partial,data;
 reg [N-1:0] keep;
 reg [2:0] filled;
 reg [7:0] first_user,user;
 reg valid,last;
 reg [OUT_WIDTH-1:0] assembled;
 reg [2:0] next_filled;
 always @* begin
  assembled=partial;
  next_filled=filled;
  if(byte_keep[0]) begin
   assembled[filled*8+:8]=byte_data[7:0];
   next_filled=filled+1'b1;
  end
 end
 assign byte_ready=rst_n&&(!valid||m_ready);
 assign m_data=data;
 assign m_keep=keep;
 assign m_user=user;
 assign m_last=last;
 assign m_valid=valid;
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   partial<=0; data<=0; keep<=0; filled<=0;
   first_user<=0; user<=0; valid<=0; last<=0;
  end else begin
   if(valid&&m_ready) valid<=0;
   if(byte_valid&&byte_ready) begin
    if(filled==0) first_user<=byte_user;
    if(next_filled==N||byte_last) begin
     data<=assembled; keep<=(5'b1<<next_filled)-1'b1;
     last<=byte_last; valid<=1;
     user<=(filled==0)?byte_user:first_user;
     partial<=0; filled<=0;
    end else begin partial<=assembled; filled<=next_filled; end
   end
  end
 end
 initial begin
  if(IN_WIDTH!=8&&IN_WIDTH!=16&&IN_WIDTH!=24&&IN_WIDTH!=32) $fatal(1,"IN_WIDTH");
  if(OUT_WIDTH!=8&&OUT_WIDTH!=16&&OUT_WIDTH!=24&&OUT_WIDTH!=32) $fatal(1,"OUT_WIDTH");
 end
endmodule
