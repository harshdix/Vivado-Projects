// centroid_calc.v  — FIXED (latch all sums at frame_end)
`timescale 1ns / 1ps

module centroid_calc #(
    parameter SUM_BITS = 21,
    parameter CNT_BITS = 14,
    parameter X_BITS   = 7,
    parameter Y_BITS   = 7,
    parameter MIN_PIX  = 100
)(
    input  wire                clk,
    input  wire                rst,
    input  wire                frame_start,
    input  wire                frame_end,
    input  wire                pixel_valid,
    input  wire                fg,
    input  wire [X_BITS-1:0]   px,
    input  wire [Y_BITS-1:0]   py,
    output reg  [X_BITS-1:0]   cx,
    output reg  [Y_BITS-1:0]   cy,
    output reg                 valid
);

// ---------------------------------------------------------------------------
// Accumulators — reset on frame_start
// ---------------------------------------------------------------------------
reg [SUM_BITS-1:0] sum_x = 0;
reg [SUM_BITS-1:0] sum_y = 0;
reg [CNT_BITS-1:0] sum_n = 0;

always @(posedge clk) begin
    if (rst || frame_start) begin
        sum_x <= 0;
        sum_y <= 0;
        sum_n <= 0;
    end else if (pixel_valid && fg) begin
        sum_x <= sum_x + {{(SUM_BITS-X_BITS){1'b0}}, px};
        sum_y <= sum_y + {{(SUM_BITS-Y_BITS){1'b0}}, py};
        sum_n <= sum_n + 1;
    end
end

reg [SUM_BITS-1:0] lat_x = 0;
reg [SUM_BITS-1:0] lat_y = 0;
reg [CNT_BITS-1:0] lat_n = 0;

// ---------------------------------------------------------------------------
// Sequential binary divider
// ---------------------------------------------------------------------------
localparam DIV_IDLE  = 2'd0,
           DIV_RUN_X = 2'd1,
           DIV_RUN_Y = 2'd2;

reg [1:0]           div_state = DIV_IDLE;
reg [SUM_BITS-1:0]  dividend  = 0;
reg [SUM_BITS-1:0]  divisor_r = 0;
reg [SUM_BITS-1:0]  quotient  = 0;
reg [SUM_BITS-1:0]  remainder = 0;
reg [4:0]           div_bit   = 0;
reg [X_BITS-1:0]    cx_int    = 0;

// Blocking variables — computed combinationally within the clocked block
reg [SUM_BITS-1:0] new_quotient;
reg [SUM_BITS-1:0] rem_shifted;

always @(posedge clk) begin
    if (rst) begin
        div_state <= DIV_IDLE;
        valid     <= 0;
        cx        <= 0;
        cy        <= 0;
        quotient  <= 0;
        remainder <= 0;
        div_bit   <= 0;
        cx_int    <= 0;
        lat_x     <= 0;
        lat_y     <= 0;
        lat_n     <= 0;
    end else begin

        case (div_state)

            DIV_IDLE: begin
                if (frame_end) begin
                    if (sum_n > MIN_PIX) begin
                        lat_x <= sum_x;
                        lat_y <= sum_y;
                        lat_n <= sum_n;

                        dividend  <= sum_x;
                        divisor_r <= {{(SUM_BITS-CNT_BITS){1'b0}}, sum_n};
                        quotient  <= 0;
                        remainder <= 0;
                        div_bit   <= SUM_BITS - 1;
                        div_state <= DIV_RUN_X;
                        valid     <= 0;
                    end else begin
                        valid <= 0;
                    end
                end
            end

            // ------------------------------------------------------------------
            // Divide sum_x / sum_n → cx
            // ------------------------------------------------------------------
            DIV_RUN_X: begin
                rem_shifted  = {remainder[SUM_BITS-2:0], dividend[div_bit]};

                if (rem_shifted >= divisor_r) begin
                    remainder    <= rem_shifted - divisor_r;
                    new_quotient  = {quotient[SUM_BITS-2:0], 1'b1};
                end else begin
                    remainder    <= rem_shifted;
                    new_quotient  = {quotient[SUM_BITS-2:0], 1'b0};
                end

                quotient <= new_quotient;

                if (div_bit == 0) begin
                    cx_int <= new_quotient[X_BITS-1:0];

                    dividend  <= lat_y;
                    divisor_r <= {{(SUM_BITS-CNT_BITS){1'b0}}, lat_n};
                    quotient  <= 0;
                    remainder <= 0;
                    div_bit   <= SUM_BITS - 1;
                    div_state <= DIV_RUN_Y;
                end else begin
                    div_bit <= div_bit - 1;
                end
            end

            // ------------------------------------------------------------------
            // Divide lat_y / lat_n → cy
            // ------------------------------------------------------------------
            DIV_RUN_Y: begin
                rem_shifted  = {remainder[SUM_BITS-2:0], dividend[div_bit]};

                if (rem_shifted >= divisor_r) begin
                    remainder    <= rem_shifted - divisor_r;
                    new_quotient  = {quotient[SUM_BITS-2:0], 1'b1};
                end else begin
                    remainder    <= rem_shifted;
                    new_quotient  = {quotient[SUM_BITS-2:0], 1'b0};
                end

                quotient <= new_quotient;

                if (div_bit == 0) begin
                    cx        <= cx_int;
                    cy        <= new_quotient[Y_BITS-1:0];
                    valid     <= 1;
                    div_state <= DIV_IDLE;
                end else begin
                    div_bit <= div_bit - 1;
                end
            end

        endcase
    end
end

endmodule