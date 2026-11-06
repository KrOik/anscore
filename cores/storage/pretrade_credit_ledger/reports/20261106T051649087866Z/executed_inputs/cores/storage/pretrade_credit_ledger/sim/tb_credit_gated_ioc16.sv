`timescale 1ns/1ps
module tb_credit_gated_ioc16;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,c_valid=0,r_ready=0,q_valid=0,qr_ready=0,i_valid=0,f_ready=0,d_ready=0;
 wire c_ready,r_valid,q_ready,qr_valid,i_ready,f_valid,d_valid,faulted;
 reg [2:0] c_op=0;reg [15:0] c_account=0;reg [63:0] c_ticket=0,c_amount=0,c_limit=0;reg [7:0] c_tag=8'hc3;
 wire [2:0] r_op;wire [3:0] r_status;wire [15:0] r_account;
 wire [63:0] r_ticket,r_amount,r_limit,r_used,r_available;wire [31:0] r_live;wire [7:0] r_tag;
 reg [3:0] q_op=0;reg q_side=0;reg [31:0] q_price=0,q_quantity=0,q_rank=0;reg [7:0] q_tag=8'ha7;
 wire [3:0] qr_op;wire qr_side,qr_found;wire [2:0] qr_status;
 wire [31:0] qr_price,qr_quantity,qr_previous,qr_bid_levels,qr_ask_levels;wire [7:0] qr_tag;
 reg [15:0] i_account=0;reg [63:0] i_ticket=0;reg [31:0] i_limit=0,i_quantity=0;reg [7:0] i_tag=0;
 wire f_buy;wire [31:0] f_price,f_quantity,f_remaining,f_index;wire [7:0] f_tag;
 wire [1:0] d_stage;wire [3:0] d_credit_status;wire [2:0] d_reason;
 wire [31:0] d_filled,d_remaining,d_fills,d_bid_levels,d_ask_levels;
 wire [15:0] d_account;wire [63:0] d_ticket,d_used;wire [7:0] d_tag;
 credit_gated_ioc16 dut(.*);
 wire [383:0] rp={r_op,r_status,r_account,r_ticket,r_amount,r_limit,r_used,r_available,r_live,r_tag,faulted};
 wire [176:0] qp={qr_op,qr_side,qr_status,qr_found,qr_price,qr_quantity,qr_previous,qr_bid_levels,qr_ask_levels,qr_tag};
 wire [136:0] fp={f_buy,f_price,f_quantity,f_remaining,f_index,f_tag};
 wire [321:0] dp={d_stage,d_credit_status,d_reason,d_filled,d_remaining,d_fills,d_bid_levels,d_ask_levels,d_account,d_ticket,d_used,d_tag,faulted};
 wire [218:0] cs={c_op,c_account,c_ticket,c_amount,c_limit,c_tag};
 wire [108:0] qs={q_op,q_side,q_price,q_quantity,q_rank,q_tag};
 wire [151:0] isrc={i_account,i_ticket,i_limit,i_quantity,i_tag};
 reg [383:0] rh,exr;reg [176:0] qh,exq;reg [136:0] fh,exf;reg [321:0] dh,exd;
 reg [218:0] ch;reg [108:0] qsh;reg [151:0] ih;reg cb=0,qb=0,ib=0;
 reg [15:0] oa;reg [63:0] ot;reg [7:0] o_tag;
 localparam [63:0] MAX=64'hffffffffffffffff, BIG=64'hfffffffe00000001;
 integer cycles=0,admins=0,maintenance=0,orders=0,fills=0,holds=0,resets=0,blocked=0;
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
 task admin(input [2:0] op,input [15:0] aa,input [63:0] tk,am,lim,input [3:0] status,input [63:0] used,input [31:0] live_count,input efault);
  reg [15:0] ea;reg [63:0] et,em,el,eu,ev;
  begin
   if(!c_valid)begin @(negedge clk);c_valid=1;c_op=op;c_account=aa;c_ticket=tk;c_amount=am;c_limit=lim;end
   do @(posedge clk);while(!c_ready);@(negedge clk);c_valid=0;
   while(!r_valid)@(posedge clk);
   ea=0;et=0;em=0;el=0;eu=0;ev=0;
   if(status==0 && (op==0||op==3))begin ea=aa;el=lim;eu=used;ev=lim-used;end
   else if(status==0 && (op==1||op==2||op==4))begin ea=aa;et=tk;em=am;el=lim;eu=used;ev=lim-used;end
   exr={op,status,ea,et,em,el,eu,ev,live_count,8'hc3,efault};
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
 task order(input [15:0] aa,input [63:0] tk,input [31:0] lim,qty);
  begin
   @(negedge clk);i_valid=1;i_account=aa;i_ticket=tk;i_limit=lim;i_quantity=qty;i_tag=orders;
   oa=aa;ot=tk;o_tag=orders;do @(posedge clk);while(!i_ready);
   @(negedge clk);i_valid=0;orders=orders+1;
  end
 endtask
 task fill(input [31:0] p,q,remaining,index,input [63:0] hold_amount,input pending_admin);
  begin
   while(!f_valid)begin @(posedge clk);if(d_valid)$fatal(1,"missing expected fill");end
   exf={1'b1,p,q,remaining,index,o_tag};if(fp!==exf)$fatal(1,"fill got%h expected%h",fp,exf);
   fh=fp;
   if(pending_admin)begin
    @(negedge clk);c_valid=1;c_op=3;c_account=0;c_ticket=0;c_amount=0;c_limit=1000;
   end
   repeat(4)begin
    @(posedge clk);if(!f_valid||fp!==fh||d_valid||dut.ledger.count!=1||dut.ledger.account_ram.mem[0][63:0]!==hold_amount||c_ready||q_ready||i_ready)$fatal(1,"fill hold / premature release");holds=holds+1;
   end
   @(negedge clk);f_ready=1;@(posedge clk);@(negedge clk);f_ready=0;fills=fills+1;
  end
 endtask
 task done(input [1:0] stage,input [3:0] credit,input [2:0] reason,input [31:0] filled,remaining,nfills,bids,asks,input [63:0] used,input efault);
  begin
   while(!d_valid)begin @(posedge clk);if(f_valid)$fatal(1,"unexpected fill");end
   exd={stage,credit,reason,filled,remaining,nfills,bids,asks,oa,ot,used,o_tag,efault};
   if(dp!==exd)$fatal(1,"done order%0d got%h expected%h",orders,dp,exd);
   if(stage==0 && (dut.ledger.count!=0 || dut.ledger.account_ram.mem[0][63:0]!=0))$fatal(1,"normal completion before release");
   dh=dp;repeat(4)begin @(posedge clk);if(!d_valid||dp!==dh||c_ready||q_ready||i_ready||f_valid)$fatal(1,"done held");holds=holds+1;end
   @(negedge clk);d_ready=1;@(posedge clk);@(negedge clk);d_ready=0;
  end
 endtask
 initial begin
  reset_all();admin(0,0,0,0,1000,0,0,0,0);
  quote(0,1,10,3,0,0,10,3,0,0,1);quote(0,1,12,4,0,0,12,4,0,0,2);quote(0,0,9,5,0,0,9,5,0,1,2);
  admin(1,0,224,900,1000,0,900,1,0);
  order(0,10,12,10);done(1,5,0,0,10,0,0,0,0,0);
  if(dut.ledger.account_ram.mem[0][63:0]!=900)$fatal(1,"credit rejection changed hold");
  quote(4,1,0,0,0,1,10,3,0,1,2);admin(2,0,224,900,1000,0,0,0,0);
  order(0,10,12,5);fill(10,3,2,0,60,0);fill(12,2,0,1,60,1);done(0,0,0,5,0,2,1,1,0,0);
  admin(3,0,0,0,1000,0,0,0,0);
  order(0,MAX,11,4);done(0,0,2,0,4,0,1,1,0,0);
  quote(4,1,0,0,0,1,12,2,0,1,1);
  order(0,1,12,4);fill(12,2,2,0,48,0);done(0,0,1,2,2,1,1,0,0,0);
  order(0,2,12,0);done(1,3,0,0,0,0,0,0,0,0);
  order(0,2,0,5);done(1,3,0,0,5,0,0,0,0,0);
  admin(0,0,0,0,MAX,0,0,0,0);quote(7,0,0,0,0,0,0,0,0,0,0);
  quote(0,1,32'hffffffff,32'hffffffff,0,0,32'hffffffff,32'hffffffff,0,0,1);
  order(0,MAX,32'hffffffff,32'hffffffff);fill(32'hffffffff,32'hffffffff,0,0,BIG,0);done(0,0,0,32'hffffffff,0,1,0,0,0,0);
  admin(1,0,77,5,MAX,0,5,1,0);order(0,77,1,1);done(1,4,0,0,1,0,0,0,0,0);admin(2,0,77,5,MAX,0,0,0,0);
  order(16'h8000,99,1,1);done(1,1,0,0,1,0,0,0,0,0);
  order(15,99,1,1);done(1,2,0,0,1,0,0,0,0,0);
  admin(0,0,0,0,0,0,0,0,0);order(0,99,1,1);done(1,5,0,0,1,0,0,0,0,0);admin(0,0,0,0,MAX,0,0,0,0);
  quote(0,1,10,1,0,0,10,1,0,0,1);quote(0,1,11,2,0,0,11,2,0,0,2);
  order(0,240,11,3);fill(10,1,2,0,33,0);
  // Inject an unexpected backend status at the real matcher BEST response,
  // after one actual committed/retired fill. No ordinary result is fabricated.
  while(dut.matcher.state!=5)@(negedge clk);
  force dut.matcher.b_status=3'd7;
  while(!dut.matcher.b_valid)@(negedge clk);@(posedge clk);@(negedge clk);release dut.matcher.b_status;
  done(2,0,4,1,2,1,0,1,0,1);
  if(dut.ledger.count!=1 || dut.ledger.account_ram.mem[0][63:0]!=33)$fatal(1,"fault released conservative hold");
  admin(3,0,0,0,MAX,9,0,1,1);order(0,241,11,1);done(1,9,0,0,1,0,0,0,0,1);
  admin(5,0,0,0,0,0,0,0,0);admin(0,0,0,0,100,0,0,0,0);
  quote(4,1,0,0,0,1,11,2,0,0,1);order(0,242,11,2);fill(11,2,0,0,22,0);done(0,0,0,2,0,1,0,0,0,0);
  quote(0,1,11,1,0,0,11,1,0,0,1);order(0,243,11,1);
  while(!f_valid)@(posedge clk);
  if(dut.ledger.account_ram.mem[0][63:0]!=11)$fatal(1,"reset fill hold");
  reset_all();repeat(4)@(posedge clk);if(f_valid||d_valid||r_valid||qr_valid)$fatal(1,"canceled output survived");
  admin(3,0,0,0,0,2,0,0,0);quote(4,1,0,0,1,0,0,0,0,0,0);
  admin(0,0,0,0,100,0,0,0,0);order(0,244,11,1);
  while(!d_valid)@(posedge clk);reset_all();admin(3,0,0,0,0,2,0,0,0);
  if(blocked<8)$fatal(1,"missing real future admin offer");
  $display("PASS credit_gated_ioc16 admins=%0d maintenance=%0d orders=%0d fills=%0d holds=%0d resets=%0d blocked=%0d cycles=%0d",admins,maintenance,orders,fills,holds,resets,blocked,cycles);$finish;
 end
endmodule
