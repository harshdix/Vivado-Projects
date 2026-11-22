module frame_receiver #(
    parameter CAM_W        = 128,
    parameter CAM_H        = 96,
    parameter FRAME_PIXELS = CAM_W * CAM_H   // 12288
)(
    input  wire        clk,
    input  wire        rst,

    // From UART receiver
    input  wire [7:0]  rx_data,
    input  wire        rx_valid,

    // To frame buffer (write port)
    output reg  [13:0] fb_waddr,     // 0..12287
    output reg  [7:0]  fb_wdata,
    output reg         fb_we,

    // Status
    output reg         frame_done,   // pulses when full frame written
    output reg  [1:0]  sync_state_dbg // for ILA debugging
);

// ── Sync detection state machine ───────────────────────────────
// Looks for sequence: 0xFF → 0xFE → 0xFD → then pixel data
localparam WAIT_FF = 2'd0,
           WAIT_FE = 2'd1,
           WAIT_FD = 2'd2,
           RECEIVE  = 2'd3;

reg [1:0]  state     = WAIT_FF;
reg [13:0] pix_count = 0;

always @(*) begin
    sync_state_dbg = state;
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state      <= WAIT_FF;
        pix_count  <= 0;
        fb_we      <= 0;
        frame_done <= 0;
        fb_waddr   <= 0;
        fb_wdata   <= 0;
    end else begin
        fb_we      <= 0;
        frame_done <= 0;

        if (rx_valid) begin
            case (state)

                // ── Sync byte 1 ───────────────────────────────
                WAIT_FF: begin
                    if (rx_data == 8'hFF) state <= WAIT_FE;
                end

                // ── Sync byte 2 ───────────────────────────────
                WAIT_FE: begin
                    if      (rx_data == 8'hFE) state <= WAIT_FD;
                    else if (rx_data == 8'hFF) state <= WAIT_FE;
                    else                       state <= WAIT_FF;
                end

                // ── Sync byte 3 ───────────────────────────────
                WAIT_FD: begin
                    if      (rx_data == 8'hFD) begin
                        state     <= RECEIVE;
                        pix_count <= 0;
                    end
                    else if (rx_data == 8'hFF) state <= WAIT_FE;
                    else                       state <= WAIT_FF;
                end

                // ── Receive pixel data ─────────────────────────
                RECEIVE: begin
                    // Reject any stray 0xFF bytes in data
                    // (pixel clamped to 0xFE max in Python if needed)
                    fb_wdata  <= rx_data;
                    fb_waddr  <= pix_count[13:0];
                    fb_we     <= 1;
                    pix_count <= pix_count + 1;

                    if (pix_count == FRAME_PIXELS - 1) begin
                        state      <= WAIT_FF;   // wait for next frame
                        frame_done <= 1;
                        pix_count  <= 0;
                    end
                end

            endcase
        end
    end
end
endmodule