// Four-phase bundled-data mailbox, one word in flight. Common reset is
// mandatory; independent domain reset/clock stopping recovery is not provided.
// Payload is registered one source beat BEFORE request assertion and held
// until acknowledgement completes. Physical CDC/MTBF/constraints remain TBD.
module cip_cdc_mailbox #(parameter WIDTH=32)(
    input wire rst_n,
    input wire src_clk, src_ce,
    input wire [WIDTH-1:0] s_data,
    input wire s_valid,
    output wire s_ready,
    input wire dst_clk, dst_ce,
    output reg [WIDTH-1:0] m_data,
    output reg m_valid,
    input wire m_ready
);
reg [WIDTH-1:0] payload;
reg [1:0] phase;
reg req, ack, waiting;
(* ASYNC_REG = "TRUE" *) reg ack_s1, ack_s2, req_s1, req_s2;
assign s_ready = rst_n && phase == 0 && !ack_s2;
always @(posedge src_clk or negedge rst_n) begin
    if (!rst_n) begin
        payload <= 0; phase <= 0; req <= 0; ack_s1 <= 0; ack_s2 <= 0;
    end else if (src_ce) begin
        ack_s1 <= ack; ack_s2 <= ack_s1;
        case (phase)
          0: if (s_valid && s_ready) begin payload <= s_data; phase <= 1; end
          1: begin req <= 1; phase <= 2; end
          2: if (ack_s2) begin req <= 0; phase <= 3; end
          3: if (!ack_s2) phase <= 0;
        endcase
    end
end
always @(posedge dst_clk or negedge rst_n) begin
    if (!rst_n) begin
        req_s1 <= 0; req_s2 <= 0; ack <= 0; waiting <= 0;
        m_valid <= 0; m_data <= 0;
    end else if (dst_ce) begin
        req_s1 <= req; req_s2 <= req_s1;
        if (!waiting && req_s2) begin
            m_data <= payload; m_valid <= 1; waiting <= 1;
        end
        if (m_valid && m_ready) begin m_valid <= 0; ack <= 1; end
        if (ack && !req_s2) begin ack <= 0; waiting <= 0; end
    end
end
initial if (WIDTH < 1) $fatal(1, "WIDTH must be positive");
endmodule
