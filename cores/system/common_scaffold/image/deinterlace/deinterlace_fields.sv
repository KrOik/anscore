// Paired temporally ordered fields -> one progressive raster.
module deinterlace_fields #(
 parameter integer WIDTH=16,HEIGHT=12,BITS=8
)(
 input wire clk,rst_n,ce,
 input wire [BITS-1:0] s_pixel,
 input wire s_parity,s_field_sof,s_eol,s_valid,
 output wire s_ready,
 input wire [1:0] cfg_mode,
 input wire cfg_first_parity,
 input wire [BITS-1:0] cfg_threshold,
 output reg [BITS-1:0] m_pixel,
 output reg m_bob_used,m_valid,m_sof,m_eol,
 input wire m_ready,
 output wire busy,
 output reg done,
 output reg [3:0] error_code
);
 localparam [63:0] N64=64'(WIDTH)*64'(HEIGHT);
 localparam integer N=(N64>=1 && N64<=65536)?N64:1;
 localparam integer AW=(N<=1)?1:$clog2(N);
 initial if(WIDTH<1 || HEIGHT<1 || WIDTH>4096 || HEIGHT>4096 || N64>65536 || BITS<8 || BITS>12)
  $fatal(1,"invalid deinterlace parameters");
 localparam CAP=0,PIX=1,OREAD=2,OSAVE=3,UPREAD=4,UPSAVE=5,DNREAD=6,DNSAVE=7,MAP=8,HOLD=9;
 reg [3:0] state;
 reg [BITS-1:0] frame[0:N-1],pixel_q,original,upper,lower;
 reg [AW-1:0] rd_addr;
 reg [11:0] cap_x,cap_y,x,y;
 reg active,phase,first_q,newer_q;
 reg [1:0] mode_q;
 reg [BITS-1:0] threshold_q;
 wire first_effective=(HEIGHT==1)?1'b0:cfg_first_parity;
 wire expected_parity=active ? (phase ? !first_q:first_q) : first_effective;
 wire [12:0] row=active?{1'b0,cap_y}:{12'd0,first_effective};
 wire expected_sof=(cap_x==0 && (!active || row=={12'd0,expected_parity}));
 wire marker_ok=(s_parity==expected_parity && s_field_sof==expected_sof && s_eol==(cap_x==WIDTH-1));
 wire [31:0] write_addr=row*WIDTH+cap_x;
 wire [12:0] up_y=(y==0)?13'd1:({1'b0,y}-1'b1);
 wire [12:0] dn_y=(y==HEIGHT-1)?({1'b0,y}-1'b1):({1'b0,y}+1'b1);
 wire [BITS:0] sum={1'b0,upper}+{1'b0,lower}+1'b1;
 wire [BITS-1:0] bob=sum[BITS:1];
 wire [BITS-1:0] difference=(original>bob)?original-bob:bob-original;
 wire choose_bob=(mode_q==1 || (mode_q==2 && difference>threshold_q));
 assign s_ready=state==CAP;
 assign busy=active || state!=CAP;
 always @(posedge clk)if(ce && rst_n)begin
  if(state==CAP && s_valid && marker_ok && (active || cfg_mode!=3))frame[write_addr[AW-1:0]]<=s_pixel;
  if(state==OREAD || state==UPREAD || state==DNREAD)pixel_q<=frame[rd_addr];
 end
 always @(posedge clk)begin
  if(!rst_n)begin
   state<=CAP;cap_x<=0;cap_y<=0;x<=0;y<=0;active<=0;phase<=0;first_q<=0;newer_q<=0;
   mode_q<=0;threshold_q<=0;rd_addr<=0;original<=0;upper<=0;lower<=0;
   m_pixel<=0;m_bob_used<=0;m_valid<=0;m_sof<=0;m_eol<=0;done<=0;error_code<=0;
  end else if(ce)begin
   done<=0;
   case(state)
    CAP:if(s_valid)begin
     if((!active && cfg_mode==3) || !marker_ok)begin
      error_code<=(!active && cfg_mode==3)?2:1;done<=1;active<=0;phase<=0;cap_x<=0;cap_y<=0;
     end else begin
      if(!active)begin
       mode_q<=cfg_mode;first_q<=first_effective;newer_q<=(HEIGHT==1)?1'b0:!first_effective;
       threshold_q<=cfg_threshold;active<=1;error_code<=0;
      end
      if(cap_x==WIDTH-1)begin
       cap_x<=0;
       if(row+2>=HEIGHT)begin
        if(phase || HEIGHT==1)begin x<=0;y<=0;state<=PIX;end
        else begin phase<=1;cap_y<=!expected_parity;end
       end else cap_y<=row+2;
      end else begin cap_x<=cap_x+1'b1;cap_y<=row[11:0];end
     end
    end
    PIX:begin rd_addr<=y*WIDTH+x;m_sof<=(x==0 && y==0);m_eol<=(x==WIDTH-1);m_bob_used<=0;state<=OREAD;end
    OREAD:state<=OSAVE;
    OSAVE:begin
     original<=pixel_q;
     if(mode_q==0 || y[0]==newer_q || HEIGHT==1)begin m_pixel<=pixel_q;m_valid<=1;state<=HOLD;end
     else begin rd_addr<=up_y*WIDTH+x;state<=UPREAD;end
    end
    UPREAD:state<=UPSAVE;
    UPSAVE:begin upper<=pixel_q;rd_addr<=dn_y*WIDTH+x;state<=DNREAD;end
    DNREAD:state<=DNSAVE;
    DNSAVE:begin lower<=pixel_q;state<=MAP;end
    MAP:begin m_pixel<=choose_bob?bob:original;m_bob_used<=choose_bob;m_valid<=1;state<=HOLD;end
    HOLD:if(m_ready)begin
     m_valid<=0;
     if(x==WIDTH-1 && y==HEIGHT-1)begin active<=0;phase<=0;cap_x<=0;cap_y<=0;x<=0;y<=0;done<=1;state<=CAP;end
     else begin if(x==WIDTH-1)begin x<=0;y<=y+1'b1;end else x<=x+1'b1;state<=PIX;end
    end
    default:begin state<=CAP;active<=0;phase<=0;cap_x<=0;cap_y<=0;m_valid<=0;error_code<=3;done<=1;end
   endcase
  end
 end
endmodule
