
`timescale 1ns / 1ps

module top (
    input  wire        CLK100MHZ,
    input  wire        CPU_RESETN,
    input  wire        UART_TXD_IN,
    input  wire        BTNC,

    input  wire [3:0]  SW,

    output wire [3:0]  VGA_R,
    output wire [3:0]  VGA_G,
    output wire [3:0]  VGA_B,
    output wire        VGA_HS,
    output wire        VGA_VS,
    output wire [3:0]  LED
);

localparam CAM_W        = 128;
localparam CAM_H        = 96;
localparam FRAME_PIXELS = CAM_W * CAM_H;
localparam ABITS        = 14;

wire rst = ~CPU_RESETN;

// ── Clock ──────────────────────────────────────────────────────
wire clk_25, clk_locked;
clk_wiz_0 u_clkgen (
    .clk_in1  (CLK100MHZ),
    .reset    (rst),
    .clk_out1 (clk_25),
    .locked   (clk_locked)
);
wire rst_safe = rst | ~clk_locked;

// ── UART receiver ──────────────────────────────────────────────
wire [7:0] uart_byte;
wire       uart_valid;

uart_rx u_uart (
    .clk   (CLK100MHZ),
    .rst   (rst_safe),
    .rx    (UART_TXD_IN),
    .data  (uart_byte),
    .valid (uart_valid)
);

// ── Frame receiver ─────────────────────────────────────────────
wire [ABITS-1:0] fb_waddr;
wire [7:0]       fb_wdata;
wire             fb_we;
wire             frame_done;
wire [1:0]       sync_dbg;

frame_receiver #(
    .CAM_W        (CAM_W),
    .CAM_H        (CAM_H),
    .FRAME_PIXELS (FRAME_PIXELS)
) u_frx (
    .clk            (CLK100MHZ),
    .rst            (rst_safe),
    .rx_data        (uart_byte),
    .rx_valid       (uart_valid),
    .fb_waddr       (fb_waddr),
    .fb_wdata       (fb_wdata),
    .fb_we          (fb_we),
    .frame_done     (frame_done),
    .sync_state_dbg (sync_dbg)
);

// ── Button debounce ────────────────────────────────────────────
reg [19:0] dbnc_cnt   = 0;
reg        dbnc_prev  = 0;
reg        capture_bg = 0;

always @(posedge CLK100MHZ) begin
    capture_bg <= 0;
    if (BTNC)
        dbnc_cnt <= (dbnc_cnt == 20'hFFFFF) ? 20'hFFFFF
                                             : dbnc_cnt + 1;
    else
        dbnc_cnt <= 0;
    if (dbnc_cnt == 20'hFFFFF && !dbnc_prev)
        capture_bg <= 1;
    dbnc_prev <= (dbnc_cnt == 20'hFFFFF);
end

reg bg_valid = 0;
always @(posedge CLK100MHZ)
    if (rst_safe) bg_valid <= 0;
    else if (capture_bg) bg_valid <= 1;

reg [7:0] threshold_reg;
always @(posedge CLK100MHZ) begin
    case (SW)
        4'b0000: threshold_reg <= 8'd10;
        4'b0001: threshold_reg <= 8'd20;
        4'b0010: threshold_reg <= 8'd30;
        4'b0011: threshold_reg <= 8'd40;
        4'b0100: threshold_reg <= 8'd50;
        4'b0101: threshold_reg <= 8'd60;
        4'b0110: threshold_reg <= 8'd70;
        4'b0111: threshold_reg <= 8'd80;
        4'b1000: threshold_reg <= 8'd90;
        4'b1001: threshold_reg <= 8'd100;
        4'b1010: threshold_reg <= 8'd110;
        4'b1011: threshold_reg <= 8'd120;
        4'b1100: threshold_reg <= 8'd130;
        4'b1101: threshold_reg <= 8'd140;
        4'b1110: threshold_reg <= 8'd150;
        4'b1111: threshold_reg <= 8'd160;
    endcase
end

// ── VGA controller ─────────────────────────────────────────────
wire [9:0] hcount, vcount;
wire       active;

vga_controller u_vga (
    .pclk   (clk_25),
    .rst    (rst_safe),
    .hsync  (VGA_HS),
    .vsync  (VGA_VS),
    .hcount (hcount),
    .vcount (vcount),
    .active (active)
);

// ── Frame buffer read address ──────────────────────────────────
wire [16:0] hscaled = hcount * 17'd205;
wire [16:0] vscaled = vcount * 17'd205;
wire [6:0]  fb_x    = (hcount < 640) ? hscaled[16:10] : 7'd0;
wire [6:0]  fb_y    = (vcount < 480) ? vscaled[16:10] : 7'd0;
wire [ABITS-1:0] fb_raddr = {fb_y, 7'b0} + {7'b0, fb_x};

// ── Frame buffer ───────────────────────────────────────────────
wire [7:0] curr_pixel, bg_pixel;

frame_buffer_dp #(
    .DEPTH (FRAME_PIXELS),
    .ABITS (ABITS)
) u_fb (
    .waddr      (fb_waddr),
    .wdata      (fb_wdata),
    .we         (fb_we),
    .wclk       (CLK100MHZ),
    .raddr_a    (fb_raddr),
    .rdata_a    (curr_pixel),
    .rclk       (clk_25),
    .raddr_b    (fb_raddr),
    .rdata_b    (bg_pixel),
    .capture_bg (capture_bg),
    .sys_clk    (CLK100MHZ)
);

// ── Background subtractor ──────────────────────────────────────
wire fg_pixel;

bg_subtractor u_bgsub (
    .clk        (clk_25),
    .curr_pixel (curr_pixel),
    .bg_pixel   (bg_pixel),
    .threshold  (threshold_reg),   // live-tunable via SW[3:0]
    .fg_pixel   (fg_pixel)
);

// ── 2-stage pipeline delay ─────────────────────────────────────
reg        active_d1 = 0, active_d2 = 0;
reg [6:0]  fb_x_d1   = 0, fb_x_d2   = 0;
reg [6:0]  fb_y_d1   = 0, fb_y_d2   = 0;

always @(posedge clk_25) begin
    active_d1 <= active;   fb_x_d1 <= fb_x;   fb_y_d1 <= fb_y;
    active_d2 <= active_d1; fb_x_d2 <= fb_x_d1; fb_y_d2 <= fb_y_d1;
end

// ── Frame end pulse ────────────────────────────────────────────
reg vsync_prev = 1;
always @(posedge clk_25) vsync_prev <= VGA_VS;
wire frame_end_pulse = (~VGA_VS) & vsync_prev;

// ── Centroid calculator ────────────────────────────────────────
wire [6:0] cx, cy;
wire       centroid_valid_raw;

centroid_calc #(
    .SUM_BITS (21),
    .CNT_BITS (14),
    .X_BITS   (7),
    .Y_BITS   (7),
    .MIN_PIX  (200)    
    
) u_cent (
    .clk         (clk_25),
    .rst         (rst_safe),
    .frame_start (frame_end_pulse),
    .frame_end   (frame_end_pulse),
    .pixel_valid (active_d2),
    .fg          (fg_pixel),
    .px          (fb_x_d2),
    .py          (fb_y_d2),
    .cx          (cx),
    .cy          (cy),
    .valid       (centroid_valid_raw)
);


wire centroid_valid = centroid_valid_raw && bg_valid;

// ── Cross overlay ──────────────────────────────────────────────
wire [9:0] cx_vga = ({3'b0, cx} << 2) + {3'b0, cx};   // cx × 5
wire [9:0] cy_vga = ({3'b0, cy} << 2) + {3'b0, cy};   // cy × 5

localparam ARM = 20;

wire on_cross_h = centroid_valid
                  && (vcount == cy_vga)
                  && (hcount + ARM >= cx_vga)
                  && (hcount        <= cx_vga + ARM);

wire on_cross_v = centroid_valid
                  && (hcount == cx_vga)
                  && (vcount + ARM >= cy_vga)
                  && (vcount        <= cy_vga + ARM);

wire on_cross = on_cross_h | on_cross_v;

// ── VGA pixel output ───────────────────────────────────────────
reg [3:0] r_reg, g_reg, b_reg;

always @(posedge clk_25) begin
    if (!active) begin
        r_reg <= 4'h0; g_reg <= 4'h0; b_reg <= 4'h0;
    end else if (on_cross) begin
        r_reg <= 4'h0; g_reg <= 4'hF; b_reg <= 4'h0;
    end else begin
        r_reg <= curr_pixel[7:4];
        g_reg <= curr_pixel[7:4];
        b_reg <= curr_pixel[7:4];
    end
end

assign VGA_R = r_reg;
assign VGA_G = g_reg;
assign VGA_B = b_reg;

// ── Debug LED pulse stretchers ─────────────────────────────────
localparam STRETCH_BITS = 23;   // 2^23 ≈ 84 ms
localparam BG_BITS      = 27;   // 2^27 ≈ 1.34 s

// LED[0] — UART receiving
reg [STRETCH_BITS-1:0] rx_cnt   = 0;
reg                    led0_reg = 0;
always @(posedge CLK100MHZ) begin
    if (rst_safe) begin rx_cnt <= 0; led0_reg <= 0; end
    else if (uart_valid)  begin rx_cnt <= {STRETCH_BITS{1'b1}}; led0_reg <= 1; end
    else if (rx_cnt > 0)  begin rx_cnt <= rx_cnt - 1;           led0_reg <= 1; end
    else                        led0_reg <= 0;
end

// LED[1] — background captured
reg [BG_BITS-1:0] bg_led_cnt = 0;
reg               led1_reg   = 0;
always @(posedge CLK100MHZ) begin
    if (rst_safe) begin bg_led_cnt <= 0; led1_reg <= 0; end
    else if (capture_bg)      begin bg_led_cnt <= {BG_BITS{1'b1}}; led1_reg <= 1; end
    else if (bg_led_cnt > 0)  begin bg_led_cnt <= bg_led_cnt - 1;  led1_reg <= 1; end
    else                            led1_reg <= 0;
end

// LED[2] — frame_done
reg [STRETCH_BITS-1:0] fd_cnt   = 0;
reg                    led2_reg = 0;
always @(posedge CLK100MHZ) begin
    if (rst_safe) begin fd_cnt <= 0; led2_reg <= 0; end
    else if (frame_done)  begin fd_cnt <= {STRETCH_BITS{1'b1}}; led2_reg <= 1; end
    else if (fd_cnt > 0)  begin fd_cnt <= fd_cnt - 1;           led2_reg <= 1; end
    else                        led2_reg <= 0;
end

// LED[3] — object detected
reg [STRETCH_BITS-1:0] cv_cnt   = 0;
reg                    led3_reg = 0;
always @(posedge CLK100MHZ) begin
    if (rst_safe) begin cv_cnt <= 0; led3_reg <= 0; end
    else if (centroid_valid)  begin cv_cnt <= {STRETCH_BITS{1'b1}}; led3_reg <= 1; end
    else if (cv_cnt > 0)      begin cv_cnt <= cv_cnt - 1;           led3_reg <= 1; end
    else                            led3_reg <= 0;
end

assign LED[0] = led0_reg;
assign LED[1] = led1_reg;
assign LED[2] = led2_reg;
assign LED[3] = led3_reg;

endmodule