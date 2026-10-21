// Discrete gradient-domain reconstruction, raster Gauss-Seidel, signed Q8.
module poisson_blend_frame #(parameter WIDTH=7,HEIGHT=5)(
 input clk,rst_n,ce,input start_valid,output start_ready,
 input [7:0] cfg_max_iterations,input [23:0] cfg_tolerance,input cfg_mixed,
 input [7:0] s_source,s_target,input s_mask,s_valid,s_sof,s_eol,output s_ready,
 output reg [7:0] m_gray,output reg m_valid,input m_ready,
 output reg m_sof,m_eol,m_last,
 output reg [7:0] iterations,output reg converged,output reg [23:0] residual,
 output done_valid,input done_ready,output reg done_error,output reg [3:0] error_code,
 output busy
);
 localparam N=WIDTH*HEIGHT;
 localparam IDLE=0,CAP=1,READ=2,CENTER=3,NEIGHBOR_READ=4,NEIGHBOR=5,
 UPDATE=6,ADVANCE=7,SWEEP_END=8,OUT_READ=9,OUT_LOAD=10,OUT=11,DONE=12;
 reg [3:0] state;
 reg [16:0] frame_mem[0:N-1];reg signed [27:0] solution_mem[0:N-1];
 reg [16:0] meta_q;reg signed [27:0] sol_q;
 reg [10:0] addr,pos,x,y;
 reg [1:0] direction;
 reg [7:0] source_center,target_center,maxiter;
 reg signed [27:0] value_center;
 reg [23:0] tolerance;reg [31:0] max_residual;
 reg mixed,residual_pass;
 reg signed [31:0] neighbor_sum,rhs;
 wire active_center=meta_q[16]&&x!=0&&x!=WIDTH-1&&y!=0&&y!=HEIGHT-1;
 wire signed [9:0] source_gradient=$signed({1'b0,source_center})-$signed({1'b0,meta_q[15:8]});
 wire signed [9:0] target_gradient=$signed({1'b0,target_center})-$signed({1'b0,meta_q[7:0]});
 wire [9:0] source_abs=source_gradient<0?-source_gradient:source_gradient;
 wire [9:0] target_abs=target_gradient<0?-target_gradient:target_gradient;
 wire signed [9:0] gradient=(mixed&&target_abs>source_abs)?target_gradient:source_gradient;
 wire signed [31:0] gradient_q8={{14{gradient[9]}},gradient,8'b0};
 wire signed [31:0] extended_neighbor={{4{sol_q[27]}},sol_q};
 wire signed [31:0] equation_error=($signed({{4{value_center[27]}},value_center})<<<2)-neighbor_sum-rhs;
 wire [31:0] error_abs=equation_error<0?-equation_error:equation_error;
 wire signed [31:0] updated=(neighbor_sum+rhs)>>>2;
 wire signed [28:0] rounded=($signed({sol_q[27],sol_q})+29'sd128)>>>8;
 assign start_ready=ce&&(state==IDLE);
 assign s_ready=ce&&(state==CAP);
 assign done_valid=state==DONE;
 assign busy=state!=IDLE;
 // One synchronous read address per memory. Capture completely overwrites RAM.
 always @(posedge clk)if(ce)begin meta_q<=frame_mem[addr];sol_q<=solution_mem[addr];end
 always @(posedge clk)begin
 if(!rst_n)begin state<=IDLE;addr<=0;m_valid<=0;m_gray<=0;m_sof<=0;m_eol<=0;m_last<=0;
 iterations<=0;converged<=0;residual<=0;done_error<=0;error_code<=0;end
 else if(ce)case(state)
 IDLE:if(start_valid)begin
 done_error<=0;error_code<=0;
 if(cfg_max_iterations==0||N<1||N>1024||WIDTH<1||WIDTH>1024||HEIGHT<1||HEIGHT>1024)begin
 done_error<=1;error_code<=1;state<=DONE;
 end else begin maxiter<=cfg_max_iterations;tolerance<=cfg_tolerance;mixed<=cfg_mixed;
 iterations<=0;converged<=0;residual<=0;pos<=0;x<=0;y<=0;state<=CAP;end end
 CAP:if(s_valid)begin
 frame_mem[pos]<={s_mask,s_source,s_target};solution_mem[pos]<={12'b0,s_target,8'b0};
 if(s_sof!=(pos==0)||s_eol!=(x==WIDTH-1))begin done_error<=1;error_code<=2;end
 if(pos==N-1)begin pos<=0;x<=0;y<=0;addr<=0;residual_pass<=0;state<=READ;end
 else begin pos<=pos+1;if(x==WIDTH-1)begin x<=0;y<=y+1;end else x<=x+1;end end
 READ:state<=CENTER;
 CENTER:if(active_center)begin
 source_center<=meta_q[15:8];target_center<=meta_q[7:0];value_center<=sol_q;
 neighbor_sum<=0;rhs<=0;direction<=0;addr<=pos-1;state<=NEIGHBOR_READ;
 end else state<=ADVANCE;
 NEIGHBOR_READ:state<=NEIGHBOR;
 NEIGHBOR:begin neighbor_sum<=neighbor_sum+extended_neighbor;rhs<=rhs+gradient_q8;
 if(direction==3)state<=UPDATE;
 else begin direction<=direction+1;
 case(direction)0:addr<=pos+1;1:addr<=pos-WIDTH;2:addr<=pos+WIDTH;endcase
 state<=NEIGHBOR_READ;end end
 UPDATE:begin
 if(residual_pass)begin if(error_abs>max_residual)max_residual<=error_abs;end
 else solution_mem[pos]<=updated[27:0];
 state<=ADVANCE;end
 ADVANCE:if(pos==N-1)state<=SWEEP_END;
 else begin pos<=pos+1;addr<=pos+1;if(x==WIDTH-1)begin x<=0;y<=y+1;end else x<=x+1;state<=READ;end
 SWEEP_END:begin
 pos<=0;x<=0;y<=0;addr<=0;
 if(!residual_pass)begin residual_pass<=1;max_residual<=0;state<=READ;end
 else begin iterations<=iterations+1;residual<=|max_residual[31:24]?24'hffffff:max_residual[23:0];
 if(max_residual<=tolerance||iterations+1==maxiter)begin converged<=max_residual<=tolerance;state<=OUT_READ;end
 else begin residual_pass<=0;state<=READ;end end end
 OUT_READ:state<=OUT_LOAD;
 OUT_LOAD:begin m_gray<=rounded<0?8'd0:rounded>255?8'd255:rounded[7:0];m_valid<=1;
 m_sof<=pos==0;m_eol<=x==WIDTH-1;m_last<=pos==N-1;state<=OUT;end
 OUT:if(m_ready)begin m_valid<=0;
 if(pos==N-1)state<=DONE;
 else begin pos<=pos+1;addr<=pos+1;if(x==WIDTH-1)x<=0;else x<=x+1;state<=OUT_READ;end end
 DONE:if(done_ready)state<=IDLE;
 default:state<=IDLE;
 endcase end
endmodule
