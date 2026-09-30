module rsa_udp_min_endpoint #(
    parameter [47:0] LOCAL_MAC = 48'h0600AABB0CDD,
    parameter [31:0] LOCAL_IP = {8'd192, 8'd168, 8'd137, 8'd15}
) (
    input clk1m,
    input rst_n,

    input netrmii_clk50m,
    input netrmii_rx_crs,
    input [1:0] netrmii_rxd,
    output netrmii_mdc,
    output netrmii_txen,
    inout netrmii_mdio,
    output [1:0] netrmii_txd,
    output phyrst,

    output clk50m,
    output ready,
    output reg service_busy,
    output rsa_busy,
    output reg last_ok,
    output reg last_error,
    output reg debug_frame,
    output reg debug_ip,
    output reg debug_udp_proto,
    output reg debug_payload_start,
    output reg debug_arp,
    output reg debug_udp,
    output reg debug_rsa_ok,
    output reg debug_rsa_error,
    output reg debug_tx_udp,
    output [7:0] resp_status,
    output [15:0] resp_cycles,
    output [255:0] resp_ciphertext
);

    localparam [15:0] REQ_LEN = 16'd37;
    localparam [15:0] RESP_LEN = 16'd40;
    localparam [15:0] UDP_SRC_PORT = 16'd11451;
    localparam [15:0] UDP_RESP_LEN = 16'd48;
    localparam [15:0] IP_RESP_LEN = 16'd68;
    localparam [15:0] ETH_UDP_LEN = 16'd86;
    localparam [15:0] ETH_ARP_LEN = 16'd42;

    localparam [7:0] STATUS_OK = 8'd0;
    localparam [7:0] STATUS_BAD_MAGIC = 8'd1;
    localparam [7:0] STATUS_BAD_LEN = 8'd2;
    localparam [7:0] STATUS_RANGE = 8'd3;
    localparam [7:0] STATUS_BAD_OP = 8'd4;

    assign clk50m = netrmii_clk50m;
    assign netrmii_mdc = clk1m;

    reg phy_rdy;
    reg rphyrst;
    reg SMI_trg;
    wire SMI_ack;
    wire SMI_ready;
    reg SMI_rw;
    reg [4:0] SMI_adr;
    wire [15:0] SMI_data;
    reg [15:0] SMI_wdata;
    reg [7:0] SMI_status;

    assign ready = phy_rdy;
    assign phyrst = rphyrst;

    always_ff @(posedge clk1m or negedge rst_n) begin
        if (!rst_n) begin
            phy_rdy <= 1'b0;
            rphyrst <= 1'b0;
            SMI_trg <= 1'b0;
            SMI_adr <= 5'd1;
            SMI_rw <= 1'b1;
            SMI_wdata <= 16'd0;
            SMI_status <= 8'd0;
        end else begin
            rphyrst <= 1'b1;
            if (!phy_rdy) begin
                SMI_trg <= 1'b1;
                if (SMI_ack && SMI_ready) begin
                    case (SMI_status)
                        8'd0: begin
                            SMI_adr <= 5'd31;
                            SMI_wdata <= 16'h0007;
                            SMI_rw <= 1'b0;
                            SMI_status <= 8'd1;
                        end
                        8'd1: begin
                            SMI_adr <= 5'd16;
                            SMI_wdata <= 16'h0FFE;
                            SMI_status <= 8'd2;
                        end
                        8'd2: begin
                            SMI_rw <= 1'b1;
                            SMI_status <= 8'd3;
                        end
                        8'd3: begin
                            SMI_adr <= 5'd31;
                            SMI_wdata <= 16'h0000;
                            SMI_rw <= 1'b0;
                            SMI_status <= 8'd4;
                        end
                        8'd4: begin
                            SMI_adr <= 5'd1;
                            SMI_rw <= 1'b1;
                            SMI_status <= 8'd5;
                        end
                        default: begin
                            if (SMI_data[2]) begin
                                phy_rdy <= 1'b1;
                                SMI_trg <= 1'b0;
                            end
                        end
                    endcase
                end
            end
        end
    end

    SMI_ct smi_inst (
        .clk(clk1m),
        .rst(rphyrst),
        .rw(SMI_rw),
        .trg(SMI_trg),
        .phy_adr(5'd1),
        .reg_adr(SMI_adr),
        .data(SMI_wdata),
        .ready(SMI_ready),
        .ack(SMI_ack),
        .smi_data(SMI_data),
        .mdio(netrmii_mdio)
    );

    reg tx_en;
    reg [7:0] tx_byte;
    wire tx_av;
    wire tx_bz;

    tx_ct tx_inst (
        .clk(clk50m),
        .rst(phy_rdy),
        .data(tx_byte),
        .tx_en(tx_en),
        .tx_av(tx_av),
        .tx_bz(tx_bz),
        .p_txd(netrmii_txd),
        .p_txen(netrmii_txen)
    );

    reg [1:0] rx_tick;
    reg [7:0] rx_shift;
    reg rx_active;
    reg rx_byte_valid;
    reg rx_end;
    reg [7:0] rx_byte;

    always_ff @(posedge clk50m or negedge phy_rdy) begin
        if (!phy_rdy) begin
            rx_tick <= 2'd0;
            rx_shift <= 8'd0;
            rx_active <= 1'b0;
            rx_byte_valid <= 1'b0;
            rx_end <= 1'b0;
            rx_byte <= 8'd0;
        end else begin
            rx_byte_valid <= 1'b0;
            rx_end <= 1'b0;
            if (netrmii_rx_crs) begin
                rx_active <= 1'b1;
                rx_shift <= {netrmii_rxd, rx_shift[7:2]};
                if (rx_tick == 2'd3) begin
                    rx_byte <= {netrmii_rxd, rx_shift[7:2]};
                    rx_byte_valid <= 1'b1;
                    rx_tick <= 2'd0;
                end else begin
                    rx_tick <= rx_tick + 2'd1;
                end
            end else begin
                if (rx_active) begin
                    rx_end <= 1'b1;
                end
                rx_active <= 1'b0;
                rx_tick <= 2'd0;
                rx_shift <= 8'd0;
            end
        end
    end

    reg in_frame;
    reg [3:0] preamble_count;
    reg [10:0] frame_idx;
    reg dest_local;
    reg dest_broadcast;
    reg [47:0] rx_src_mac_shift;
    reg [47:0] peer_mac;
    reg [31:0] peer_ip;
    reg [15:0] peer_port;
    reg [15:0] eth_type;
    reg [15:0] arp_oper;
    reg [31:0] arp_spa;
    reg [31:0] arp_tpa;
    reg [7:0] ip_proto;
    reg [31:0] ip_src;
    reg [31:0] ip_dst;
    reg [15:0] udp_src_port;
    reg [15:0] udp_dst_port;
    reg [15:0] udp_len;
    reg [15:0] payload_idx;
    reg [7:0] req_status;
    reg [255:0] req_message;
    reg pending_arp;
    reg pending_rsa_start;
    reg clear_pending_arp;
    reg clear_pending_udp;
    reg [15:0] ip_id;

    reg rsa_start;
    wire rsa_done;
    wire rsa_error;
    wire [15:0] rsa_cycles_wire;
    wire [255:0] rsa_ciphertext;
    reg [7:0] response_status;
    reg [15:0] response_cycles;
    reg [255:0] response_ciphertext;
    reg [47:0] response_mac;
    reg [31:0] response_ip;
    reg [15:0] response_port;
    reg pending_udp;

    assign resp_status = response_status;
    assign resp_cycles = response_cycles;
    assign resp_ciphertext = response_ciphertext;

    rsa_modexp rsa_inst (
        .clk(clk50m),
        .rst_n(phy_rdy),
        .start(rsa_start),
        .message(req_message),
        .busy(rsa_busy),
        .done(rsa_done),
        .error(rsa_error),
        .cycles(rsa_cycles_wire),
        .ciphertext(rsa_ciphertext)
    );

    function automatic [7:0] local_mac_byte(input [2:0] idx);
        begin
            local_mac_byte = LOCAL_MAC[(5 - idx) * 8 +: 8];
        end
    endfunction

    function automatic [7:0] peer_mac_byte(input [2:0] idx);
        begin
            peer_mac_byte = peer_mac[(5 - idx) * 8 +: 8];
        end
    endfunction

    function automatic [7:0] response_mac_byte(input [2:0] idx);
        begin
            response_mac_byte = response_mac[(5 - idx) * 8 +: 8];
        end
    endfunction

    function automatic [7:0] local_ip_byte(input [1:0] idx);
        begin
            local_ip_byte = LOCAL_IP[(3 - idx) * 8 +: 8];
        end
    endfunction

    function automatic [7:0] peer_ip_byte(input [1:0] idx);
        begin
            peer_ip_byte = peer_ip[(3 - idx) * 8 +: 8];
        end
    endfunction

    function automatic [7:0] response_ip_byte(input [1:0] idx);
        begin
            response_ip_byte = response_ip[(3 - idx) * 8 +: 8];
        end
    endfunction

    function automatic [15:0] ip_checksum;
        input [15:0] ident;
        input [31:0] dst_ip;
        reg [31:0] sum;
        begin
            sum = 32'd0;
            sum = sum + 16'h4500 + IP_RESP_LEN + ident + 16'h4000 + 16'h4011;
            sum = sum + LOCAL_IP[31:16] + LOCAL_IP[15:0] + dst_ip[31:16] + dst_ip[15:0];
            sum = {16'd0, sum[15:0]} + {16'd0, sum[31:16]};
            sum = {16'd0, sum[15:0]} + {16'd0, sum[31:16]};
            ip_checksum = ~sum[15:0];
        end
    endfunction

    wire [15:0] ip_sum = ip_checksum(ip_id, response_ip);

    function automatic [7:0] response_payload_byte(input [15:0] idx);
        begin
            if (idx == 16'd0) response_payload_byte = "R";
            else if (idx == 16'd1) response_payload_byte = "S";
            else if (idx == 16'd2) response_payload_byte = "A";
            else if (idx == 16'd3) response_payload_byte = "R";
            else if (idx == 16'd4) response_payload_byte = response_status;
            else if (idx == 16'd5) response_payload_byte = response_cycles[15:8];
            else if (idx == 16'd6) response_payload_byte = response_cycles[7:0];
            else if (idx == 16'd7) response_payload_byte = 8'd32;
            else if (idx < RESP_LEN)
                response_payload_byte = response_ciphertext[(31 - (idx - 16'd8)) * 8 +: 8];
            else response_payload_byte = 8'h00;
        end
    endfunction

    function automatic [7:0] arp_frame_byte(input [15:0] idx);
        begin
            if (idx < 16'd6) arp_frame_byte = peer_mac_byte(idx[2:0]);
            else if (idx < 16'd12) arp_frame_byte = local_mac_byte(idx - 16'd6);
            else if (idx == 16'd12) arp_frame_byte = 8'h08;
            else if (idx == 16'd13) arp_frame_byte = 8'h06;
            else if (idx == 16'd14) arp_frame_byte = 8'h00;
            else if (idx == 16'd15) arp_frame_byte = 8'h01;
            else if (idx == 16'd16) arp_frame_byte = 8'h08;
            else if (idx == 16'd17) arp_frame_byte = 8'h00;
            else if (idx == 16'd18) arp_frame_byte = 8'h06;
            else if (idx == 16'd19) arp_frame_byte = 8'h04;
            else if (idx == 16'd20) arp_frame_byte = 8'h00;
            else if (idx == 16'd21) arp_frame_byte = 8'h02;
            else if (idx < 16'd28) arp_frame_byte = local_mac_byte(idx - 16'd22);
            else if (idx < 16'd32) arp_frame_byte = local_ip_byte(idx - 16'd28);
            else if (idx < 16'd38) arp_frame_byte = peer_mac_byte(idx - 16'd32);
            else if (idx < 16'd42) arp_frame_byte = peer_ip_byte(idx - 16'd38);
            else arp_frame_byte = 8'h00;
        end
    endfunction

    function automatic [7:0] udp_frame_byte(input [15:0] idx);
        begin
            if (idx < 16'd6) udp_frame_byte = response_mac_byte(idx[2:0]);
            else if (idx < 16'd12) udp_frame_byte = local_mac_byte(idx - 16'd6);
            else if (idx == 16'd12) udp_frame_byte = 8'h08;
            else if (idx == 16'd13) udp_frame_byte = 8'h00;
            else if (idx == 16'd14) udp_frame_byte = 8'h45;
            else if (idx == 16'd15) udp_frame_byte = 8'h00;
            else if (idx == 16'd16) udp_frame_byte = IP_RESP_LEN[15:8];
            else if (idx == 16'd17) udp_frame_byte = IP_RESP_LEN[7:0];
            else if (idx == 16'd18) udp_frame_byte = ip_id[15:8];
            else if (idx == 16'd19) udp_frame_byte = ip_id[7:0];
            else if (idx == 16'd20) udp_frame_byte = 8'h40;
            else if (idx == 16'd21) udp_frame_byte = 8'h00;
            else if (idx == 16'd22) udp_frame_byte = 8'h40;
            else if (idx == 16'd23) udp_frame_byte = 8'h11;
            else if (idx == 16'd24) udp_frame_byte = ip_sum[15:8];
            else if (idx == 16'd25) udp_frame_byte = ip_sum[7:0];
            else if (idx < 16'd30) udp_frame_byte = local_ip_byte(idx - 16'd26);
            else if (idx < 16'd34) udp_frame_byte = response_ip_byte(idx - 16'd30);
            else if (idx == 16'd34) udp_frame_byte = UDP_SRC_PORT[15:8];
            else if (idx == 16'd35) udp_frame_byte = UDP_SRC_PORT[7:0];
            else if (idx == 16'd36) udp_frame_byte = response_port[15:8];
            else if (idx == 16'd37) udp_frame_byte = response_port[7:0];
            else if (idx == 16'd38) udp_frame_byte = UDP_RESP_LEN[15:8];
            else if (idx == 16'd39) udp_frame_byte = UDP_RESP_LEN[7:0];
            else if (idx == 16'd40) udp_frame_byte = 8'h00;
            else if (idx == 16'd41) udp_frame_byte = 8'h00;
            else if (idx < ETH_UDP_LEN) udp_frame_byte = response_payload_byte(idx - 16'd42);
            else udp_frame_byte = 8'h00;
        end
    endfunction

    task automatic parse_request_byte(input [15:0] idx, input [7:0] data);
        begin
            if (idx == 16'd0 && data != "R") req_status <= STATUS_BAD_MAGIC;
            if (idx == 16'd1 && data != "S") req_status <= STATUS_BAD_MAGIC;
            if (idx == 16'd2 && data != "A") req_status <= STATUS_BAD_MAGIC;
            if (idx == 16'd3 && data != "1") req_status <= STATUS_BAD_MAGIC;
            if (idx == 16'd4 && data != 8'h01) req_status <= STATUS_BAD_OP;
            if (idx >= 16'd5 && idx < REQ_LEN) begin
                req_message <= {req_message[247:0], data};
            end
        end
    endtask

    always_ff @(posedge clk50m or negedge phy_rdy) begin
        if (!phy_rdy) begin
            in_frame <= 1'b0;
            preamble_count <= 4'd0;
            frame_idx <= 11'd0;
            dest_local <= 1'b0;
            dest_broadcast <= 1'b0;
            rx_src_mac_shift <= 48'd0;
            peer_mac <= 48'd0;
            peer_ip <= 32'd0;
            peer_port <= 16'd0;
            eth_type <= 16'd0;
            arp_oper <= 16'd0;
            arp_spa <= 32'd0;
            arp_tpa <= 32'd0;
            ip_proto <= 8'd0;
            ip_src <= 32'd0;
            ip_dst <= 32'd0;
            udp_src_port <= 16'd0;
            udp_dst_port <= 16'd0;
            udp_len <= 16'd0;
            payload_idx <= 16'd0;
            req_status <= STATUS_OK;
            req_message <= 256'd0;
            pending_arp <= 1'b0;
            pending_rsa_start <= 1'b0;
            rsa_start <= 1'b0;
            response_status <= STATUS_OK;
            response_cycles <= 16'd0;
            response_ciphertext <= 256'd0;
            response_mac <= 48'd0;
            response_ip <= 32'd0;
            response_port <= 16'd0;
            pending_udp <= 1'b0;
            service_busy <= 1'b0;
            last_ok <= 1'b0;
            last_error <= 1'b0;
            debug_frame <= 1'b0;
            debug_ip <= 1'b0;
            debug_udp_proto <= 1'b0;
            debug_payload_start <= 1'b0;
            debug_arp <= 1'b0;
            debug_udp <= 1'b0;
            debug_rsa_ok <= 1'b0;
            debug_rsa_error <= 1'b0;
            ip_id <= 16'h1000;
        end else begin
            rsa_start <= 1'b0;
            pending_rsa_start <= 1'b0;
            debug_frame <= 1'b0;
            debug_ip <= 1'b0;
            debug_udp_proto <= 1'b0;
            debug_payload_start <= 1'b0;
            debug_arp <= 1'b0;
            debug_udp <= 1'b0;
            debug_rsa_ok <= 1'b0;
            debug_rsa_error <= 1'b0;
            service_busy <= rsa_busy || pending_udp;

            if (clear_pending_arp) begin
                pending_arp <= 1'b0;
            end
            if (clear_pending_udp) begin
                pending_udp <= 1'b0;
            end

            if (rsa_done) begin
                response_cycles <= rsa_cycles_wire;
                if (rsa_error) begin
                    response_status <= STATUS_RANGE;
                    response_ciphertext <= 256'd0;
                    last_ok <= 1'b0;
                    last_error <= 1'b1;
                    debug_rsa_error <= 1'b1;
                end else begin
                    response_status <= STATUS_OK;
                    response_ciphertext <= rsa_ciphertext;
                    last_ok <= 1'b1;
                    last_error <= 1'b0;
                    debug_rsa_ok <= 1'b1;
                end
                pending_udp <= 1'b1;
                ip_id <= ip_id + 16'd1;
            end

            if (pending_rsa_start) begin
                rsa_start <= 1'b1;
            end

            if (rx_end) begin
                in_frame <= 1'b0;
                preamble_count <= 4'd0;
            end

            if (rx_byte_valid) begin
                if (!in_frame) begin
                    if (rx_byte == 8'h55) begin
                        if (preamble_count != 4'hF) preamble_count <= preamble_count + 4'd1;
                    end else if (rx_byte == 8'hD5 && preamble_count >= 4'd5) begin
                        in_frame <= 1'b1;
                        debug_frame <= 1'b1;
                        frame_idx <= 11'd0;
                        dest_local <= 1'b1;
                        dest_broadcast <= 1'b1;
                        rx_src_mac_shift <= 48'd0;
                        eth_type <= 16'd0;
                        arp_oper <= 16'd0;
                        arp_spa <= 32'd0;
                        arp_tpa <= 32'd0;
                        ip_proto <= 8'd0;
                        ip_src <= 32'd0;
                        ip_dst <= 32'd0;
                        udp_src_port <= 16'd0;
                        udp_dst_port <= 16'd0;
                        udp_len <= 16'd0;
                        payload_idx <= 16'd0;
                        req_status <= STATUS_OK;
                        req_message <= 256'd0;
                        preamble_count <= 4'd0;
                    end else begin
                        preamble_count <= 4'd0;
                    end
                end else begin
                    if (frame_idx < 11'd6) begin
                        if (rx_byte != local_mac_byte(frame_idx[2:0])) dest_local <= 1'b0;
                        if (rx_byte != 8'hFF) dest_broadcast <= 1'b0;
                    end
                    if (frame_idx >= 11'd6 && frame_idx < 11'd12) begin
                        rx_src_mac_shift <= {rx_src_mac_shift[39:0], rx_byte};
                        if (frame_idx == 11'd11) peer_mac <= {rx_src_mac_shift[39:0], rx_byte};
                    end
                    if (frame_idx == 11'd12) eth_type[15:8] <= rx_byte;
                    if (frame_idx == 11'd13) eth_type[7:0] <= rx_byte;

                    if ((dest_local || dest_broadcast) && eth_type == 16'h0800 && frame_idx == 11'd14) begin
                        debug_ip <= 1'b1;
                    end

                    if ((dest_local || dest_broadcast) && eth_type == 16'h0806) begin
                        if (frame_idx == 11'd20) arp_oper[15:8] <= rx_byte;
                        if (frame_idx == 11'd21) arp_oper[7:0] <= rx_byte;
                        if (frame_idx >= 11'd28 && frame_idx < 11'd32) arp_spa <= {arp_spa[23:0], rx_byte};
                        if (frame_idx >= 11'd38 && frame_idx < 11'd42) arp_tpa <= {arp_tpa[23:0], rx_byte};
                        if (frame_idx == 11'd31) peer_ip <= {arp_spa[23:0], rx_byte};
                        if (frame_idx == 11'd41) begin
                            if (arp_oper == 16'h0001 && {arp_tpa[23:0], rx_byte} == LOCAL_IP) begin
                                pending_arp <= 1'b1;
                                debug_arp <= 1'b1;
                            end
                        end
                    end

                    if ((dest_local || dest_broadcast) && eth_type == 16'h0800) begin
                        if (frame_idx == 11'd23) begin
                            ip_proto <= rx_byte;
                            if (rx_byte == 8'h11) debug_udp_proto <= 1'b1;
                        end
                        if (frame_idx >= 11'd26 && frame_idx < 11'd30) ip_src <= {ip_src[23:0], rx_byte};
                        if (frame_idx >= 11'd30 && frame_idx < 11'd34) ip_dst <= {ip_dst[23:0], rx_byte};
                        if (frame_idx == 11'd29) peer_ip <= {ip_src[23:0], rx_byte};
                        if (frame_idx == 11'd34) udp_src_port[15:8] <= rx_byte;
                        if (frame_idx == 11'd35) begin
                            udp_src_port[7:0] <= rx_byte;
                            peer_port <= {udp_src_port[15:8], rx_byte};
                        end
                        if (frame_idx == 11'd36) udp_dst_port[15:8] <= rx_byte;
                        if (frame_idx == 11'd37) udp_dst_port[7:0] <= rx_byte;
                        if (frame_idx == 11'd38) udp_len[15:8] <= rx_byte;
                        if (frame_idx == 11'd39) udp_len[7:0] <= rx_byte;
                        if (frame_idx >= 11'd42) begin
                            if (frame_idx == 11'd42) debug_payload_start <= 1'b1;
                            parse_request_byte(payload_idx, rx_byte);
                            payload_idx <= payload_idx + 16'd1;
                            if (payload_idx + 16'd1 == ({udp_len[15:8], udp_len[7:0]} - 16'd8)) begin
                                debug_udp <= 1'b1;
                                if (ip_proto == 8'h11 &&
                                    (ip_dst == LOCAL_IP || ip_dst == 32'hFFFFFFFF) &&
                                    udp_dst_port == UDP_SRC_PORT) begin
                                    response_mac <= peer_mac;
                                    response_ip <= peer_ip;
                                    response_port <= peer_port;
                                    if (({udp_len[15:8], udp_len[7:0]} - 16'd8) != REQ_LEN) begin
                                        response_status <= STATUS_BAD_LEN;
                                        response_cycles <= 16'd0;
                                        response_ciphertext <= 256'd0;
                                        pending_udp <= 1'b1;
                                        last_ok <= 1'b0;
                                        last_error <= 1'b1;
                                        ip_id <= ip_id + 16'd1;
                                    end else if (req_status != STATUS_OK) begin
                                        response_status <= req_status;
                                        response_cycles <= 16'd0;
                                        response_ciphertext <= 256'd0;
                                        pending_udp <= 1'b1;
                                        last_ok <= 1'b0;
                                        last_error <= 1'b1;
                                        ip_id <= ip_id + 16'd1;
                                    end else begin
                                        pending_rsa_start <= 1'b1;
                                    end
                                end
                            end
                        end
                    end

                    frame_idx <= frame_idx + 11'd1;
                end
            end
        end
    end

    reg [1:0] tx_kind;
    reg [15:0] tx_idx;
    reg tx_active;
    wire [15:0] tx_len = (tx_kind == 2'd1) ? ETH_ARP_LEN : ETH_UDP_LEN;

    always_ff @(posedge clk50m or negedge phy_rdy) begin
        if (!phy_rdy) begin
            tx_kind <= 2'd0;
            tx_idx <= 16'd0;
            tx_active <= 1'b0;
            tx_en <= 1'b0;
            tx_byte <= 8'd0;
            clear_pending_arp <= 1'b0;
            clear_pending_udp <= 1'b0;
        end else begin
            tx_en <= 1'b0;
            clear_pending_arp <= 1'b0;
            clear_pending_udp <= 1'b0;
            debug_tx_udp <= 1'b0;
            if (!tx_active) begin
                if (!tx_bz && pending_arp) begin
                    tx_active <= 1'b1;
                    tx_kind <= 2'd1;
                    tx_idx <= 16'd0;
                    clear_pending_arp <= 1'b1;
                end else if (!tx_bz && pending_udp) begin
                    tx_active <= 1'b1;
                    tx_kind <= 2'd2;
                    tx_idx <= 16'd0;
                    clear_pending_udp <= 1'b1;
                    debug_tx_udp <= 1'b1;
                end
            end else if (tx_av) begin
                tx_en <= 1'b1;
                tx_byte <= (tx_kind == 2'd1) ? arp_frame_byte(tx_idx) : udp_frame_byte(tx_idx);
                if (tx_idx == tx_len - 16'd1) begin
                    tx_active <= 1'b0;
                    tx_idx <= 16'd0;
                end else begin
                    tx_idx <= tx_idx + 16'd1;
                end
            end
        end
    end

endmodule
