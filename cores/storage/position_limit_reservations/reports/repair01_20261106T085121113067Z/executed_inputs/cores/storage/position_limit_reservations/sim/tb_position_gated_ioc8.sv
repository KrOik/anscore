`timescale 1ns/1ps
module tb_position_gated_ioc8;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,c_valid=0,r_ready=0,q_valid=0,qr_ready=0,i_valid=0,f_ready=0,d_ready=0;
 wire c_ready,r_valid,q_ready,qr_valid,i_ready,f_valid,d_valid,faulted;
 reg [2:0] c_op=0;reg [31:0] c_context=0,c_quantity=0;reg [63:0] c_ticket=0;reg c_buy=0;
 reg signed [63:0] c_position=0,c_min_position=0,c_max_position=0;reg [7:0] c_tag=8'hc3;
 wire [2:0] r_op;wire [3:0] r_status;wire [31:0] r_context,r_remaining;wire [63:0] r_ticket;wire r_buy;
 wire signed [63:0] r_position,r_min_position,r_max_position;wire [37:0] r_buy_open,r_sell_open;wire [31:0] r_live;wire [7:0] r_tag;
 reg [3:0] q_op=0;reg q_side=0;reg [31:0] q_price=0,q_quantity=0,q_rank=0;reg [7:0] q_tag=8'ha7;
 wire [3:0] qr_op;wire qr_side,qr_found;wire [2:0] qr_status;
 wire [31:0] qr_price,qr_quantity,qr_previous,qr_bid_levels,qr_ask_levels;wire [7:0] qr_tag;
 reg [31:0] i_context=0;reg [63:0] i_ticket=0;reg i_buy=0;reg [31:0] i_limit=0,i_quantity=0;reg [7:0] i_tag=0;
 wire f_buy;wire [31:0] f_price,f_quantity,f_remaining,f_index;wire [7:0] f_tag;
 wire [1:0] d_stage;wire [3:0] d_risk_status;wire [2:0] d_reason;
 wire [31:0] d_filled,d_remaining,d_fills,d_bid_levels,d_ask_levels,d_context;
 wire [63:0] d_ticket;wire signed [63:0] d_position;wire [37:0] d_buy_open,d_sell_open;wire [7:0] d_tag;
 position_gated_ioc8 dut(.*);
 wire [444:0] rp={r_op,r_status,r_context,r_ticket,r_buy,r_remaining,r_position,r_min_position,r_max_position,r_buy_open,r_sell_open,r_live,r_tag,faulted};
 wire [176:0] qp={qr_op,qr_side,qr_status,qr_found,qr_price,qr_quantity,qr_previous,qr_bid_levels,qr_ask_levels,qr_tag};
 wire [136:0] fp={f_buy,f_price,f_quantity,f_remaining,f_index,f_tag};
 wire [413:0] dp={d_stage,d_risk_status,d_reason,d_filled,d_remaining,d_fills,d_bid_levels,d_ask_levels,d_context,d_ticket,d_position,d_buy_open,d_sell_open,d_tag,faulted};
 wire [331:0] cs={c_op,c_context,c_ticket,c_buy,c_quantity,c_position,c_min_position,c_max_position,c_tag};
 wire [108:0] qs={q_op,q_side,q_price,q_quantity,q_rank,q_tag};
 wire [168:0] isrc={i_context,i_ticket,i_buy,i_limit,i_quantity,i_tag};
 reg [444:0] rh,exr;reg [176:0] qh,exq;reg [136:0] fh,exf;reg [413:0] dh,exd;
 reg [331:0] ch;reg [108:0] qsh;reg [168:0] ih;reg cb=0,qb=0,ib=0;
 reg [31:0] oc;reg [63:0] ot;reg ob;reg [7:0] o_tag;
 localparam signed [63:0] LO=64'h8000000000000000,HI=64'h7fffffffffffffff;
 localparam [63:0] MAX=64'hffffffffffffffff;
 integer cycles=0,admins=0,maintenance=0,orders=0,done_results=0,fills=0,holds=0,resets=0,blocked=0,cancelled=0,isolated=0;
 always @(negedge clk)begin cycles=cycles+1;if(cycles>300000)$fatal(1,"example watchdog");end
 always @(posedge clk)begin
  if(!rst_n)begin cb=0;qb=0;ib=0;end
  else begin
   if(cb&&(!c_valid||cs!==ch))$fatal(1,"admin source changed");
   if(qb&&(!q_valid||qs!==qsh))$fatal(1,"maintenance source changed");
   if(ib&&(!i_valid||isrc!==ih))$fatal(1,"IOC source changed");
   cb=c_valid&&!c_ready;qb=q_valid&&!q_ready;ib=i_valid&&!i_ready;ch=cs;qsh=qs;ih=isrc;
   if(cb)blocked=blocked+1;
  end
 end
 task reset_all;
  begin
   @(negedge clk);rst_n=0;c_valid=0;q_valid=0;i_valid=0;r_ready=0;qr_ready=0;f_ready=0;d_ready=0;
   #1;if(c_ready||q_ready||i_ready||r_valid||qr_valid||f_valid||d_valid)$fatal(1,"example reset mask");
   repeat(2)@(posedge clk);@(negedge clk);rst_n=1;resets=resets+1;
   @(posedge clk);if(faulted||dut.ledger.live!=0||dut.ledger.configured!=0)$fatal(1,"example reset epoch");
  end
 endtask
 task admin(input [2:0] op,input [31:0] ctx,input [63:0] tk,input side,input [31:0] qty,
            input signed [63:0] p,lo,hi,input [3:0] status,input signed [63:0] ep,
            input [37:0] bo,so,input [31:0] rem,live_count,input efault);
  reg [31:0] ec,er;reg [63:0] et;reg eb;reg signed [63:0] el,eu,pp;reg [37:0] bb,ss;
  begin
   if(!c_valid)begin
    @(negedge clk);c_valid=1;c_op=op;c_context=ctx;c_ticket=tk;c_buy=side;c_quantity=qty;c_position=p;c_min_position=lo;c_max_position=hi;
   end
   do @(posedge clk);while(!c_ready);@(negedge clk);c_valid=0;
   while(!r_valid)@(posedge clk);ec=0;er=0;et=0;eb=0;el=0;eu=0;pp=0;bb=0;ss=0;
   if(status==0&&op<6)begin
    ec=ctx;pp=ep;el=lo;eu=hi;bb=bo;ss=so;
    if(op!=0&&op!=4)begin et=tk;eb=side;er=rem;end
   end
   exr={op,status,ec,et,eb,er,pp,el,eu,bb,ss,live_count,8'hc3,efault};
   if(rp!==exr)$fatal(1,"admin %0d got%h expected%h",admins,rp,exr);
   rh=rp;repeat(3)begin @(posedge clk);if(!r_valid||rp!==rh||c_ready||q_ready||i_ready)$fatal(1,"admin held");holds=holds+1;end
   @(negedge clk);r_ready=1;@(posedge clk);@(negedge clk);r_ready=0;admins=admins+1;
  end
 endtask
 task quote(input [3:0] op,input side,input [31:0] price,qty,input [2:0] status,input found,input [31:0] resultprice,resultqty,previous,bids,asks);
  begin
   @(negedge clk);q_valid=1;q_op=op;q_side=side;q_price=price;q_quantity=qty;q_rank=0;
   do @(posedge clk);while(!q_ready);@(negedge clk);q_valid=0;
   while(!qr_valid)@(posedge clk);exq={op,side,status,found,resultprice,resultqty,previous,bids,asks,8'ha7};
   if(qp!==exq)$fatal(1,"maintenance %0d got%h expected%h",maintenance,qp,exq);
   qh=qp;repeat(3)begin @(posedge clk);if(!qr_valid||qp!==qh||c_ready||q_ready||i_ready)$fatal(1,"maintenance held");holds=holds+1;end
   @(negedge clk);qr_ready=1;@(posedge clk);@(negedge clk);qr_ready=0;maintenance=maintenance+1;
  end
 endtask
 task order(input [31:0] ctx,input [63:0] tk,input side,input [31:0] lim,qty);
  begin
   @(negedge clk);i_valid=1;i_context=ctx;i_ticket=tk;i_buy=side;i_limit=lim;i_quantity=qty;i_tag=orders;
   oc=ctx;ot=tk;ob=side;o_tag=orders;do @(posedge clk);while(!i_ready);
   @(negedge clk);i_valid=0;orders=orders+1;
  end
 endtask
 task fill(input [31:0] p,q,rem,index,input signed [63:0] oldp,input [37:0] bo,so,input [31:0] live_count,input pending_admin);
  begin
   while(!f_valid)begin @(posedge clk);if(d_valid)$fatal(1,"missing expected fill");end
   exf={ob,p,q,rem,index,o_tag};if(fp!==exf)$fatal(1,"fill got%h expected%h",fp,exf);fh=fp;
   if(pending_admin)begin
    @(negedge clk);c_valid=1;c_op=4;c_context=0;c_ticket=0;c_buy=0;c_quantity=0;c_position=0;c_min_position=-5;c_max_position=5;
   end
   repeat(4)begin
    @(posedge clk);
    if(!f_valid||fp!==fh||d_valid||dut.ledger.count!=live_count||
       dut.ledger.context_ram.mem[0][267:204]!==oldp||dut.ledger.context_ram.mem[0][75:38]!==bo||
       dut.ledger.context_ram.mem[0][37:0]!==so||c_ready||q_ready||i_ready)$fatal(1,"fill hold / premature accounting");holds=holds+1;
   end
   @(negedge clk);f_ready=1;@(posedge clk);@(negedge clk);f_ready=0;fills=fills+1;
  end
 endtask
 task done(input [1:0] stage,input [3:0] risk,input [2:0] reason,input [31:0] filled,rem,nfills,bids,asks,
           input signed [63:0] p,input [37:0] bo,so,input [31:0] live_count,input efault);
  begin
   while(!d_valid)begin @(posedge clk);if(f_valid)$fatal(1,"unexpected fill");end
   exd={stage,risk,reason,filled,rem,nfills,bids,asks,oc,ot,p,bo,so,o_tag,efault};
   if(dp!==exd)$fatal(1,"done order%0d got%h expected%h",orders,dp,exd);
   if(dut.ledger.count!=live_count)$fatal(1,"done ticket count");
   if(stage==0&&(dut.ledger.context_ram.mem[oc][267:204]!==p||dut.ledger.context_ram.mem[oc][75:38]!==bo||dut.ledger.context_ram.mem[oc][37:0]!==so))$fatal(1,"done before actual position update");
   dh=dp;repeat(4)begin @(posedge clk);if(!d_valid||dp!==dh||c_ready||q_ready||i_ready||f_valid)$fatal(1,"done held");holds=holds+1;end
   @(negedge clk);d_ready=1;@(posedge clk);@(negedge clk);d_ready=0;done_results=done_results+1;if(stage==2)isolated=isolated+1;
  end
 endtask
 initial begin
  reset_all();
  admin(0,0,0,0,0,0,-5,5,0,0,0,0,0,0,0);admin(0,1,0,0,0,0,-10,10,0,0,0,0,0,0,0);
  quote(0,1,10,3,0,0,10,3,0,0,1);quote(0,1,12,4,0,0,12,4,0,0,2);quote(0,0,9,5,0,0,9,5,0,1,2);
  admin(1,0,900,0,5,0,-5,5,0,0,0,5,5,1,0);
  order(0,10,1,12,6);done(1,5,0,0,6,0,0,0,0,0,0,1,0);
  order(0,10,1,12,5);fill(10,3,2,0,0,5,5,2,0);fill(12,2,0,1,0,5,5,2,1);done(0,0,0,5,0,2,1,1,5,0,5,1,0);
  admin(4,0,0,0,0,0,-5,5,0,5,0,5,0,1,0);
  // The preceding executed buy remains at +5 after its IOC reservation is gone.
  order(0,11,1,12,1);done(1,5,0,0,1,0,0,0,0,0,0,1,0);
  order(0,12,0,9,4);fill(9,4,0,0,5,0,9,2,0);done(0,0,0,4,0,1,1,1,1,0,5,1,0);
  order(0,13,0,10,1);done(0,0,2,0,1,0,1,1,1,0,5,1,0);
  admin(3,0,900,0,0,0,-5,5,0,1,0,0,0,0,0);
  order(0,14,1,12,4);fill(12,2,2,0,1,4,0,1,0);done(0,0,1,2,2,1,1,0,3,0,0,0,0);
  order(0,15,1,12,3);done(1,5,0,0,3,0,0,0,0,0,0,0,0);
  order(0,16,0,9,4);fill(9,1,3,0,3,0,4,1,0);done(0,0,1,1,3,1,0,0,2,0,0,0,0);
  order(0,17,0,9,1);done(0,0,1,0,1,0,0,0,2,0,0,0,0);
  order(0,18,1,12,0);done(1,3,0,0,0,0,0,0,0,0,0,0,0);
  order(32'h80000000,19,1,12,1);done(1,1,0,0,1,0,0,0,0,0,0,0,0);
  order(7,20,1,12,1);done(1,2,0,0,1,0,0,0,0,0,0,0,0);
  admin(1,1,777,1,1,0,-10,10,0,0,1,0,1,1,0);
  order(0,777,1,12,1);done(1,4,0,0,1,0,0,0,0,0,0,1,0);
  admin(3,1,777,1,0,0,-10,10,0,0,0,0,0,0,0);
  admin(0,0,0,0,0,LO+1,LO,HI,0,LO+1,0,0,0,0,0);
  order(0,21,0,0,2);done(1,5,0,0,2,0,0,0,0,0,0,0,0);
  quote(0,0,0,1,0,0,0,1,0,1,0);
  order(0,MAX,0,0,1);fill(0,1,0,0,LO+1,0,1,1,0);done(0,0,0,1,0,1,0,0,LO,0,0,0,0);
  order(0,22,0,0,1);done(1,5,0,0,1,0,0,0,0,0,0,0,0);
  reset_all();admin(0,0,0,0,0,0,-100,100,0,0,0,0,0,0,0);
  quote(0,1,10,1,0,0,10,1,0,0,1);quote(0,1,11,2,0,0,11,2,0,0,2);quote(0,0,9,2,0,0,9,2,0,1,2);
  order(0,30,1,11,3);fill(10,1,2,0,0,3,0,1,0);
  // Real matcher failure after an actual committed and retired fill.
  while(dut.matcher.state!=5)@(negedge clk);force dut.matcher.b_status=3'd7;
  while(!dut.matcher.b_valid)@(negedge clk);@(posedge clk);@(negedge clk);release dut.matcher.b_status;
  done(2,0,4,1,2,1,1,1,0,0,0,1,1);
  if(dut.ledger.context_ram.mem[0][267:204]!==64'd0||dut.ledger.context_ram.mem[0][75:38]!==38'd3)$fatal(1,"matcher fault released reservation");
  admin(4,0,0,0,0,0,-100,100,9,0,0,0,0,1,1);
  order(0,31,1,11,1);done(1,9,0,0,1,0,0,0,0,0,0,1,1);
  admin(6,0,0,0,0,0,0,0,0,0,0,0,0,0,0);admin(0,0,0,0,0,0,-100,100,0,0,0,0,0,0,0);
  order(0,32,0,9,2);fill(9,2,0,0,0,0,2,1,0);
  // Force a failed private FILL response after the genuine risk commit.
  // The wrapper must invalidate even though book and position already changed.
  while(dut.state!=8)@(negedge clk);force dut.lr_status=4'd12;
  while(!dut.lr_valid)@(negedge clk);@(posedge clk);@(negedge clk);release dut.lr_status;
  done(2,12,0,2,0,1,0,1,0,0,0,0,1);
  if(dut.ledger.context_ram.mem[0][267:204]!==-64'sd2)$fatal(1,"post-commit fault unexpectedly rolled back position");
  admin(6,0,0,0,0,0,0,0,0,0,0,0,0,0,0);admin(0,0,0,0,0,0,-100,100,0,0,0,0,0,0,0);
  order(0,33,1,11,1);while(!f_valid)@(posedge clk);cancelled=cancelled+1;reset_all();
  repeat(4)@(posedge clk);if(f_valid||d_valid||r_valid||qr_valid)$fatal(1,"canceled output survived");
  admin(4,0,0,0,0,0,0,0,2,0,0,0,0,0,0);quote(4,1,0,0,1,0,0,0,0,0,0);
  admin(0,0,0,0,0,0,-100,100,0,0,0,0,0,0,0);order(0,34,1,11,1);
  while(!d_valid)@(posedge clk);cancelled=cancelled+1;reset_all();admin(4,0,0,0,0,0,0,0,2,0,0,0,0,0,0);
  if(blocked<8)$fatal(1,"missing real future admin offer");
  $display("PASS position_gated_ioc8 admins=%0d maintenance=%0d orders=%0d done_results=%0d fills=%0d holds=%0d resets=%0d blocked=%0d cancelled=%0d isolated=%0d cycles=%0d",admins,maintenance,orders,done_results,fills,holds,resets,blocked,cancelled,isolated,cycles);$finish;
 end
endmodule
